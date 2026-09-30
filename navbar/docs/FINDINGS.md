# EPD106 底部三键导航栏 —— 根因定位与方案

设备：Allwinner **EPD106** (`virgo_perf1`/`virgo-perf1`)，Android 8.1.0 (API 27)，
`user` build / `ro.secure=1` / 无 `su` / `adb root` 被拒 / `/system` 只读。

所有结论均来自设备实机产物（`dumpsys`、设备 APK 资源、设备 vdex 反编译），不是推测。

---

## 一、根因：厂商删掉了 SystemUI 里创建导航栏窗口的那一句

### 1.1 框架侧是原版的，而且完整支持导航栏

`services.vdex` → `PhoneWindowManager` 反编译（baksmali 拆出的 smali 工作区用完就删了，按需重拆）：

```smali
# setInitialDisplaySize()  .line 2489-2496
const v0, 0x1120094                    # bool/config_showNavigationBar
invoke-virtual {v4, v0}, Landroid/content/res/Resources;->getBoolean(I)Z
iput-boolean v0, p0, Lcom/android/server/policy/PhoneWindowManager;->mHasNavigationBar:Z
const-string/jumbo v0, "qemu.hw.mainkeys"
# == "1" -> mHasNavigationBar = false   （与 AOSP 8.1 完全一致）
```

`prepareAddWindowLw()` 的 TYPE 分发表：

```
0x7d0 -> :sswitch_9     # TYPE_STATUS_BAR        -> 校验 STATUS_BAR_SERVICE, mStatusBar = win
0x7e3 -> :sswitch_2e    # TYPE_NAVIGATION_BAR    -> 校验 STATUS_BAR_SERVICE, mNavigationBar = win
```

`layoutWindowLw()` 里有 `const/16 v3, 0x7e3` 分支负责摆放导航栏窗口。
`updateSystemUiVisibilityLw`/`systemBars` 那一带仍按 `mHasNavigationBar` 计算底部 inset。

结论：**框架没有任何一处被裁剪**，只要有一个 `TYPE_NAVIGATION_BAR` 窗口被添加，
框架就会绑定它、摆到屏幕底部、并把 app 可用区往上收。

### 1.2 卡点在 SystemUI：`createNavigationBar()` 被删除

`SystemUI.vdex` → `StatusBar.smali`，方法 `makeStatusBarView()`（行 17706 起）：

```
.line 1089
    iget-object v0, p0, ...->mWindowManager:Landroid/view/IWindowManager;
    invoke-interface {v0}, Landroid/view/IWindowManager;->hasNavigationBar()Z
    move-result v0
.line 1099                 <-- 注意：1090..1098 一条指令都没有
    const/4 v0, -0x1
    #iput-quick v0, p0, ...field@0x298
```

AOSP 8.1 对应区间是：

```java
1074  boolean showNav = mWindowManagerService.hasNavigationBar();
1075  if (DEBUG) Log.v(TAG, "hasNavigationBar=" + showNav);
1076  if (showNav) {
1077      createNavigationBar();
1078  }
1079  } catch (RemoteException ex) { ... }   // 1080-1081
```

厂商把 1075-1081（判断 + 调用 + catch）整段删掉了，只留下一次没人用的
`hasNavigationBar()` 调用。全文件搜 `createNavigationBar` **零命中** —— 方法也被删了。
`StatusBar.smali` 还留着 `mNavigationBar` 字段（行 352）和 `getNavigationBarView()`（行 14247），
但没有任何调用者。

### 1.3 厂商把导航键改放进了状态栏

- SystemUI 资源里有 AOSP 不存在的 id：
  - `my_stat_home_img_view` = `0x7f0a01ca`
  - `my_stat_more_img`   = `0x7f0a01cb`
- 使用者是 `com.android.systemui.statusbar.phone.PhoneStatusBarTransitions`（行 935 / 1244）。
- 实机截图：状态栏左上角 `x=45..63, y=37..55` 有一个 `‹` 返回图标，而 `StatusBar`
  窗口 frame 只有 `[0,0][758,40]` —— 图标大半画在状态栏窗口下边界之外，且 `super_status_bar.xml`
  的根 `StatusBarWindowView` 没有 `clipChildren=false`，说明这个 `‹` 是**直接渲染到 framebuffer（图层合成）**上的，
  基本可以确定是墨水屏 UI 的图层合成改造，不是普通 Android 视图。

---

## 二、为什么"装个 RRO 打开 config_showNavigationBar"这条路是死的

1. ROM 自带的 `/vendor/overlay/framework-res__auto_generated_rro.apk`（**静态 RRO，37 项**）
   里**已经把 `config_showNavigationBar` 覆盖为 `true`**，而且这个 RRO **确实生效**
   （同 RRO 的 `integer/config_minimumScreenOffTimeout=3000`、`bool/config_unplugTurnsOnScreen=true`
   在 `dumpsys power` 里都能读到，基线值分别是 10000 / false）。
2. 所以框架里 `config_showNavigationBar` 早就是 `true`，`hasNavigationBar()` 早就是 `true`。
3. 但导航栏窗口从来没人创建 —— 因为该创建它的那句代码被厂商删了。
4. **RRO 只能改资源，不能改代码。** 因此无论我们再怎么覆盖资源，导航栏都不会出现。

（之前"vendor RRO 未生效"的推断是错的：我把 `dumpsys power` 的
`Config=3000` 误读成"没读到"。重新核准后确认 3000 = RRO 的值，不是基线值。）

---

## 三、签名：设备用的是公开的 AOSP `platform` 密钥

| | SHA-1 | SHA-256 |
|---|---|---|
| 设备 `framework-res.apk` 签名者 | `27196E386B875E76ADF700E7EA84E4C6EEE33DFA` | `C8:A2:E9:BC:CF:59:7C:2F:B6:DC:66:BE:E2:93:FC:13:F2:FC:47:EC:77:BC:6B:2B:0D:52:C1:1F:51:19:2A:B8` |
| AOSP `platform` 密钥 | 同上 ✓ | 同上 ✓ |
| AOSP `testkey` | `61ED377E85D386A8DFEE6B864BD85B0BFAA5AF81` | `A4:0D:…` （**不是**它） |

`platform.pk8`（2048-bit RSA 私钥，公开于 AOSP `build/target/product/security/`）已下载到
[`../keys/platform.{x509.pem,pk8}`](../keys/)（仓库内），`openssl pkcs8 -inform DER -nocrypt` 可正常解出。

**含义**：我们可以产出真正 platform 签名的 APK，从而声明 `signature` 级权限 ——
这正是添加 `TYPE_NAVIGATION_BAR` 窗口所需的 `android.permission.STATUS_BAR_SERVICE` 的门槛。

---

## 四、可行的路线

### 路线 A（免 root，推荐）：platform 签名的辅助 App 添加真·导航栏窗口

在 `/data` 安装一个 platform 签名的 App：

- 声明权限：`android.permission.STATUS_BAR_SERVICE`（signature 级，platform 签名可授予）
- 用 `WindowManager.addView` 添加 `TYPE_NAVIGATION_BAR`（2019）窗口，贴底，高度用
  `dimen/navigation_bar_height`
- 画 Back / Home / Recents 三个键（可用 `PhoneWindowManager` 认可的 drawable，或自绘）
- 点击 → 注入 `KeyEvent`（`INJECT_EVENTS` 也是 signature 级，platform 签名可授予）
  或者用 `IActivityManager`/`WindowManager` 的公开入口

预期效果：
- `prepareAddWindowLw` 绑定 `mNavigationBar` → 框架按导航栏摆放
- 底部出现真导航栏，`mStable` 从 `(0,40)-(758,1024)` 变成 `(0,40)-(758,976)`
- app 可用区从 `758x960` 收到约 `758x912`（`navigation_bar_height` = 48dp @ 212dpi）

**完全不写 `/system`**，卸载即回滚。

风险：
1. 未实测 —— 需要做一次最小验证（空色块窗口，先只确认 inset 生效）。
2. PWM 的 `BarController.NavigationBar` 由 SystemUI 驱动隐藏状态；SystemUI 这里没注册它，
   窗口会不会被框架判为 hidden 需要在实测中确认。
3. 该 ROM 的 SystemUI 在配置变更路径上有隐藏 NPE（见下），新增底部 bars 会触发配置变更。
4. 常驻进程，需要 `BOOT_COMPLETED` 自启（或有办法让它常驻）。

### 路线 B（最彻底，需要 root）：改回 SystemUI

拿到 root（Magisk / eng 固件）后，把 `StatusBar.makeStatusBarView()` 里
`if (showNav) createNavigationBar();` 加回去，或直接改 `framework-res.apk`。
当前固件 `ro.secure=1`、无 `su`、`adb root` 被拒 —— 这条路的入口是"能不能 root"，目前无解。

### 路线 C（不碰系统）：无障碍悬浮窗底栏

非系统级，没有 inset，会盖住 app 内容；墨水屏上残影/刷屏问题明显。作为兜底。

---

## 五、已知的设备坑（改造时必须避开）

**这台机器的 SystemUI 在配置变更时会崩。** 我用 `wm density 220` 做探针时触发：

```
Process: com.android.systemui
InflateException: Binary XML file line #33:
  NullPointerException at
  com.android.systemui.qs.QuickStatusBarHeader.onFinishInflate(QuickStatusBarHeader.java:101)
    RadioGroup.setOnCheckedChangeListener(...) on a null object reference
→ "Process com.android.systemui has crashed too many times: killing!"
```

AOSP 8.1 的 `QuickStatusBarHeader.onFinishInflate` 里**没有 RadioGroup** —— 说明这处也被厂商改过，
且补丁在 `FragmentHostManager.onConfigurationChanged` → `QSFragment.onCreateView` 路径上有空指针。

**因为"底部多出导航栏"本身就会改变 app 可用区（配置变更），路线 A 有踩到同一个坑的可能。**
基线快照（`state/window-displays.txt` 等）已记录，可随时对照恢复。

---

## 六、基线快照（用于回滚对照）

```
init=758x1024 212dpi cur=758x1024 app=758x960 rng=758x718-960x920
mStableFullscreen=(0,0)-(758,1024)
mStable=(0,40)-(758,1024)
无 BarController.NavigationBar（只有 BarController.StatusBar）
```
