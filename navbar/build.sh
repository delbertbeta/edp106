#!/bin/sh
# Build, platform-sign and stage the EpdNavBar APK.
#
# No Gradle and no external dependencies: aapt2 compile/link -> javac -> d8 ->
# zipalign -> apksigner, using the Android build-tools already installed in WSL.
# The APK is signed with the well-known AOSP `platform` key, which is the same
# key the device itself is signed with, so the signature-level permissions it
# requests (STATUS_BAR_SERVICE, INJECT_EVENTS, ...) are actually granted.
#
#   ./build.sh            # build only
#   ./build.sh --install  # build, then install onto the attached device
set -e

PROJECT=$(cd "$(dirname "$0")" && pwd)
BT=${BT:-/opt/android-sdk/build-tools/35.0.0}
PLATFORM=${PLATFORM:-/opt/android-sdk/platforms/android-36/android.jar}
KEY=${KEY:-$PROJECT/keys/platform.pk8}
CERT=${CERT:-$PROJECT/keys/platform.x509.pem}

OUT=$PROJECT/build
APK=$OUT/epdnav.apk

rm -rf "$OUT"
mkdir -p "$OUT/classes"

echo "=== 1/7 aapt2 compile (resources) ==="
"$BT/aapt2" compile --dir "$PROJECT/res" -o "$OUT/res.zip"

echo "=== 2/7 javac ==="
javac -source 8 -target 8 -nowarn \
    -bootclasspath "$PLATFORM" \
    -d "$OUT/classes" \
    $(find "$PROJECT/src" -name '*.java')

echo "=== 3/7 d8 ==="
"$BT/d8" --min-api 27 --lib "$PLATFORM" --output "$OUT" \
    $(find "$OUT/classes" -name '*.class')

echo "=== 4/7 aapt2 link ==="
"$BT/aapt2" link -o "$OUT/unsigned.apk" -I "$PLATFORM" \
    --manifest "$PROJECT/AndroidManifest.xml" \
    --min-sdk-version 27 --target-sdk-version 27 \
    "$OUT/res.zip"

echo "=== 5/7 add classes.dex ==="
python3 - "$OUT" <<'PY'
import sys, zipfile, os
out = sys.argv[1]
with zipfile.ZipFile(os.path.join(out, "unsigned.apk"), "a", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(out, "classes.dex"), "classes.dex")
print("  added classes.dex")
PY

echo "=== 6/7 zipalign ==="
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "=== 7/7 apksigner (AOSP platform key) ==="
"$BT/apksigner" sign \
    --key "$KEY" \
    --cert "$CERT" \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --out "$APK" "$OUT/aligned.apk"

"$BT/apksigner" verify --print-certs "$APK" | sed -n '3,4p'
echo
echo "APK: $APK"

if [ "$1" = "--install" ]; then
    echo
    echo "=== installing ==="
    adb install -r "$APK"
    echo
    echo "Now launch it once so the package leaves the stopped state:"
    echo "  adb shell am start -n com.delbert.epdnav/.MainActivity"
fi
