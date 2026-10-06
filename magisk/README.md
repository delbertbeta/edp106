# magisk/ — Magisk 模块

每个子目录是一个模块的**源码 / 生成脚本**；模块本体（生成的 zip、设备上的目录）不入库。

| 模块 | 是什么 | 入口 |
|---|---|---|
| `misans/` | MiSans 全系统字体：整个字重梯度上移一级（默认 400 = Medium） | [`misans/README.md`](misans/README.md) |
| `blem3map/` | 把 BLE-M3 翻页器变成标准键盘：PageUp/PageDown、DPAD 左右、中键点屏幕中心、底部键 = Back | [`blem3map/README.md`](blem3map/README.md) |
| `btpan/` | 把 ROM 关掉的蓝牙 PAN 打开（设置里「用于 → 互联网连接」能勾上）：补 `bool/profile_supported_pan` + 清 PMS 解析缓存 | [`btpan/README.md`](btpan/README.md) |

装上以后模块躺在设备侧 `/data/adb/modules/<模块 id>/`；在 Magisk app 里禁用（或删掉目录）
重启即回滚。MiSans 那个模块的设备侧完整记录在 [`../root/README.md`](../root/README.md)。
