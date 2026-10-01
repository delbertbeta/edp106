#!/bin/sh
# 把 blem3map 打成一个可直接在 Magisk 里安装的模块 zip。
# 依赖：NDK（见 build.sh）、python3（只用它的 zipfile，省得依赖 zip 命令）。
# 产出：work/blem3map-module.zip
set -e

here=$(cd "$(dirname "$0")" && pwd)
stage="$here/work/module"
out="$here/work/blem3map-module.zip"

sh "$here/build.sh"

rm -rf "$stage"
mkdir -p "$stage"
cp "$here/blem3map" "$here/module/module.prop" "$here/module/service.sh" \
   "$here/module/uninstall.sh" "$stage/"
chmod 755 "$stage/blem3map" "$stage/service.sh" "$stage/uninstall.sh"
chmod 644 "$stage/module.prop"

python3 - "$stage" "$out" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
names = ["module.prop", "service.sh", "uninstall.sh", "blem3map"]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for n in names:
        z.write(os.path.join(stage, n), n)      # module.prop 必须在 zip 根目录
print("zip entries:", ", ".join(names))
PY

echo "built: $out ($(wc -c < "$out") bytes)"
