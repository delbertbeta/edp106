# KOReader 扩展

给 EPD106（Allwinner `virgo_perf1`，Android 8.1，758×1024 墨水屏）写的 KOReader 扩展。

```
patches/      KOReader 启动时加载的 Lua patch
plugins/      koplugin
styletweaks/  Stylesheet（Style tweaks）
```

| 路径 | 干什么的 |
|---|---|
| `patches/2-zenos-topbar-margins.lua` | 给 ZenOS 的阅读状态栏加边距设置（Zen Settings → Reader → Top/Bottom status bar）。它**故意放在 `zenos.koplugin` 外面**，这样升级 ZenOS 不会把它覆盖掉；ZenOS 改了相关源码结构时它会往日志里报错，而不是静默失效。ZenOS 4.x 的 **Align status bars with book margins** 抢的是同一组边距，所以装了 patch 之后那个功能被强制关掉（`isMarginAlignmentEnabled` 恒为 false），菜单入口也一并删掉 |
| `patches/2-android-net-connected.lua` | 让 KOReader 认得出**蓝牙 PAN / VPN** 这类非 Wi-Fi 网络，不再显示"未连接"。见下面「为什么蓝牙/VPN 会显示未连接」 |
| `plugins/totalfresh.koplugin/` | 墨水屏全刷。KOReader 自带的 Full refresh rate 在这台机器上不生效——它的 Android launcher 认不出这块屏的控制器，`Screen:refreshFull()` 只做一次普通 blit、不闪。插件自己数翻页，翻到 1/5/10/20 次时通过窗口管理器直接触发 GC16 全刷；刷新波形仍交给系统设置，插件不碰。**依赖这块屏，换设备没意义** |
| `plugins/txtoutline.koplugin/` | TXT 章节标题识别 → 多级目录；GB2312/GBK/GB18030 自动转码（借系统 ICU，不内置码表），见它自己的 [`README.md`](plugins/txtoutline.koplugin/README.md) |
| `styletweaks/heading_left_bar.css` | 章节标题左对齐 + 左侧竖线 + 内边距；txtoutline 认出来的标题会套用这个效果 |

## 安装

拷进 KOReader 的数据目录（Android 上是 `/sdcard/koreader/`），层级保持一致：

```sh
adb push patches/2-zenos-topbar-margins.lua  /sdcard/koreader/patches/
adb push patches/2-android-net-connected.lua /sdcard/koreader/patches/
adb push plugins/totalfresh.koplugin        /sdcard/koreader/plugins/
adb push plugins/txtoutline.koplugin        /sdcard/koreader/plugins/
adb push styletweaks/heading_left_bar.css   /sdcard/koreader/styletweaks/
```

推完要**完全退出**再重启 KOReader（从最近任务里划掉，不是回主页）。

## 环境

| | 版本 |
|---|---|
| KOReader（`org.koreader.launcher`） | v2026.07.2 |
| ZenOS | v4.0.1 —— `patches/2-zenos-topbar-margins.lua` 挂的就是它，内部模块结构一变 patch 就会在日志里报错（v4 重写过 `reader_top_status_bar.lua`，patch 的锚点已按 v4.0.1 对齐，不再兼容 ≤ 3.3.x） |
| SimpleUI | 由 ZenOS 带进来，跟这里的东西没有直接关系 |

## 为什么蓝牙/VPN 会显示未连接

**症状**：用蓝牙网络共享（PAN）或者挂了 VPN 上网时，浏览器、微信读书都正常，
但 KOReader 到处说"未连接"——"网络信息"菜单显示未连接，同步/OPDS/下载插件
会先弹"要开 Wi-Fi 吗"。

### 根因：KOReader 的安卓侧只认三种网络类型

链路是 `NetworkMgr:isConnected()` → `android.getNetworkInfo()` →
Java 侧 `ActivityExtensions.networkInfo()`。
后者的实现（反汇编 `classes.dex` 得到，API 23+ 分支）等价于：

```java
Network n = cm.getActiveNetwork();
if (n == null) return "0;0";
NetworkCapabilities c = cm.getNetworkCapabilities(n);
if (c == null) return "0;0";
if      (c.hasTransport(TRANSPORT_WIFI))     return "1;1";  // Wi-Fi
else if (c.hasTransport(TRANSPORT_CELLULAR)) return "1;2";  // 移动数据
else if (c.hasTransport(TRANSPORT_ETHERNET)) return "1;3";  // 以太网
else                                         return "0;0";  // ← 其余全算没联网
```

而这个 ROM 里，蓝牙网络共享上报的是 `Transports: BLUETOOTH`、VPN 是 `TRANSPORT_VPN`，
两个都落到最后那行，返回 `"0;0"`。**注意返回的不只是"类型未知"，连"已连接"那个
标志位都是 0** —— 所以 `isConnected()` 直接是 false，KOReader 认为压根没网。

而 `retrieveNetworkInfo()`（菜单里那句"未连接"）是同一份数据的直连透视。

### 取证：网络其实是通的

在一个跑在 KOReader 进程里的探针（`patches/2-netprobe.lua`，用完删了）中，
蓝牙 PAN 已连、网络正常时：

```
android.getNetworkInfo()   -> connected=0 type=0        ← 唯一错的东西
Device:retrieveNetworkInfo -> 未连接
tcp 223.5.5.5:53           -> OK
dns www.baidu.com          -> 157.148.69.186
hasDefaultRoute=true   canResolveHostnames=true   isOnline=true
isConnected=false                                        ← 被上面那个 0 带歪
```

`isOnline()` 跟 `isConnected()` 走的不是一条路（前者只做 DNS 解析），
所以它反而是对的——这个不一致本身就说明问题出在 Java 那个 API 上。
浏览器/微信读书不看这个 API，自己开 socket，所以它们没事。

### 修法

`patches/2-android-net-connected.lua` 把 `NetworkMgr:isConnected()`（连 `isWifiOn`，
因为 `initNetworkManager()` 里把后者绑到了前者的旧函数上）改成看**内核路由表**：

```lua
NetworkMgr.isConnected = function(self)
    if not Device:hasWifiToggle() then return true end
    if self:hasDefaultRoute() then return true end
    return orig_isConnected(self)   -- 兜底
end
NetworkMgr.isWifiOn = NetworkMgr.isConnected
```

`hasDefaultRoute()` 是 KOReader 自带的，只对 `203.0.113.1` 做一次路由查找
（`socket.udp():setpeername`，不发包、不解析域名），开销可忽略；网络真断时它也会
如实返回 false，所以不会把真断网误报成在线。顺带把 `retrieveNetworkInfo()` 也接了，
免得"网络信息"菜单继续自相矛盾。

改完实测（同一个进程内探针）：`isConnected=true`、`isWifiOn=true`、
`retrieveNetworkInfo -> Connected`。
