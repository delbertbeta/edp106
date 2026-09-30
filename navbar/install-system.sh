#!/bin/sh
# Install EpdNavBar as a privileged system app, so that it starts on boot by
# itself and cannot be killed.
#
# WHY THIS EXISTS
# ---------------
# A /data install cannot auto-start reliably on this ROM. Its ActivityManager
# silently drops a startForegroundService() issued from a process it has not yet
# marked foreground, and it refuses `am` service starts while the package is in
# the stopped state. Measured, by logging every attempt:
#
#   startForegroundService ok from onCreate    <- returns, logs nothing, nothing happens
#   startForegroundService ok from onResume    <- same
#   startForegroundService ok from delayed-3s  <- works
#
# BootReceiver fires into exactly that freshly-spawned, not-yet-foreground state,
# so BOOT_COMPLETED is not dependable here. As a system app with
# android:persistent="true" the process is started by ActivityManagerService
# during boot (startPersistentApps), which sidesteps the problem entirely: no
# broadcast delivery, no background service start to drop, and a persistent
# process cannot be killed.
#
# REQUIRES ROOT -- either an eng/userdebug build (adb root works, or su), or
# Magisk. On the stock `user` build this cannot work: ro.secure=1, no su, and
# adbd refuses to run as root in a production build.
#
#   ./install-system.sh
set -e

PROJECT=$(cd "$(dirname "$0")" && pwd)
APK=$PROJECT/build/epdnav.apk
PKG=com.delbert.epdnav
APP_DIR=/system/priv-app/EpdNavBar
PERM_DIR=/system/etc/permissions
PERM_XML=privapp-permissions-$PKG.xml
TMP=/data/local/tmp

[ -f "$APK" ] || { echo "build first: ./build.sh" >&2; exit 1; }

# ---------------------------------------------------------------- root access
echo "=== 1/7 establish root ==="
adb root >/dev/null 2>&1 || true
sleep 2

if adb shell id 2>/dev/null | grep -q 'uid=0'; then
    SUDO=""
    echo "  adbd is running as root"
elif adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
    SUDO=1
    echo "  will escalate with su"
else
    cat >&2 <<'EOF'
  no root available.

  Neither `adb root` nor `su` gives uid 0. This ROM is a production `user`
  build (ro.secure=1) with no su binary, so /system cannot be written.
  Flash eng/userdebug firmware, or install Magisk, then re-run this script.
EOF
    exit 1
fi

# Run a command on the device with root. $SUDO empty => adbd is already root, so
# the command only needs adb shell; otherwise wrap it in su -c.
asroot() {
    if [ -z "$SUDO" ]; then
        adb shell "$1"
    else
        adb shell "su -c '$1'"
    fi
}

# ------------------------------------------------------------ mount /system rw
echo "=== 2/7 remount /system read-write ==="
if ! asroot 'mount -o rw,remount /system' 2>/dev/null; then
    asroot 'mount -o rw,remount /' 2>/dev/null || adb remount || true
fi
if ! asroot 'touch /system/.epdnav-write-test' 2>/dev/null; then
    echo "  /system is still read-only" >&2
    exit 1
fi
asroot 'rm -f /system/.epdnav-write-test'
echo "  /system is writable"

# ------------------------------------------------------------------ stage files
echo "=== 3/7 stage files on the device ==="
adb push "$APK" "$TMP/epdnav.apk"
adb push "$PROJECT/system/etc/permissions/$PERM_XML" "$TMP/$PERM_XML"

# --------------------------------------------------------------- install the APK
echo "=== 4/7 install into $APP_DIR ==="
asroot "mkdir -p $APP_DIR"
asroot "cp $TMP/epdnav.apk $APP_DIR/epdnav.apk"
asroot "chown root:root $APP_DIR/epdnav.apk"
asroot "chmod 644 $APP_DIR/epdnav.apk"
asroot "restorecon -R $APP_DIR" 2>/dev/null || true

# --------------------------------------------------------- privileged whitelist
echo "=== 5/7 install privapp permission whitelist ==="
asroot "cp $TMP/$PERM_XML $PERM_DIR/$PERM_XML"
asroot "chown root:root $PERM_DIR/$PERM_XML"
asroot "chmod 644 $PERM_DIR/$PERM_XML"
asroot "restorecon $PERM_DIR/$PERM_XML" 2>/dev/null || true
asroot "rm -f $TMP/epdnav.apk $TMP/$PERM_XML"

# ------------------------------------------------------------------- clean up
echo "=== 6/7 remove any /data copy of the package ==="
# A /data install of the same package name shadows the system one. A fresh
# firmware flash wipes /data anyway, so this is just a safety net.
adb uninstall "$PKG" >/dev/null 2>&1 || true
echo "  done"

# ---------------------------------------------------------------------- reboot
echo "=== 7/7 reboot ==="
adb reboot
echo
cat <<EOF
Rebooting. Once it is back, verify auto-start with:

  adb shell dumpsys package $PKG | grep -A3 'flags='
      # expect FLAG_SYSTEM (0x1) and FLAG_PERSISTENT (0x8) in the app's flags

  adb shell ps -A | grep epdnav
      # the process should exist without anything having launched it

  adb shell dumpsys window | grep mStable
      # expect the bottom at 960 instead of 1024

  adb shell dumpsys window policy | grep -E 'mNavigationBar=|BarController'
EOF
