#!/system/bin/sh
# btstandby — Magisk late_start 阶段开机自启
#
# 只负责把 watch.sh 拉起成单实例；逻辑全在 watch.sh 里。
# 必须用 setsid：这样 watch.sh 自成会话/进程组（pgid == 它的 pid），
# 停的时候 kill -9 -<pid> 能把 watch.sh 和它下面的 logcat 一起收掉。
# 不用 pkill -f：模式会匹配到调用者自己那条 sh -c 的 cmdline，把自己杀了。

MODDIR=${0%/*}
PIDF="$MODDIR/.pid"
LOGF=/data/local/tmp/btstandby.log

# 收掉上一次那份（含赖着的 logcat 子进程）
old=$(cat "$PIDF" 2>/dev/null)
[ -n "$old" ] && kill -9 -"$old" 2>/dev/null
rm -f "$PIDF" "$MODDIR/.state"          # 状态要清：否则会把用户自己关掉的蓝牙又打开

: >"$LOGF"                              # 每次开机重开一份日志
chmod 755 "$MODDIR/watch.sh" 2>/dev/null
setsid "$MODDIR/watch.sh" >/dev/null 2>&1 &
