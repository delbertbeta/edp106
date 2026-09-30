# KOReader 扩展

给 EPD106（Allwinner `virgo_perf1`，Android 8.1，758×1024 墨水屏）写的 KOReader 扩展。

```
patches/      KOReader 启动时加载的 Lua patch
plugins/      koplugin
styletweaks/  Stylesheet（Style tweaks）
```

| 路径 | 干什么的 |
|---|---|
| `patches/2-zenos-topbar-margins.lua` | 给 ZenOS 的阅读状态栏加边距设置（Zen Settings → Reader → Top/Bottom status bar）。它**故意放在 `zenos.koplugin` 外面**，这样升级 ZenOS 不会把它覆盖掉；ZenOS 改了相关源码结构时它会往日志里报错，而不是静默失效 |
| `plugins/totalfresh.koplugin/` | 墨水屏全刷。KOReader 自带的 Full refresh rate 在这台机器上不生效——它的 Android launcher 认不出这块屏的控制器，`Screen:refreshFull()` 只做一次普通 blit、不闪。插件自己数翻页，翻到 1/5/10/20 次时通过窗口管理器直接触发 GC16 全刷；刷新波形仍交给系统设置，插件不碰。**依赖这块屏，换设备没意义** |
| `plugins/txtoutline.koplugin/` | TXT 章节标题识别 → 多级目录，见它自己的 [`README.md`](plugins/txtoutline.koplugin/README.md) |
| `styletweaks/heading_left_bar.css` | 章节标题左对齐 + 左侧竖线 + 内边距；txtoutline 认出来的标题会套用这个效果 |

## 安装

拷进 KOReader 的数据目录（Android 上是 `/sdcard/koreader/`），层级保持一致：

```sh
adb push patches/2-zenos-topbar-margins.lua /sdcard/koreader/patches/
adb push plugins/totalfresh.koplugin        /sdcard/koreader/plugins/
adb push plugins/txtoutline.koplugin        /sdcard/koreader/plugins/
adb push styletweaks/heading_left_bar.css   /sdcard/koreader/styletweaks/
```

推完要**完全退出**再重启 KOReader（从最近任务里划掉，不是回主页）。

## 环境

| | 版本 |
|---|---|
| KOReader（`org.koreader.launcher`） | v2026.07.1 |
| ZenOS | v3.3.1 —— `patches/2-zenos-topbar-margins.lua` 挂的就是它，内部模块结构一变 patch 就会在日志里报错 |
| SimpleUI | 由 ZenOS 带进来，跟这里的东西没有直接关系 |
