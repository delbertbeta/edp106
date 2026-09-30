# EPD106 改造归档

小米多看电纸书一代 —— Allwinner **EPD106**（`virgo_perf1`，Android 8.1，758×1024 墨水屏）——
的改造工作统一放这里：补回被 ROM 删掉的底部三键导航栏、Magisk root、全系统字体替换。

    navbar/     导航栏 App（com.delbert.epdnav）。无 Gradle，用 AOSP platform 密钥签名，不需要 root
    root/       root + 字体改造。原厂/patched boot、Magisk 模块生成脚本、签名刷机工具链、还原包
    baseline/   改造前的原厂基线：设备状态快照 + 原厂文件 md5 清单
    koreader/   自己写的 KOReader 扩展：墨水屏全刷插件、TXT 章节识别插件、ZenOS patch、标题样式

## 三块内容

| 目录 | 是什么 | 入口 |
|---|---|---|
| `navbar/` | 用 `TYPE_NAVIGATION_BAR` 窗口把 ROM 删掉的导航栏补回来；`/data` 侧安装，不碰 `/system` | [`navbar/README.md`](navbar/README.md) |
| `root/` | Magisk v28.1 root（patch boot.img）+ MiSans 全系统字体（Magisk 模块）；含还原原厂 boot 的已签名刷机包 | [`root/README.md`](root/README.md) |
| `baseline/` | 改造前的设备状态快照，以及原厂文件的 md5 还原基准 | [`baseline/README.md`](baseline/README.md) |
| `koreader/` | 自己写的 KOReader 扩展：墨水屏全刷、TXT 章节标题识别、ZenOS 状态栏边距 patch、标题样式 | [`koreader/README.md`](koreader/README.md) |

## 结论摘要

- 导航栏缺失**不是设置问题，RRO 也修不了**：ROM 的 `SystemUI` 里
  `StatusBar` 创建导航栏窗口那段代码被厂商删了（`.line` 表 1089 直接跳到 1099），
  而框架侧 `PhoneWindowManager` 是原版的。取证见 [`navbar/docs/FINDINGS.md`](navbar/docs/FINDINGS.md)。
- 设备已 root（Magisk v28.1，patch boot 分区），系统字体已是 MiSans（字重梯度整体上移一级）。
- 回滚：`root/make-restore-zip.sh` 重建还原包后 `adb sideload` 回去，即还原原厂 boot；
  字体在 Magisk app 里禁用 `misans` 模块即恢复 Noto/Roboto。

## 环境

构建只在 **WSL (Debian)** 里做 —— Android SDK 装在 WSL，不在 Windows。所有命令都从
仓库根目录起；脚本里没有硬编码绝对路径，只认自己所在目录和环境变量
（`BT`/`PLATFORM`、`SRC_TTF`、`JAVA8`）。工具链版本见 [`navbar/TOOLING.md`](navbar/TOOLING.md)。
