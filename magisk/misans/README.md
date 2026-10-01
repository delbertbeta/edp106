# misans — MiSans 全系统字体（Magisk 模块）

模块 id = `misans`。把系统 `sans-serif` 家族换成 MiSans，并且**整个字重梯度上移一级**：
Android 默认的 400 由 Regular 变成 Medium（这就是当时要的效果），其余字重同此顺移。
设不到的字符回落到 Roboto / Noto。

设备侧的完整记录（为什么这么改、怎么回滚、`/system` 空间代价等）见
[`../../root/README.md`](../../root/README.md)。

## 生成

```sh
cd magisk/misans
python3 build_misans_v2.py          # 产出 work/misans_font_v2.zip，Magisk 里直接安装
```

字体默认读本目录下的 `fonts/`，可以用 `SRC_TTF=/path/to/ttf` 指到别处。设备上现成有这
6 个字重，拉下来即可（要 su）：

```sh
adb shell su -c 'ls /data/adb/modules/misans/system/fonts/'
adb pull /data/adb/modules/misans/system/fonts/ fonts/
```

`fonts_orig.xml` 是原厂 `/system/etc/fonts.xml`。模块里的 `fonts.xml` 就是拿它做底，
在 `sans-serif` 家族里插入脚本顶部那张「字重 → MiSans 文件」映射表得到的。

## 回滚

Magisk app 里禁用（或删除）`misans` 模块 → 重启即恢复 Noto/Roboto。
