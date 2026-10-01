# blem3map — 把 BLE-M3 翻页器变成一个标准键盘

BLE-M3（`0E05:0A00`）是"模拟鼠标"式的翻页器：方向键不是按键，而是**拿鼠标相对位移模拟
绝对坐标**——每次按下先发 `REL_X/REL_Y = ±2047` 撞到屏幕边角，再走一段固定偏移到目标点，
然后按下左键、拖拽几步、松开，等于一次"穿过屏幕中心的滑动"。所以直接用它只能看着光标
满屏乱跳。

这个小程序在**主机侧**（电纸书）把它翻译成按键：

| 设备上的键 | 设备实际发出（758x1024 坐标） | blem3map 发出去 |
|---|---|---|
| 上 | `(108,772)` 向上滑到 `(108,380)` | `PAGE_UP` |
| 下 | `(108,168)` 向下滑到 `(108,808)` | `PAGE_DOWN` |
| 左 | `(40,351)` 向右滑到 `(490,351)` | `DPAD_LEFT` |
| 右 | `(676,351)` 向左滑到 `(226,351)` | `DPAD_RIGHT` |
| 中 | 点 `(160,643)` | `input tap 379 512`（真正的屏幕中心） |
| 底部 | 点 `(170,903)` + `KEY_VOLUMEDOWN`（有时只发音量、不带坐标） | `BACK` |

滑动方向与键位相反是阅读类 app 的翻页约定（左滑 = 下一页），不是 bug。

上表是从设备自己的事件流里读出来的，原始抓包（每个键按 3 下）见
[`docs/blem3-capture-presses.txt`](docs/blem3-capture-presses.txt)。

## 它怎么工作

1. `EVIOCGRAB` 独占抓取 `/dev/input/eventN` —— 系统从此收不到它的任何事件，光标不再乱跑。
   代价：抓取期间它就不是鼠标了（这正是我们要的）。
2. 认出"归位 → 偏移 → 左键按下"这个三段式，用 `(归位方向, 偏移)` 查 `rules[]` 翻译成一个按键。
   真按压一定带一次左键按下，"回位"动作不带——靠这个区分，否则一次按压会被翻成两下。
3. 按键经 `/dev/uinput` 的虚拟键盘（名字就叫 `blem3map`）注入；中键改用 `input tap`。
   虚拟键盘在 Android 里被识别为普通键盘，走 `Generic.kl`，所以上面那些键码都是标准映射。

`kill` 掉就完全恢复原样（抓取随 fd 关闭自动释放，虚拟键盘随进程消失）。

## 用法

```sh
./build.sh                                          # 需要 NDK，产出 armv7 的 blem3map
adb push blem3map /data/local/tmp/
adb shell su -c 'chmod 755 /data/local/tmp/blem3map'

# 前台跑，按 6 个键看日志（每次翻译都会打印一行）
adb shell su -c '/data/local/tmp/blem3map'

# 停止（恢复原样）
adb shell su -c 'pkill blem3map'
```

日志会告诉你每个手势被认成了什么；认不出来的会打 `未知手势 park(..) move(..)`，
照着改 `rules[]` 就行。

## 做成 Magisk 模块（开机自启）

```sh
./make-module.sh                                     # 编译 + 打包 → work/blem3map-module.zip
adb push work/blem3map-module.zip /sdcard/Download/  # 然后在 Magisk app 里「从本地安装」
# 或者命令行直接装：
adb push work/blem3map-module.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/blem3map-module.zip'
```

模块就四样东西：`module.prop`、`service.sh`（late_start 阶段先 `pkill -x` 收掉旧实例，
再后台拉起单实例，异常退出 5 秒重试）、`uninstall.sh`（卸载时停进程）、`blem3map`（armv7 二进制）。
**不碰 `/system`、不做任何 mount、不动 boot**，纯数据侧。

日志在 `/data/local/tmp/blem3map.log`，每次开机重开一份；每行前缀是**开机秒数**
（跟 `getevent -lt`、内核日志同一时基），方便事后和“某个时刻屏幕怎么了”对账。

回滚：

- 立刻停：`adb shell su -c 'pkill -x blem3map'`
- 禁用模块（Magisk app 里关掉，或 `touch /data/adb/modules/blem3map/disable`）→ 重启后不再自启
- 彻底移除：`adb shell su -c 'rm -rf /data/adb/modules/blem3map'` 后重启

## 待验证 / 已知取舍

- **上/下、左/右 是否反了**：映射表是按"上 → PageUp"写的（依据是抓包里按键的先后顺序）。
  手感相反的话，把 `rules[]` 里对应两行的 `key` 互换即可，一行改动。
- **KOReader 若不吃 PageUp/PageDown**：把这两行换成 `KEY_UP`/`KEY_DOWN` 再试。
- 每次按压只发一次按键（按下 + 立刻松开），没有长按连发。需要再加。
- 设备偶发"只发音量、不带坐标"的事件也按底部键处理成 `BACK`（`run()` 里那一段），
  这样底部键在任何状态下都不会失灵。
- 模块只做按键映射。微信读书里“翻几页后正文页底色发灰”（实测那页底色是 240 而不是 255，黑字仍为 0，且同一张截图里微信读书自己的面板是 255/253）是另一件事，还没定位到它自己哪个开关切的。
