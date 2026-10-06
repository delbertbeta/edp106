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
#       PAN 重连前先看 wifi_on：WiFi 开着就跳过，两者抢同一个 2.4G 前端。

MODDIR=${0%/*}
PIDF="$MODDIR/.pid"
LOGF=/data/local/tmp/btstandby.log
STATE="$MODDIR/.state"

echo $$ >"$PIDF"
trap 'rm -f "$PIDF"' EXIT

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOGF"; }

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
    if [ "$(cat "$STATE" 2>/dev/null)" != 1 ]; then
        log "screen on -> nothing to restore"
        return
    fi

    svc bluetooth enable
    log "screen on -> bluetooth restored"

    # WiFi 开着就**不碰 PAN**：BCM43436 是组合芯片，2.4G 前端共用。
    # 实测 PAN 连着的时候 WiFi 扫描回来 0 个 AP（RSSI -127），PAN 会把它挤掉。
    if [ "$(settings get global wifi_on 2>/dev/null)" = 1 ]; then
        log "screen on -> wifi is on, skip PAN reconnect"
        return
    fi

    # PAN 不会自己回来（AOSP 里 PAN 的 isAutoConnectable=false，实测重开蓝牙后
    # PanService 起来、代理连上，但没有任何一处调 connect()）。交给 app 去连。
    # --include-stopped-packages：app 没有 Activity，可能一直处于 stopped 状态。
    am broadcast --include-stopped-packages \
        -a com.delbert.btpan.RECONNECT -n com.delbert.btpan/.PanConnectReceiver \
        >/dev/null 2>&1
    log "screen on -> asked app to reconnect PAN (wifi off)"
}

log "=== started (bluetooth_on=$(settings get global bluetooth_on 2>/dev/null)) ==="

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
