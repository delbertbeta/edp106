# btpan — 把 ROM 关掉的蓝牙 PAN 打开（「用于 → 互联网连接」）

## 现象

设置 → 蓝牙 →（已配对的手机）→ 右侧齿轮 →「用于」里的 **互联网连接** 勾选框点不上：

```
I/CachedBluetoothDevice: Failed to connect PAN to <手机名>
```

不是置灰（实测 `enabled=true`、能点），是点完立刻回弹。**没有任何运行时开关能打开它** ——
不是设置问题，也不是 root 能改的设置项。

## 根因：ROM 编译时把 PAN 关了两道

**第一道，资源开关。** 设备上 `com.android.bluetooth` 的 `bool/profile_supported_pan = false`。
AOSP 的 `btservice/Config.java` 里 `Config.init()` 用
`resources.getBoolean(R.bool.profile_supported_*)`（再看 `Settings.Global.bluetooth_disabled_profiles`
的位掩码，设备上是 `0`，不是它挡的）决定 `SUPPORTED_PROFILES`，`AdapterService` 只启动这些
profile 服务。设备上只有 `gatt` / `hid` / `opp` 三个 bool 为 true，正好就是实际在跑的三个服务
（`W/AdapterServiceConfig: Could not find profile bit mask` 那条警告对应 OPP 没有 index 映射，是旁证）。

而 manifest 里每个 profile service 又都写成 `android:enabled="@bool/profile_supported_*"`
（`aapt2 dump xmltree` 可见），所以**同一个 bool 关掉了两件事**：PanService 不启动，
而且这个组件对 PMS 来说是 disabled 的。`am startservice -n com.android.bluetooth/.a2dp.A2dpService`
这类实验能复现：bool=false 的组件一律 `Not found; no service started`。

**第二道，PMS 的解析缓存。** `/data/system/package_cache/<user>/Bluetooth-65` 里存着 PMS
"解析好的 APK 结构"（UTF-16 的组件名都在里面），**而且 PMS 不校验 APK 有没有被改过** ——
把打过补丁的 APK 挂上去重启之后，这个文件的 mtime 还停在 `2025-01-13 23:28`。
于是 PMS 仍然认为 PanService 是 disabled，ActivityManager 直接拒绝：

```
D/AdapterServiceConfig: Adding PanService                                   <- App 自己读到了新 bool
D/BluetoothAdapterService: setProfileServiceState() - Starting service ...PanService
W/ActivityManager: Unable to start service Intent { cmp=.../.pan.PanService (has extras) } U=0: not found
```

> 这条对以后**任何替换预装 APK 的改造**都成立：改完 APK 还得让 PMS 重新解析
> （删掉对应 package_cache，或干脆换签名/包名让它当成新包）。

框架和原生本来都支持 PAN，只被 Java 层挡住：framework 侧 `tetherableBluetoothRegexs: [bt-pan]`；
`libbluetooth_jni.so` 里有 `register_com_android_bluetooth_pan` / `enablePanNative` / `getPanLocalRoleNative`；
原生栈 `/system/lib/hw/bluetooth.default.so` 里有 BNEP；`/etc/bluetooth/bt_stack.conf` 里有 `TRC_BNEP` / `TRC_PAN`。

## 模块做了什么

1. **`system/app/Bluetooth/Bluetooth.apk`** —— 原厂 APK 的 `resources.arsc` 里
   `0x7f010012`（`bool/profile_supported_pan`）的值 `false` 改成 `true`。
   整个 APK 逐字节比对后**只有 resources.arsc 偏移 522172 这 1 个字节不同**，
   manifest 与其它条目完全一致；APK 本来就没有 classes.dex（ROM 把代码剥到
   `/system/app/Bluetooth/oat/` 里了），所以不动 oat、现成的 odex/vdex 继续有效。
   改完用**与原厂相同的密钥**重签：设备上的 `Bluetooth.apk` 就是 AOSP `platform`
   密钥签的（SHA-256 `C8:A2:E9:…:2A:B8`，密钥在 `navbar/keys/`），证书指纹不变，
   PMS 的签名校验照过。
2. **`post-fs-data.sh`** —— 在 zygote / PMS 扫描之前删掉那条 package_cache，
   让 PMS 用打过补丁的 APK 重新解析；**`uninstall.sh`** 卸载时也清一次，回滚干净。

只开了 `pan` 这一个 bool。`a2dp` / `hfp` / `map` / `pbap` / `sap`… 仍然是 false，没动 ——
不需要（YAGNI），要开哪个再说。

## 用法

```sh
adb pull /system/app/Bluetooth/Bluetooth.apk tmp/                 # 原厂 APK（md5 见下）
SRC_APK=tmp/Bluetooth.apk ./make-module.sh                        # → work/btpan-module.zip
adb push work/btpan-module.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/btpan-module.zip'
adb reboot
```

`make-module.sh` 需要 WSL 里的 build-tools（`aapt2`/`zipalign`/`apksigner`，默认
`/opt/android-sdk/build-tools/35.0.0`）和 `python3`；脚本会自己核对补丁是否生效
（`aapt2 dump resources` 里 `profile_supported_pan` 必须是 `true`）、并打印签名指纹。

原厂 APK 基准：

| 文件 | 设备路径 | 大小 | md5 |
|---|---|---|---|
| `Bluetooth.apk`（原厂） | `/system/app/Bluetooth/Bluetooth.apk` | 847,455 | `0aeaad2760098287c03246e5f3229d5c` |
| `Bluetooth.apk`（本模块） | 同上（模块挂载） | 850,277 | `3e75115573d77e38ece3b4f6453b897e` |

## 验证（改完重启后实测）

```sh
su -c 'dumpsys activity services com.android.bluetooth'   # 多了 com.android.bluetooth/.pan.PanService
su -c 'dumpsys bluetooth_manager'                          # 多了 Profile: PanService / mPanIfName: bt-pan
logcat | grep -i pan
```

```
D/AdapterServiceConfig: Adding PanService
D/BluetoothAdapterService: setProfileServiceState() - Starting service com.android.bluetooth.pan.PanService
D/PanService: Received start request. Starting profile...
```

点「互联网连接」勾选框（`package-restrictions.xml` 里没有任何 `pm enable` 残留，纯靠 APK 自己）：

```
D/BluetoothPan: BluetoothPAN Proxy object connected
D/BluetoothPan: connect(<手机 MAC>)
I/bt_stack: [INFO:bnep_api.cc(132)] BNEP_Connect BDA:<手机 MAC>
D/BluetoothPanServiceJni: connection_state_callback: state:1, local_role:2, remote_role:1
D/PanService: handlePanDeviceStateChange LOCAL_PANU_ROLE:REMOTE_NAP_ROLE state = 1
```

`local_role=PANU / remote_role=NAP` 正是"电纸书用手机的网"这个方向，BNEP 也真的发到手机了。
随后 `state:2 → 0`、`Failed to connect PAN device`，是因为**手机那侧没开「蓝牙共享网络」**
（手机 NAP 不接受 PANU）。设备侧到这里已经通了，剩下一步在手机上。

BLE-M3（HID）与蓝牙文件传输不受影响：改完重启后 `HidService` / `BluetoothOppService` /
`GattService` 照常运行，两个已配对设备都还在。

## 回滚

```sh
# 立即回滚：删掉模块目录（或 Magisk app 里禁用）后重启
adb shell su -c 'rm -rf /data/adb/modules/btpan /data/adb/modules_update/btpan'
adb reboot
```

卸载时 `uninstall.sh` 会把那条 package_cache 也清掉，下次开机 PMS 用原厂 APK 重新解析，
`PanService` 回到 disabled、"互联网连接"重新勾不上 —— 即原状。

## 已知取舍 / 待验证

- **手机侧必须开「蓝牙共享网络」**（小米：设置 → 蓝牙 → 该设备/蓝牙共享网络），
  否则 BNEP 连上就断，现象就是上面那条 `Failed to connect PAN device`。
- PAN 带宽比 Wi-Fi 差很多，只适合临时上网。
- 每次开机都会删一次那条 package_cache（PMS 于是重新解析一次 `Bluetooth.apk`，
  代价可以忽略），换来确定性：不受"缓存里有旧结论"影响。
- `Resources`/`Config` 只在 App 进程里被读，所以补丁 APK 必须真的被 App 用上；
  模块挂的是 `/system/app/Bluetooth/Bluetooth.apk` 单文件，不碰目录里其它文件。
