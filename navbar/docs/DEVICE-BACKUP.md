# EPD106 原厂文件备份 / navbar 改造前基线

备份时间：2026（改造开始前，设备未做任何修改）
设备：Allwinner **EPD106** (`virgo_perf1` / `virgo-perf1`)，Android 8.1.0 (API 27)，`ro.build.fingerprint=Allwinner/virgo_perf1/virgo-perf1:8.1.0/OPM1.171019.026/20231122-142053:user/test-keys`

## 文件清单（md5 已与设备端 `md5sum` 逐一核对一致）

| 文件 | 设备路径 | 大小 | md5 |
|---|---|---|---|
| `framework-res.apk` | `/system/framework/framework-res.apk` | 48,012,027 | `6f379142955dc4bd2abe609a4cecaa12` |
| `SystemUI.apk` | `/system/priv-app/SystemUI/SystemUI.apk` | 11,603,501 | `23c51c60f3ac589ae4ebf46ca4ac6f5c` |
| `SystemUI.odex` | `/system/priv-app/SystemUI/oat/arm/SystemUI.odex` | 82,400 | `47bd36368b32c4e3fa94e510e86a7dbd` |
| `SystemUI.vdex` | `/system/priv-app/SystemUI/oat/arm/SystemUI.vdex` | 5,376,876 | `dffcbbd7c944c8d63cf8754e770b59fc` |
| `framework-res__auto_generated_rro.apk` | `/system/vendor/overlay/framework-res__auto_generated_rro.apk` | 1,367,554 | `1159d0bd7a1a9dfd110472f99b124fc4` |
| `SysuiDarkThemeOverlay.apk` | `/system/vendor/overlay/SysuiDarkTheme/SysuiDarkThemeOverlay.apk` | 6,406 | `81f623f44ea86b236bf42e173904be4a` |

`state/` 目录是同期抓的设备运行时状态快照（overlay dump/list、window displays/policy/windows、
`dumpsys package android`、settings secure/global/system、getprop、包列表、`ls -lR /system/vendor/overlay`）。

## 恢复方法

**前提：需要 root。** 当前固件是 `user` + `ro.secure=1`，无 `su`，`adb root` 报
`adbd cannot run as root in production builds`，`/system` 对 shell 只读且部分路径 `ls` 都 Permission denied。
所以本备份**无法在无 root 状态下自动写回**，它的作用是：拿到 root / 刷机后作为逐字节还原基准。

拿到 root 后：

```sh
adb push framework-res.apk /data/local/tmp/
adb shell su -c 'mount -o rw,remount /system'
adb shell su -c 'cp /data/local/tmp/framework-res.apk /system/framework/framework-res.apk'
adb shell su -c 'chown root:root /system/framework/framework-res.apk && chmod 644 /system/framework/framework-res.apk'
adb shell su -c 'restorecon /system/framework/framework-res.apk'
# SystemUI 同理；oat/arm/*.odex|vdex 若被改过也要一起还原
```

> 注：改造方案（`/data` 侧 RRO overlay）**完全不碰 `/system`**，本备份是回滚保险，不是回滚手段。

## 关键发现（探测结论）

1. 设备当前**没有导航栏窗口**，`dumpsys window 2 | grep mStable` = `mStable=(0,40)-(758,1024)`，
   app 可用区 `app=758x960`（只有 40px 状态栏）。
2. 所有"运行时开关"全部堵死：
   - `settings put secure navigation_mode` → 8.1 无此机制（Android 10+ 才有）
   - `cmd overlay enable-exclusive …` / `cmd overlay fabricate` → 8.1 的 `cmd overlay` 没有这两个子命令
   - `setprop qemu.hw.mainkeys 0` → `failed to set property`（Enforcing + user build，
     这是 AOSP 8.1**唯一**的运行时导航栏开关，见 `PhoneWindowManager.java:2237-2246`）
3. 根因是框架资源：**`framework-res.apk` 里 `bool/config_showNavigationBar = false`**（`0x01120094`）。
   `PhoneWindowManager.hasNavigationBar()` 直接返回它，`StatusBar.java:1074` 用它决定 `createNavigationBar()`。
4. ROM 自带的 `/vendor/overlay/framework-res__auto_generated_rro.apk` 是个 **37 项**的静态 RRO，
   里面**已经把 `config_showNavigationBar` 覆盖为 `true`**，而且**确实生效**
   （同 RRO 的 `integer/config_minimumScreenOffTimeout=3000`、`bool/config_unplugTurnsOnScreen=true`
   在 `dumpsys power` 里都读得到，基线值分别是 10000 / false）。
   **修正**：早前"vendor RRO 未生效"的推断是错的（误读了 `dumpsys power` 的输出）。
   真实结论是——框架里这个开关**早就是 true**，导航栏窗口仍不出现，所以卡点在 SystemUI 代码，不在资源。
5. `framework-res.apk` 用**公开的 AOSP `platform` 密钥**签名 —— SHA-1 `27196E386B875E76ADF700E7EA84E4C6EEE33DFA`、
   SHA-256 `C8:A2:E9:…:2A:B8`，与 AOSP `build/target/product/security/platform` 精确一致。
   `platform.pk8` 私钥公开，已存进仓库 [`../keys/`](../keys/)。
   （**修正**：早前记的 `27196E38…` 被标成 SHA-256，实际上 `.NET` 的 `X509Certificate2.Thumbprint`
   返回的是 SHA-1；且它是 platform 密钥，不是 testkey。）
6. SystemUI.apk 里导航栏代码/资源**齐全**（`res/layout/navigation_bar`、`navigation_layout`、
   `res/xml/nav_bar_tuner`、`NavigationBarFragment`、`NavigationBarView`），只是被开关关掉。
7. `/system/priv-app/SystemUI/SystemUI.odex` 只有 **82,400 字节**（正常应数 MB），而 `SystemUI.vdex`
   有 5.3MB → SystemUI 走 odex/vdex（`boot.art` 类预编译），不是纯解释执行。
