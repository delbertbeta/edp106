#!/bin/sh
# 交叉编译 blem3map（armv7a / Android 8.1 / API 27）。需要 Android NDK。
# 覆盖：NDK=/path/to/ndk API=27 ./build.sh
set -e

API=${API:-27}
here=$(cd "$(dirname "$0")" && pwd)

if [ -z "$NDK" ]; then
    for d in "$ANDROID_NDK_HOME" "$ANDROID_NDK_ROOT" /opt/android-sdk/ndk/*; do
        [ -d "$d" ] && NDK=$d
    done
fi
[ -d "$NDK" ] || { echo "找不到 NDK，请 NDK=/path/to/ndk $0" >&2; exit 1; }

for c in "$NDK"/toolchains/llvm/prebuilt/*/bin/armv7a-linux-androideabi$API-clang; do
    CC=$c
done
[ -x "$CC" ] || { echo "找不到编译器 $CC" >&2; exit 1; }

"$CC" -O2 -Wall -Wextra -o "$here/blem3map" "$here/blem3map.c"
echo "built: $here/blem3map ($(wc -c < "$here/blem3map") bytes)"
