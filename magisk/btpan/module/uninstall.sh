#!/system/bin/sh
# 卸载/移除模块时把那条缓存也清掉，让下次开机用原厂 APK 重新解析，
# 否则缓存里还留着"PanService enabled=true"的旧结论（无害，但不干净）。
for d in /data/system/package_cache/*/; do
    for f in "$d"Bluetooth-* "$d"Bluetooth.apk-*; do
        [ -f "$f" ] && rm -f "$f"
    done
done
