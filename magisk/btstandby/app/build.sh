#!/bin/sh
# 编译并平台签名 BtPanStby.apk。
# 惯例同 navbar/build.sh：无 Gradle，aapt2 -> javac -> d8 -> aapt2 link -> zipalign -> apksigner，
# 用 AOSP platform 密钥签名（和 device 自己的签名一致，权限才真拿得到）。
#
#   ./build.sh        # 只编译
set -e

PROJECT=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$PROJECT/../../.." && pwd)
BT=${BT:-/opt/android-sdk/build-tools/35.0.0}
PLATFORM=${PLATFORM:-/opt/android-sdk/platforms/android-36/android.jar}
KEY=${KEY:-$root/navbar/keys/platform.pk8}
CERT=${CERT:-$root/navbar/keys/platform.x509.pem}

OUT=$PROJECT/build
APK=$OUT/BtPanStby.apk

rm -rf "$OUT"
mkdir -p "$OUT/classes"

echo "=== 1/6 javac ==="
javac -source 8 -target 8 -nowarn -bootclasspath "$PLATFORM" -d "$OUT/classes" \
    $(find "$PROJECT/src" -name '*.java')

echo "=== 2/6 d8 ==="
"$BT/d8" --min-api 27 --lib "$PLATFORM" --output "$OUT" \
    $(find "$OUT/classes" -name '*.class')

echo "=== 3/6 aapt2 link ==="
"$BT/aapt2" link -o "$OUT/unsigned.apk" -I "$PLATFORM" \
    --manifest "$PROJECT/AndroidManifest.xml" \
    --min-sdk-version 27 --target-sdk-version 27

echo "=== 4/6 加入 classes.dex ==="
python3 - "$OUT" <<'PY'
import sys, zipfile, os
out = sys.argv[1]
with zipfile.ZipFile(os.path.join(out, "unsigned.apk"), "a", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(out, "classes.dex"), "classes.dex")
print("  added classes.dex")
PY

echo "=== 5/6 zipalign ==="
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "=== 6/6 apksigner (AOSP platform key) ==="
"$BT/apksigner" sign --key "$KEY" --cert "$CERT" \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$APK" "$OUT/aligned.apk"

"$BT/apksigner" verify --print-certs "$APK" | sed -n '3,4p'
echo
echo "APK: $APK"
