#!/bin/sh
# 生成 btstandby 模块 zip：先编译 PAN 重连 app，再连脚本一起打包。
#
# 必须显式写 zip 里的权限位：Windows/NTFS 上 chmod 存不住，
# Magisk 安装时是按 zip 条目的 external_attr 解出可执行位的（同 btpan/make-module.sh）。
#
#   ./make-module.sh
# 产出：work/btstandby-module.zip
set -e

here=$(cd "$(dirname "$0")" && pwd)
work=$here/work
out=$work/btstandby-module.zip

echo "=== 编译 app ==="
"$here/app/build.sh" >/dev/null
apk=$here/app/build/BtPanStby.apk
[ -f "$apk" ] || { echo "APK 没编出来" >&2; exit 1; }

rm -rf "$work"
mkdir -p "$work/module/system/priv-app/BtPanStby"

# app 放到 priv-app：签名用的是 platform 密钥，priv-app 位置能让隐藏的权限检查也过
cp "$apk" "$work/module/system/priv-app/BtPanStby/BtPanStby.apk"

python3 - "$here/module" "$work/module" "$out" <<'PY'
import os, stat, sys, time, zipfile
src, stage, out = sys.argv[1], sys.argv[2], sys.argv[3]
files = [
    ("module.prop", 0o644),
    ("service.sh", 0o755),
    ("watch.sh", 0o755),
    ("uninstall.sh", 0o755),
    ("system/priv-app/BtPanStby/BtPanStby.apk", 0o644),
]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, mode in files:            # module.prop 必须在 zip 根目录
        path = os.path.join(stage if name.startswith("system/") else src, name)
        info = zipfile.ZipInfo(name, time.localtime(os.path.getmtime(path))[:6])
        info.external_attr = (stat.S_IFREG | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(path, "rb") as f:
            z.writestr(info, f.read())
print("zip entries:", ", ".join(n for n, _ in files))
PY

echo
echo "模块: $out ($(wc -c < "$out") bytes)"
