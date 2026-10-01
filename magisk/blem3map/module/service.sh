#!/system/bin/sh
# blem3map — Magisk late_start 阶段开机自启
#
# 守护进程只做一件事：独占抓取 BLE-M3，把它的鼠标手势翻译成按键。
# 蓝牙可能在开机后才连上，设备没出现时它自己会等，所以这里只负责拉起单实例。

MODDIR=${0%/*}
BIN="$MODDIR/blem3map"
LOG=/data/local/tmp/blem3map.log

pkill -x blem3map 2>/dev/null          # 单实例（手动跑过的那份也会被收掉）
chmod 755 "$BIN" 2>/dev/null
: > "$LOG"                             # 每次开机重开一份日志

# uinput / 设备节点可能还没就绪；异常退出就 5 秒后重来
( while true; do "$BIN" >>"$LOG" 2>&1; sleep 5; done ) &
