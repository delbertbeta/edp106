#!/system/bin/sh
# btstandby — 熄屏关蓝牙，亮屏按熄屏前的状态恢复。行为同 WiFi：熄屏即关。
#
# 触发：events 缓冲区里的 screen_toggled（0=屏灭，1=屏亮）。这个缓冲区噪音极低
#       （实测 14 秒只有 37 行），比轮询 dumpsys 省。
#       必须带 -T 1：不加的话 logcat 会先把环形缓冲区里积压的历史事件整批吐出来，
#       旧事件被当成刚发生的（实测一启动就 off→on→off 连发三次）。-T 1 只吐最后
#       一行（会被 -s 过滤掉）然后开始跟随，既不重放，也没有 -d/-c 的竞态和副作用。
# 开关：root 下调 svc bluetooth（实测无 SecurityException）。
# 记忆：熄屏前把 settings global bluetooth_on 存进 .state，只恢复「本模块自己关掉的」。
#
# PAN 重连走 maybe_reconnect_pan()：**蓝牙开着 + WiFi 关着**就连。
#   亮屏时调（恢复蓝牙之后）、开机也调（所以重启后不再需要手动勾）——
#   开机那次 screen_toggled:1 会走到 "nothing to restore" 直接 return，
#   所以必须在启动时自己调一次，不能只靠亮屏事件。

MODDIR=${0%/*}
PIDF="$MODDIR/.pid"
LOGF=/data/local/tmp/btstandby.log
STATE="$MODDIR/.state"

echo $$ >"$PIDF"
trap 'rm -f "$PIDF"' EXIT

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOGF"; }

# 蓝牙开着 + WiFi 关着才连 PAN。
# WiFi 开着就**不碰 PAN**：BCM43436 是组合芯片，2.4G 前端共用。
# 实测 PAN 连着的时候 WiFi 扫描回来 0 个 AP（RSSI -127），PAN 会把它挤掉。
# 返回 0 = 真的把广播发出去了；非 0 = 被条件挡下（调用方据此决定要不要重试）。
maybe_reconnect_pan() {
    if [ "$(settings get global bluetooth_on 2>/dev/null)" != 1 ]; then
        log "pan -> bluetooth is off, skip"
        return 2
    fi
    if [ "$(settings get global wifi_on 2>/dev/null)" = 1 ]; then
        log "pan -> wifi is on, skip"
        return 3
    fi

    # PAN 不会自己回来（AOSP 里 PAN 的 isAutoConnectable=false，实测重开蓝牙后
    # PanService 起来、代理连上，但没有任何一处调 connect()）。交给 app 去连。
    # --include-stopped-packages：app 没有 Activity，可能一直处于 stopped 状态。
    am broadcast --include-stopped-packages \
        -a com.delbert.btpan.RECONNECT -n com.delbert.btpan/.PanConnectReceiver \
        >/dev/null 2>&1
    log "pan -> asked app to reconnect (bt on, wifi off)"
    return 0
}

pan_connected() {
    dumpsys bluetooth_manager 2>/dev/null \
        | sed -n '/mPanDevices/,/^Profile:/p' \
        | grep -qE '([0-9A-Fa-f]{2}:){5}'
}

# 重试到连上为止。
# 为什么必须重试：svc bluetooth enable 是异步的，settings 里的 bluetooth_on 要十几秒后才翻成 1。
# 亮屏后立刻调一次的话，会读到还没翻过来的 0，直接被当作“蓝牙没开”跳过（实测就是这个 bug）。
# rc=3（WiFi 开着）是政策上不连，直接放弃；rc=2（蓝牙还没起来）是瞬时状态，等下一轮。
reconnect_pan_retry() {
    n=0
    while [ "$n" -lt 8 ]; do
        maybe_reconnect_pan
        [ $? = 3 ] && break
        pan_connected && break
        n=$((n + 1))
        [ "$n" -lt 8 ] && sleep 5
    done
}

screen_off() {
    prev=$(settings get global bluetooth_on 2>/dev/null)
    echo "$prev" >"$STATE"
    if [ "$prev" = 1 ]; then
        svc bluetooth disable
        log "screen off -> bluetooth off"
    else
        log "screen off -> bluetooth already off, nothing to do"
    fi
}

screen_on() {
    if [ "$(cat "$STATE" 2>/dev/null)" = 1 ]; then
        svc bluetooth enable
        log "screen on -> bluetooth restored"
        reconnect_pan_retry
    else
        log "screen on -> nothing to restore"
        maybe_reconnect_pan
    fi
}

log "=== started (bluetooth_on=$(settings get global bluetooth_on 2>/dev/null)) ==="

# 开机也连：重启后不用再手动勾。开机早期蓝牙栈和 app 都还没就绪，同样靠重试。
reconnect_pan_retry

# logcat 退出（被杀 / 缓冲区异常）就 2 秒后重来，保证守护进程不会静默死掉
while true; do
    logcat -b events -v time -T 1 -s screen_toggled:I | while read -r l; do
        case "${l##*: }" in
            0) screen_off ;;
            1) screen_on  ;;
        esac
    done
    sleep 2
done
