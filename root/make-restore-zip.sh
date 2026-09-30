#!/bin/sh
# Rebuild work/restore_stock_signed.zip -- the signed OTA zip that writes the
# ORIGINAL boot.img back to the boot partition, undoing the Magisk root.
#
#   JAVA8=~/jdk8 ./make-restore-zip.sh
#
# Then, on the device:
#
#   adb reboot recovery       # touch the screen, pick "Apply update from ADB"
#   adb sideload work/restore_stock_signed.zip
#
# The package is assembled from toolkit/kernel_flashing_template.zip (whose
# update-binary, otacert and metadata are the ones stock recovery accepts),
# with toolkit/restore-updater-script substituted in and backup/zzboot.img
# appended STORED -- an OTA boot.img must not be compressed.
#
# Signing needs a JDK **8**: signapk reaches into sun.security.pkcs, which
# JDK 9+ no longer exports. That is why this takes JAVA8 rather than using
# whatever `java` is on PATH.
set -e

PROJECT=$(cd "$(dirname "$0")" && pwd)
JAVA8=${JAVA8:-}

[ -x "$JAVA8/bin/java" ] || {
    echo "JAVA8 is not set to a JDK 8 home, e.g. JAVA8=~/jdk8 $0" >&2
    echo "(signapk needs JDK 8; JDK 9+ does not export sun.security.pkcs)" >&2
    exit 1
}

OUT=$PROJECT/work
STAGE=$OUT/.restore_unsigned.zip
mkdir -p "$OUT"

echo "=== 1/2 assemble the unsigned package ==="
python3 - "$PROJECT" "$STAGE" <<'PY'
import os, sys, zipfile

project, stage = sys.argv[1], sys.argv[2]
updater = open(os.path.join(project, "toolkit", "restore-updater-script"), "rb").read()
boot_img = open(os.path.join(project, "backup", "zzboot.img"), "rb").read()

with zipfile.ZipFile(os.path.join(project, "toolkit", "kernel_flashing_template.zip")) as src, \
     zipfile.ZipFile(stage, "w", zipfile.ZIP_DEFLATED) as dst:
    for entry in src.infolist():
        data = updater if entry.filename.endswith("updater-script") else src.read(entry.filename)
        dst.writestr(entry, data)
    boot = zipfile.ZipInfo("boot.img")
    boot.compress_type = zipfile.ZIP_STORED
    dst.writestr(boot, boot_img)
print("  boot.img %d bytes (STORED)" % len(boot_img))
PY

echo "=== 2/2 sign with testkey ==="
"$JAVA8/bin/java" -jar "$PROJECT/toolkit/signapk-1.0.jar" \
    -w "$PROJECT/toolkit/testkey.x509.pem" "$PROJECT/toolkit/testkey.pk8" \
    "$STAGE" "$OUT/restore_stock_signed.zip"
rm -f "$STAGE"

echo
echo "writes the ORIGINAL boot (md5 411ffe637dc3ca8972d88cd6bfbe3717) to /dev/block/by-name/boot"
echo "install with:  adb reboot recovery  &&  adb sideload $OUT/restore_stock_signed.zip"
