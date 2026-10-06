# btstandby — 熄屏关蓝牙，亮屏按之前的状态恢复，并把 PAN 连回来

把 WiFi 的熄屏行为搬到蓝牙上，外加补上 ROM 没做的那半截：**PAN 恢复**。

ROM 在 `PowerManagerService` 里塞了一套「超级待机」：一进睡眠就 `setWifiEnabled(false)`，
但**不碰蓝牙**，而且 WiFi 关掉后亮屏也不会自己回来（`WIFI_ON` 被写成 0）。这个模块补的是蓝牙。

```
10-06 22:27:13.264 I/PowerManagerService: Going to sleep due to power button (uid 1000)...
10-06 22:27:13.264 W/PowerManagerService: Go to super standby...        ← 厂商加的
10-06 22:27:13.266 D/WifiService: setWifiEnabled: false pid=1959 ...    ← WiFi 被关
                                                                         ← 蓝牙没有对应动作
```

## 为什么除了脚本还得有个 app

熄屏关蓝牙、亮屏开蓝牙，纯 shell 就够（`svc bluetooth`）。**但 PAN 不会自己回来**：

```
23:00:41.191 PanService: Received start request. Starting profile...       ← profile 起来了
23:00:41.192 BluetoothPanServiceJni control_state_callback: ifname:bt-pan ← 接口也建了
23:00:41.304 BluetoothPan(2074): BluetoothPAN Proxy object connected      ← API 也接上了
                                                                          ← 没人调 connect()
```

AOSP 的 `CachedBluetoothDevice` 自动连接会按 `profile.isAutoConnectable()` 过滤，**PAN 是 false**
（A2DP/HFP/HID 是 true）。所以 PAN 只有两个入口：用户点勾选框，或某个 app 显式 `connect()`。

而 `connect()` 只能在 **真 app 进程**里调 —— `PanService` 不在 `servicemanager` 里（只有
`bluetooth_manager`），`cmd` 没实现，`app_process` 路线两条都实测死掉：

| 路线 | 结果 |
|---|---|
| `Context.getProfileProxy`（app_process） | `SecurityException: Unable to find app for caller ... when binding service` |
| `bluetooth_manager.bindBluetoothProfileService` + 手写 AIDL 回调 | 走到 `Creating new ProfileServiceConnections object for profile: 5` 后返回 `false` |

同一个根因：`bindService` 的调用方由 AMS 按 pid 归属，`app_process` 没有 app 记录。
所以这一小步（约 130 行）必须跑在 app 里 —— `app/` 就是它。

## 只连真的支持 NAP 的设备

不写死 MAC，也无脑试：查已配对设备的 **SDP 缓存**，只有带 **NAP（`0x1116`，蓝牙共享网络）**
的才连。本机实测：

```
DEV <翻页器 MAC> [LE] BLE-M3                    -> 只有 0x1812(HID)，无 NAP -> 跳过
DEV <手机 MAC>   [CLASSIC] 手机                 -> 有 0x1115(PANU)+0x1116(NAP) -> 只连它
```

UUIDS 没缓存时才退回「非 LE 单模」。所以换手机、加设备都不用改配置。

## 结构

```
app/                     PAN 重连 app（平台签名，装到 /system/priv-app）
  AndroidManifest.xml    只有一个 exported receiver
  src/.../PanConnectReceiver.java
  build.sh               aapt2 -> javac -> d8 -> aapt2 link -> zipalign -> apksigner
module/
  module.prop
  service.sh             Magisk late_start：拉起 watch.sh 单实例
  watch.sh               熄屏关 / 亮屏开；`maybe_reconnect_pan()` 在亮屏和开机各试一次
                          （蓝牙开着 + WiFi 关着才连 —— 两者抢同一个 2.4G 前端）
  uninstall.sh
make-module.sh           编译 app + 打包 zip
check.sh                 设备侧端到端自检
```

| 环节 | 做法 |
|---|---|
| 触发屏亮/屏灭 | `logcat -b events -T 1 -s screen_toggled:I`。**`-T 1` 不能省**：不加的话 logcat 会先把缓冲区里积压的历史事件整批吐出来，旧事件被当成刚发生的（实测一启动就 off→on→off 连发三次） |
| 开关蓝牙 | root 下 `svc bluetooth` |
| 记住熄屏前状态 | 熄屏时存 `settings get global bluetooth_on` 到 `.state`，只恢复**本模块关掉的**那一份 |
| PAN 重连 | `maybe_reconnect_pan()`：**蓝牙开着 + WiFi 关着**就连。亮屏时调（恢复蓝牙之后）、**开机也调** —— 开机那次 `screen_toggled:1` 会走到 `nothing to restore` 直接 return，所以必须在启动时自己调一次，不能只靠亮屏事件 |
| WiFi 闸门 | WiFi 开着就跳过 PAN 重连。BCM43436 是组合芯片，2.4G 前端共用；实测 PAN 连着时 WiFi 扫描回来 0 个 AP（RSSI -127），PAN 会把 WiFi 挤掉 |

两个坑：**开机要清 `.state`**（否则会把用户自己关掉的蓝牙又打开）；
**停止要用 PID 文件 + `kill -9 -<pgid>`**，不能用 `pkill -f`（模式会匹配到调用者自己的
cmdline 把自己杀了，而且 TERM 不一定生效，还会留下 logcat 孤儿进程）。

## 用法

```sh
./make-module.sh                                       # → work/btstandby-module.zip
adb push work/btstandby-module.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/btstandby-module.zip'
adb reboot
```

`make-module.sh` 需要 WSL 里的 build-tools（`aapt2`/`d8`/`zipalign`/`apksigner`，默认
`/opt/android-sdk/build-tools/35.0.0`）和 platform 密钥（复用 `navbar/keys/`）。

> 如果之前用 `adb install` 装过 `BtPanStby.apk`（调试时装的 `/data/app` 版本），
> 装模块前先 `adb uninstall com.delbert.btpan`，免得同一包名两份。

## 验证

```sh
adb shell su -c '/data/local/tmp/m/check.sh'        # 端到端自检（见下）
adb shell su -c 'cat /data/local/tmp/btstandby.log'
adb logcat -s BtPanStby
```

期望：

```
10-06 23:14:31 === started (bluetooth_on=1) ===
10-06 23:14:31 pan -> wifi is on, skip              ← 开机先试一次
10-06 23:14:37 screen off -> bluetooth off
10-06 23:14:44 screen on -> bluetooth restored
10-06 23:14:44 pan -> asked app to reconnect (bt on, wifi off)
I/BtPanStby: 跳过 <翻页器 MAC> BLE-M3（无 NAP）
I/BtPanStby: 发起连接 <手机 MAC> -> true
D/BluetoothPanServiceJni: connectPanNative(L193): in
D/PanService: LOCAL_PANU_ROLE:REMOTE_NAP_ROLE state = 1
```

`check.sh` 实测 7/7 通过。

## 回滚

Magisk app 里禁用本模块，或：

```sh
adb shell su -c 'rm -rf /data/adb/modules/btstandby'
adb reboot
```

`uninstall.sh` 会停掉守护进程、清掉 `.state` 和日志。app 随模块一起消失。

## 已知取舍

- 熄屏期间蓝牙**整个关断**，所以 BLE-M3 翻页器和 PAN 在睡眠时都不在。
  好处是 `bluesleep` 这个唤醒源也一起消失，少一个能把主机拽出挂起的东西。
- **PAN 真能连上取决于手机侧开着「蓝牙共享网络」。** 设备侧到这里没问题
  （`connectPanNative` 发得出去、`local_role=PANU/remote_role=NAP` 方向正确），
  手机没开的话会 `state:1 -> 2` 两秒后断开，现象是 `Failed to connect PAN device`。
- 不管 WiFi。ROM 自己会关，而且恢复行为**不稳定**：实测量到过亮屏后 system_server 自己调
  `setWifiEnabled: true`（`pid=1978, uid=1000, package=android`），也量到过不恢复。本模块不碰它。
- **WiFi 开着就不重连 PAN**（闸门）。代价是：如果 ROM 在亮屏时自己把 WiFi 开回来，
  PAN 就几乎不会再重连。想要 PAN 优先，就得把 WiFi 保持关着（实测关着时可靠命中重连）。
- PAN 和 WiFi 在这台机器上**互斥**：BCM43436 共用 2.4G 前端，实测 PAN 连着时 WiFi 扫描
  回来 0 个 AP、RSSI -127（软件层重启 WiFi 服务救不回来，得把 PAN 断掉）。
  所以“两个都要”做不到，只能二选一。
