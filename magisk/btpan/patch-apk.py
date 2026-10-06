#!/usr/bin/env python3
"""把 com.android.bluetooth 里某个 bool 资源从 false 改成 true，产出打过补丁的 APK。

背景：设备的 BT App 把 `profile_supported_pan` 编译成了 false，
`btservice/Config.java` 的 `Config.init()` 因此不会把 PanService 放进
`SUPPORTED_PROFILES`，PanService 就从来不会启动 —— 设置里蓝牙设备详情页的
「用于 → 互联网连接」勾选框于是永远勾不上（点了会失败，也不置灰）。

这个脚本只改 resources.arsc 里那一个 Res_value 的 data 字节（0 → 1），
dex 一个字节都不动，所以 /system 里现成的 odex/vdex 仍然有效。
签名在 make-module.sh 里用原证书（AOSP platform）重做。

用法: patch-apk.py <原 APK> <输出 APK> [资源名，默认 profile_supported_pan]
"""
import struct
import sys
import zipfile

RES_TABLE_TYPE = 0x0002
RES_STRING_POOL_TYPE = 0x0001
RES_TABLE_PACKAGE_TYPE = 0x0200
RES_TABLE_TYPE_TYPE = 0x0201
TYPE_INT_BOOLEAN = 0x12

# 重新签名后这些会被 apksigner 重写，打包时先丢掉
SIG_ENTRIES = ("META-INF/MANIFEST.MF",)


def iter_chunks(buf, start, end):
    off = start
    while off + 8 <= end:
        chunk_type, header_size, size = struct.unpack_from("<HHI", buf, off)
        if size < 8 or off + size > end:
            return
        yield off, chunk_type, header_size, size
        off += size


def read_len8(buf, pos):
    """ResStringPool 的 UTF-8 长度：1 或 2 字节（高位置 1 表示两字节）。"""
    first = buf[pos]
    if first & 0x80:
        return ((first & 0x7F) << 8) | buf[pos + 1], pos + 2
    return first, pos + 1


def parse_string_pool(buf, off):
    chunk_type, header_size, _ = struct.unpack_from("<HHI", buf, off)
    assert chunk_type == RES_STRING_POOL_TYPE, hex(chunk_type)
    count, _styles, flags, strings_start, _styles_start = struct.unpack_from("<IIIII", buf, off + 8)
    utf8 = bool(flags & (1 << 8))
    offsets = struct.unpack_from("<%dI" % count, buf, off + header_size)
    base = off + strings_start
    out = []
    for rel in offsets:
        pos = base + rel
        if utf8:
            _chars, pos = read_len8(buf, pos)
            nbytes, pos = read_len8(buf, pos)
            out.append(buf[pos:pos + nbytes].decode("utf-8", "replace"))
        else:
            nchars = struct.unpack_from("<H", buf, pos)[0]
            pos += 2
            out.append(buf[pos:pos + 2 * nchars].decode("utf-16-le", "replace"))
    return out


def find_bool_entries(buf, want_name):
    """返回 [(字节偏移, 资源 id, 当前值, key 名)]，即所有配置变体里的这个资源。"""
    if struct.unpack_from("<H", buf, 0)[0] != RES_TABLE_TYPE:
        raise SystemExit("不是 resources.arsc（缺 ResTable header）")
    hits = []
    for pkg_off, chunk_type, header_size, size in iter_chunks(buf, 12, len(buf)):
        if chunk_type != RES_TABLE_PACKAGE_TYPE:
            continue
        pkg_id = struct.unpack_from("<I", buf, pkg_off + 8)[0]
        type_strings, _lpt, key_strings, _lpk = struct.unpack_from("<IIII", buf, pkg_off + 268)
        type_offset = (
            struct.unpack_from("<I", buf, pkg_off + 284)[0] if header_size >= 288 else 0
        )
        type_names = parse_string_pool(buf, pkg_off + type_strings)
        key_names = parse_string_pool(buf, pkg_off + key_strings)

        for off, chunk_type, type_header_size, chunk_size in iter_chunks(
            buf, pkg_off + header_size, pkg_off + size
        ):
            if chunk_type != RES_TABLE_TYPE_TYPE:
                continue
            type_id = buf[off + 8]
            entry_count, entries_start = struct.unpack_from("<II", buf, off + 12)
            type_name = (
                type_names[type_id - 1 - type_offset]
                if 0 <= type_id - 1 - type_offset < len(type_names)
                else "?"
            )
            if type_name != "bool":
                continue
            for index in range(entry_count):
                # 条目偏移表紧跟在 ResTable_type 头部之后（config 的 padding 已算进 headerSize）
                rel = struct.unpack_from("<I", buf, off + type_header_size + 4 * index)[0]
                if rel == 0xFFFFFFFF:
                    continue
                entry_off = off + entries_start + rel
                entry_size, _flags, key_index = struct.unpack_from("<HHI", buf, entry_off)
                if entry_size != 8:
                    continue  # 复杂条目（map）不是 bool
                if key_index >= len(key_names):
                    continue
                if key_names[key_index] != want_name:
                    continue
                value_size, _res0, data_type, data = struct.unpack_from(
                    "<HBBI", buf, entry_off + 8
                )
                assert value_size == 8, value_size
                assert data_type == TYPE_INT_BOOLEAN, hex(data_type)
                res_id = ((pkg_id & 0xFF) << 24) | (type_id << 16) | index
                hits.append((entry_off + 12, res_id, data, type_name, key_names[key_index]))
    return hits


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__.strip())
    src, dst = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else "profile_supported_pan"

    with zipfile.ZipFile(src) as z:
        names = z.namelist()
        if "resources.arsc" not in names:
            raise SystemExit("APK 里没有 resources.arsc")
        arsc = bytearray(z.read("resources.arsc"))
        method = z.getinfo("resources.arsc").compress_type

        hits = find_bool_entries(arsc, name)
        if not hits:
            raise SystemExit("没找到 bool/%s" % name)
        for off, res_id, data, _t, _n in hits:
            print(
                "  %s -> 0x%08x  当前 %s，改为 true（偏移 %d）"
                % (name, res_id, "true" if data else "false", off)
            )
            arsc[off : off + 4] = struct.pack("<I", 1)

        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as out:
            for info in z.infolist():
                if info.filename.startswith("META-INF/") and (
                    info.filename.endswith((".SF", ".RSA", ".DSA", ".EC"))
                    or info.filename in SIG_ENTRIES
                ):
                    continue  # 旧签名，交给 apksigner 重做
                data = bytes(arsc) if info.filename == "resources.arsc" else z.read(info)
                target = zipfile.ZipInfo(info.filename, info.date_time)
                target.compress_type = method if info.filename == "resources.arsc" else info.compress_type
                target.external_attr = info.external_attr
                target.internal_attr = info.internal_attr
                target.create_system = info.create_system
                out.writestr(target, data)
    print("  写好了 %s（%d 个配置变体，dex 未改动）" % (dst, len(hits)))


if __name__ == "__main__":
    main()
