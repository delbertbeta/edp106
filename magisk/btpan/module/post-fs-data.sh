#!/system/bin/sh
# PMS 把解析好的 APK 结构缓存在 /data/system/package_cache/<user>/<apk 名>-<n>，
# 而且不校验 APK 有没有被改过。缓存里记着 PanService 的 enabled=false
# （ROM 编译时 profile_supported_pan=false 解析出来的那个值），不清掉的话
# 我们改过的 bool 对 PMS 永远不生效 —— 组件照样"not found"，PanService 起不来。
#
# 本脚本在 post-fs-data 阶段跑（早于 zygote / PMS 扫描），所以删掉后
# PMS 会用打过补丁的 APK 重新解析并重建缓存。
# 注意：glob 的 * 必须写在引号外面，否则是字面量。
LOG=/data/local/tmp/btpan.log
echo "$(date '+%m-%d %H:%M:%S') post-fs-data: clearing PMS package_cache for Bluetooth" >> $LOG

for d in /data/system/package_cache/*/; do
    for f in "$d"Bluetooth-* "$d"Bluetooth.apk-*; do
        if [ -f "$f" ]; then
            rm -f "$f" && echo "  removed $f" >> $LOG
        fi
    done
done
