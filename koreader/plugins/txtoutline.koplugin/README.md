# TXT Outline for KOReader

自动识别纯文本书籍中的中英文章节标题，并为 KOReader 生成多级目录。

## 功能

- 仅在打开 `.txt` 文件时运行。
- 不修改原始 TXT。
- 识别常见中文结构：卷、部、篇、集、册、章、回、话、节，以及序章、前言、楔子、引子、尾声、后记、番外、附录等。
- 识别常见英文结构：Volume、Book、Part、Chapter、Section、Prologue、Epilogue、Preface、Foreword、Introduction、Afterword、Appendix、Interlude。
- 支持阿拉伯数字、全角数字、中文数字和罗马数字。
- 按卷/章/节关系生成最多三级目录。
- 识别结果缓存在 KOReader 的书籍 sidecar 设置中；源文件大小、修改时间、DOM 或相关设置变化后自动失效。
- 阅读界面菜单 **“TXT chapter outline”** 提供两个独立的全局开关：章节目录与 TXT 段落样式；两者默认开启。
- TXT 段落样式会抽样正文：原文多数段落已有行首空格时不再叠加 `2em`，否则自动补充首行缩进。
- 目录的一级、二级标题会像 KOReader 默认 EPUB 标题一样另起一页。
- 识别出的 TXT 标题会套用 `heading_left_bar.css` 的左对齐、左侧竖线与内边距效果。
- 菜单提供 **“Rescan chapters”**，用于清除当前书籍缓存并重新识别。

## 标题显示与限制

插件把章节命中的 XPointer 转换为精确的结构 CSS 选择器，只为对应节点应用 `h1/h2/h3` 风格。因此正文不会因为宽泛的 `pre` 或 `p` 规则而全部变成标题。

这是**视觉层级**：KOReader 当前没有向 Lua 插件公开修改 DOM 标签的接口，所以底层节点仍是 TXT 解析器生成的 `pre`、`p` 或 `title`，不是真实 HTML `<h1>/<h2>/<h3>`。若 XPointer 无法安全转换，插件只为该书提供目录并放弃标题样式。

如必须获得真实标题标签，需要采用“TXT 转换为派生 HTML/EPUB”的方案；这会产生新的书籍身份，并涉及阅读进度与书签迁移，不属于当前非破坏式版本。

## 安装

把整个 `txtoutline.koplugin` 目录复制到 Android KOReader 数据目录下的 `plugins` 目录，确保结构不是双层嵌套：

```text
plugins/
└── txtoutline.koplugin/
    ├── _meta.lua
    ├── main.lua
    ├── txtoutline_recognizer.lua
    ├── txtoutline_adapter.lua
    ├── txtoutline_charset.lua
    └── txtoutline_cache.lua
```

完全退出并重新启动 KOReader，然后直接打开 TXT。识别成功后可从 KOReader 的目录入口查看。

菜单入口位于阅读界面的 **更多工具（More tools）→ TXT chapter outline**。切换开关或重新扫描后，插件会无闪烁地重新加载当前 TXT，使配置立即生效。开关是全局设置，对随后打开的其他 TXT 同样生效。

## 编码

国内纯文本小说大多是 GB2312/GBK。插件读完原始字节先按 UTF-8 校验，不通过就交给**系统 ICU**
（`libicuuc.so`：Android 自带，且列在 `/system/etc/public.libraries.txt` 里，所以 App 可以 dlopen），
一次 `ucnv_convert("utf-8", "gb18030", …)` 转完。GB18030 覆盖 GB2312 和 GBK 的全部两字节区，
四字节区也是原生支持，所以不需要内置码表。

实测（EPD106 / Android 8.1 / armv7a / ICU 58）：340 KB 的《珍宝馆》转码 **12 毫秒**，结果与 Python 的
`gb18030` 编解码器逐字节一致（503525 字节，滚动哈希相同）。ICU 的 C 符号带版本后缀（这台是
`ucnv_convert_58`，版本号跟着 Android 走），插件运行时探测后缀，不硬编码。

ICU 解不开的字节会被替换成 U+FFFD；替换比例超过文件的 2% 就判定「不是这个编码」并跳过整本。
猜错编码不会产生错目录：识别出的标题必须能在 crengine 解码后的正文里搜到才算数，所以猜错只会
**漏**标题，不会指错位置。

UTF-16 仍未支持（带 BOM 或含 NUL 字节即跳过）。ICU 换个转换器名就能加，等真有这种书再说。

## 安全降级

以下情况插件会跳过，不影响原书正常打开：

- 文件超过 16 MiB；
- 无法读取；
- UTF-16，或含 NUL 字节的二进制文件；
- 非 UTF-8，且系统 ICU 不可用（无 FFI、无 ICU、符号后缀认不出），或替换字符超过 2%；
- 已启用 KOReader 自带的手工目录；
- 当前 KOReader 版本缺少搜索或 XPointer API；
- 标题能够识别，但无法映射到文档节点。

诊断信息写入 KOReader 的日志，前缀为 `txtoutline:`。
