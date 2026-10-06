#!/bin/sh
# 生成 btpan 模块：把 ROM 的 Bluetooth.apk 里 bool/profile_supported_pan 改成 true，
# 用原证书（AOSP platform）重签，打成可直接安装的 Magisk 模块 zip。
#
# 为什么是改 APK 而不是 RRO overlay：这个 bool 属于 com.android.bluetooth 自己的资源，
# 而设备上没有任何 overlay 覆盖它（/vendor/overlay 只有 framework-res 和 SystemUI 两个），
# 改资源文件是唯一确定的路子。dex 不动，所以 /system 里现成的 odex/vdex 仍然对得上。
#
#   SRC_APK=/path/to/Bluetooth.apk ./make-module.sh
# 产出：work/Bluetooth.apk（打过补丁、已签名）与 work/btpan-module.zip
set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
BT=${BT:-/opt/android-sdk/build-tools/35.0.0}
KEY=${KEY:-$root/navbar/keys/platform.pk8}
CERT=${CERT:-$root/navbar/keys/platform.x509.pem}
SRC_APK=${SRC_APK:-}

work=$here/work
apk=$work/Bluetooth.apk
out=$work/btpan-module.zip

if [ -z "$SRC_APK" ]; then
    echo "用法: SRC_APK=/path/to/Bluetooth.apk $0" >&2
    echo "（设备上: adb pull /system/app/Bluetooth/Bluetooth.apk）" >&2
    exit 1
fi

rm -rf "$work"
mkdir -p "$work"

echo "=== 1/4 打 resources.arsc 补丁 ==="
python3 "$here/patch-apk.py" "$SRC_APK" "$work/unsigned.apk"

echo "=== 2/4 自检 ==="
"$BT/aapt2" dump resources "$work/unsigned.apk" \
    | grep -A1 'bool/profile_supported_pan' | grep -v '^--$'
if "$BT/aapt2" dump resources "$work/unsigned.apk" | grep -A1 'bool/profile_supported_pan' | grep -q false; then
    echo "补丁没生效，中止" >&2
    exit 1
fi

echo "=== 3/4 zipalign + 用 platform 密钥重签 ==="
"$BT/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
"$BT/apksigner" sign \
    --key "$KEY" --cert "$CERT" \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$apk" "$work/aligned.apk"
"$BT/apksigner" verify --print-certs "$apk" | sed -n '2,3p'
rm -f "$work/unsigned.apk" "$work/aligned.apk"

echo "=== 4/4 打包模块 ==="
stage=$work/module
mkdir -p "$stage/system/app/Bluetooth"
cp "$here/module/module.prop" "$here/module/post-fs-data.sh" "$here/module/uninstall.sh" "$stage/"
cp "$apk" "$stage/system/app/Bluetooth/Bluetooth.apk"

# zip 里显式写权限位：NTFS 上 chmod 存不住，Magisk 安装时会照 external_attr 解出来
python3 - "$stage" "$out" <<'PY'
import os, stat, sys, time, zipfile
stage, out = sys.argv[1], sys.argv[2]
files = [
    ("module.prop", 0o644),
    ("post-fs-data.sh", 0o755),
    ("uninstall.sh", 0o755),
    ("system/app/Bluetooth/Bluetooth.apk", 0o644),
]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, mode in files:            # module.prop 必须在 zip 根目录
        path = os.path.join(stage, name)
        info = zipfile.ZipInfo(name, time.localtime(os.path.getmtime(path))[:6])
        info.external_attr = (stat.S_IFREG | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(path, "rb") as f:
            z.writestr(info, f.read())
print("zip entries:", ", ".join(n for n, _ in files))
PY

echo
echo "APK:    $apk"
echo "模块:   $out ($(wc -c < "$out") bytes)"
