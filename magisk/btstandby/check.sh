#!/system/bin/sh
# btstandby 端到端自检：熄屏关蓝牙 -> 亮屏开蓝牙 -> 自动重连 PAN。
# 会真的切屏和开关蓝牙，跑完恢复跑之前的状态。
#
#   adb push module/service.sh module/watch.sh check.sh /data/local/tmp/m/
#   adb shell su -c 'chmod 755 /data/local/tmp/m/* && /data/local/tmp/m/check.sh'
#
# 前提：BtPanStby.apk 已安装。PAN 真能连上还取决于手机侧开着「蓝牙共享网络」。

M=/data/local/tmp/m
L=/data/local/tmp/btstandby.log
BT() { settings get global bluetooth_on; }
stopit() { p=$(cat "$M/.pid" 2>/dev/null); [ -n "$p" ] && kill -9 -"$p" 2>/dev/null; }
fail=0
chk() { [ "$2" = "$3" ] && echo "  ok   $1=$2" || { echo "  FAIL $1=$2 (期望 $3)"; fail=1; }; }

ORIG=$(BT); echo "跑之前 bt=$ORIG"
stopit; rm -f "$M/.state" "$L"
logcat -c
setsid "$M/watch.sh" >/dev/null 2>&1 & sleep 2

echo "[1] 启动后不该有动作"
chk bt "$(BT)" 1
chk 日志行数 "$(wc -l <"$L")" 1

echo "[2] 熄屏 -> 关蓝牙"
input keyevent 26; sleep 7
chk bt "$(BT)" 0

echo "[3] 亮屏 -> 开蓝牙 + 触发 PAN 重连"
input keyevent 26; sleep 18
chk bt "$(BT)" 1
echo "  --- app 侧日志 ---"
logcat -d -b all -v time | grep -E "BtPanStby|connectPanNative" | tail -6 | sed 's/^/  /'

echo "[4] 停止要干净"
stopit; sleep 2
chk "watch.sh 残留" "$(pgrep -f '[/]watch\.sh' | wc -l)" 0
chk "logcat 残留" "$(pgrep -f 'screen_toggled' | wc -l)" 0

echo "=== watch.sh 日志 ==="; cat "$L"
[ "$ORIG" = 1 ] && svc bluetooth enable || svc bluetooth disable
sleep 2; echo "恢复后 bt=$(BT)"
[ $fail = 0 ] && echo "全部通过" || echo "有失败项"
exit $fail
