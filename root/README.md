# MiReader (EPD106) — root + 字体改造记录

设备：小米多看电纸书一代 = 型号 `EPD106` = 墨案电纸书青春版
SoC：Allwinner B300 (`sun8iw15p1`) / Android 8.1 / 单槽分区 / 无 AVB、无 dm-verity

---

## 已完成的改动

| # | 改动 | 位置 |
|---|---|---|
| 1 | Magisk v28.1 root（patch boot.img 写入 `boot` 分区） | `/dev/block/by-name/boot` |
| 2 | 全局系统字体 → MiSans，整个字重梯度上移一级（默认 400 = Medium） | Magisk 模块 `misans` |
| 3 | 微信读书「京华老宋体」→ 方正筑紫明朝 | app 私有目录（非模块） |

## 关键原理

固件用 **AOSP 公开测试密钥**签名（`/system/etc/security/otacerts.zip` = AOSP 8.1
`testkey.x509.pem`，PEM sha1 `ef543a46…`），因此可以自签 update.zip，
通过 stock recovery 的 `Apply update from ADB` 刷入。bootloader 本来就未锁。

**自签包为什么能被接受**：recovery 只验整包签名（`vendor/bootable/recovery/verifier.cpp`），
签名覆盖范围 = `[文件头, EOCD+20)`，PKCS7 放 zip 注释里。

---

## 还原 / 回滚

### 还原原厂 boot（撤销 root）

还原包**不入库**（34MB），先按下面「重建还原包」生成，然后在设备上：

```powershell
adb reboot recovery      # 屏幕上触屏选 "Apply update from ADB"
adb sideload work\restore_stock_signed.zip
```
写入的是原厂 boot，md5 应为 `411ffe637dc3ca8972d88cd6bfbe3717`。
回滚后 Magisk 消失，但模块文件仍在 `/data/adb/modules/`（会失效）。

### 换回系统字体

删除或禁用 Magisk 模块 `misans`（Magisk app 里操作）→ 重启即恢复 Noto/Roboto。
`backup/fonts_orig.xml` 是原厂 `/system/etc/fonts.xml`。

### 还原微信读书字体

原字体需要自备（那台机器上已经被替换掉了），拿到后推上去：

```powershell
adb push KingHwa_OldSong.ttf.orig /sdcard/Download/kh.ttf
adb shell 'su -c "
  T=/data/data/com.tencent.weread.eink/files/fonts/available/KingHwa_OldSong.ttf
  am force-stop com.tencent.weread.eink
  cp /sdcard/Download/kh.ttf \$T
  chown 10037:10037 \$T; chmod 600 \$T
  chcon u:object_r:app_data_file:s0:c512,c768 \$T"'
```
> 注意：微信读书若重下字体 / 更新 / 清数据，替换会被还原，需再执行一次。

---

## 目录内容

| 路径 | 说明 |
|---|---|
| `backup/zzboot.img` | **原厂 boot 分区**（md5 `411ffe637dc3ca8972d88cd6bfbe3717`）—— 既是还原基准，也是还原包的原料 |
| `backup/magisk_patched.img` | Magisk v28.1 补丁后的 boot（md5 `ea1f0277dd4c269f42c19ad826a00488`），刷进 boot 分区即为 root |
| `backup/fonts_orig.xml` | 原厂 `/system/etc/fonts.xml` |
| `build_misans_v2.py` | 生成 MiSans 字体模块（Magisk 可直接安装的 zip） |
| `make-restore-zip.sh` | 生成「还原原厂 boot」的已签名刷机包 |
| `toolkit/kernel_flashing_template.zip` | 刷机包模板：内含 recovery 认可的 `update-binary`、`otacert`、`metadata` |
| `toolkit/restore-updater-script` | 还原包的 `updater-script`：把 `boot.img` 写回 boot 分区 |
| `toolkit/signapk-1.0.jar`、`toolkit/testkey.{pk8,x509.pem}` | 自签 OTA 包用。testkey 就是 AOSP 公开的那把 —— 这台固件本身用它签名，所以自签包能被 recovery 接受 |
| `toolkit/dump_kernel_to_system_signed.zip` | 社区工具：把内核 dump 到 `/system` |

## 重建

| 要什么 | 怎么生成 |
|---|---|
| MiSans 字体模块 zip | `python3 build_misans_v2.py`。字体默认读 `root/fonts/`，可用 `SRC_TTF=` 指到别处；设备上现成有 6 个字重，`adb pull /data/adb/modules/misans/system/fonts/ fonts/` 即可（要 su） |
| 还原原厂 boot 的刷机包 | `JAVA8=~/jdk8 ./make-restore-zip.sh` → `work/restore_stock_signed.zip`，然后 `adb sideload` |
| 换回微信读书原字体 | 需要 `KingHwa_OldSong.ttf.orig`；那台机器上的已经被替换掉了，只能让微信读书自己重下字体后再 pull |

还原包的做法：拿 `kernel_flashing_template.zip` 做底，换上 `toolkit/restore-updater-script`，
追加 `backup/zzboot.img`（**STORED**，OTA 的 boot.img 不能压缩），再用 `toolkit/testkey.*` 签名。

`JAVA8` 必须是 **JDK 8**：signapk 要摸 `sun.security.pkcs`，JDK 9+ 不再导出。要签别的刷机包，
同一个 jar 也这么用：

```bash
$JAVA8/bin/java -jar toolkit/signapk-1.0.jar \
  -w toolkit/testkey.x509.pem toolkit/testkey.pk8 in.zip out_signed.zip
```

社区那份 `org_boot.img` 与本机不一致（它 md5 `f25bc72e…`，本机 `411ffe63…`），**不要**拿它当还原基准。

---

## 设备侧现状（勿删）

| 路径 | 说明 |
|---|---|
| `/data/adb/modules/misans` | 字体模块本体，删了就退回系统字体 |
| `/data/adb/` | Magisk 自身 |
| `/cache/backup`、`/cache/backup_stage`、`/cache/recovery` | **固件自带**，非本次创建 |
| `/system/app/DkReader106/oat/arm/DkReader106.odex` | 保留（配套 vdex 已重建到 `/data/dalvik-cache`） |

## 已知代价 / 遗留

- `/system/app/DkReader106/oat/arm/DkReader106.vdex`（49 MB）为腾空间已删 →
  ART 已在 `/data/dalvik-cache` 重建，多看阅读实测正常。
- `/system` 真实可用空间原本只有 1.5 MB（recovery 里 `df` 会虚报 +16 MB）。
- 无官方完整固件，社区那个 2021 年 PhoenixSuit 线刷包对新批次机型可能失效 →
  **不要**用 PhoenixSuit 刷多分区（同芯片机型有刷砖先例）。
- FEL 不可用：B300 的 SoC ID `0x1755` 不在 `sunxi-fel` 的 `soc_info.c` 里，且缺 `fes1.fex`。

---


