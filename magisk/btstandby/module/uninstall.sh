#!/system/bin/sh
# btstandby — 卸载：停掉守护进程（连同它的 logcat 子进程），清掉状态与日志

MODDIR=${0%/*}
p=$(cat "$MODDIR/.pid" 2>/dev/null)
[ -n "$p" ] && kill -9 -"$p" 2>/dev/null
rm -f "$MODDIR/.pid" "$MODDIR/.state" /data/local/tmp/btstandby.log
