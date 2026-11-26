#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 VrSystemActor.lockLandscape() 里 USER_ROTATION 的 ROTATION_90 改成 ROTATION_0。

纯 Python 二进制 dex patch，不需要 JDK/baksmali。

原理（见 shared/runtime-actor/.../VrSystemActor.java 的 lockLandscape）：
    const/4 v4, 0x1                       # 12 14
    Settings.System.getInt(res, ACCELEROMETER_ROTATION, v4)   # 默认值 1
    ...
    Settings.System.putInt(res, USER_ROTATION, v4)            # 写 ROTATION_90
v4 在整个方法里只被这两处使用。把 const/4 的立即数 1 -> 0（12 14 -> 12 04）：
    getInt 的默认值变成 0（设置项存在时读实际值，无影响；不存在时 0 也合理）
    putInt 写入 ROTATION_0 —— 盒子原生横屏，不再被掰成竖屏。

绝不改其它地方：先在 dex 的 class_defs/class_data/code_item 里精确定位
lockLandscape 的 insns 区间，只在该区间内找唯一的 `12 14`。

用法:
    python patch_lock_landscape.py inspect <classes4.dex>
    python patch_lock_landscape.py patch   <classes4.dex> <out.dex>
"""
import hashlib
import struct
import sys
import zlib
from pathlib import Path

TARGET_CLASS = "Lcom/huawei/hvrsdkserverapp/compat/VrSystemActor;"
TARGET_METHOD = "lockLandscape"
OLD = b"\x12\x14"   # const/4 v4, 0x1
NEW = b"\x12\x04"   # const/4 v4, 0x0


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def uleb(b, pos):
    """返回 (value, new_pos)。"""
    result = 0
    shift = 0
    while True:
        cur = b[pos]
        pos += 1
        result |= (cur & 0x7F) << shift
        if not (cur & 0x80):
            break
        shift += 7
    return result, pos


def mutf8(b, off):
    n, shift = 0, 0
    while True:
        c = b[off]
        off += 1
        n |= (c & 0x7F) << shift
        if not (c & 0x80):
            break
        shift += 7
    return b[off:off + n].decode("utf-8", "replace")


def tables(b):
    str_n, str_off = u32(b, 0x38), u32(b, 0x3C)
    typ_n, typ_off = u32(b, 0x40), u32(b, 0x44)
    mtd_n, mtd_off = u32(b, 0x58), u32(b, 0x5C)
    cdf_n, cdf_off = u32(b, 0x60), u32(b, 0x64)
    strs = [mutf8(b, u32(b, str_off + 4 * i)) for i in range(str_n)]
    types = [strs[u32(b, typ_off + 4 * i)] for i in range(typ_n)]
    methods = []
    for i in range(mtd_n):
        cls, proto, name = struct.unpack_from("<HHI", b, mtd_off + 8 * i)
        methods.append((types[cls], strs[name]))
    return types, methods, (cdf_n, cdf_off)


def class_data_methods(b, cdata_off, methods):
    """返回 [(method_name, class_name, code_off), ...]。"""
    p = cdata_off
    sf, p = uleb(b, p)
    inf, p = uleb(b, p)
    dm, p = uleb(b, p)
    vm, p = uleb(b, p)
    for _ in range(sf + inf):           # encoded_field: 2 x uleb128
        _, p = uleb(b, p)
        _, p = uleb(b, p)
    out = []
    # direct_methods 与 virtual_methods 的 method_idx_diff 各自从 0 起累加
    for count in (dm, vm):
        idx = 0
        for _ in range(count):
            diff, p = uleb(b, p)
            _, p = uleb(b, p)          # access_flags
            code_off, p = uleb(b, p)
            idx += diff
            out.append((methods[idx][1], methods[idx][0], code_off))
    return out


def find_code(b):
    """定位 lockLandscape 的 insns 字节区间 (start, end)。"""
    types, methods, (cdf_n, cdf_off) = tables(b)
    for i in range(cdf_n):
        base = cdf_off + 32 * i
        cls_idx = u32(b, base)
        if types[cls_idx] != TARGET_CLASS:
            continue
        cdata_off = u32(b, base + 24)
        if cdata_off == 0:
            continue
        for name, owner, code_off in class_data_methods(b, cdata_off, methods):
            if name == TARGET_METHOD and code_off:
                insns_size = u32(b, code_off + 12)
                start = code_off + 16
                return start, start + insns_size * 2, code_off, insns_size
    raise SystemExit("找不到 %s->%s 的 code_item" % (TARGET_CLASS, TARGET_METHOD))


def cmd_inspect(path):
    b = Path(path).read_bytes()
    s, e, code_off, n = find_code(b)
    seg = b[s:e]
    print(f"文件        : {path} ({len(b)} B)")
    print(f"code_off    : 0x{code_off:x}, insns={n} u16, 区间 [0x{s:x},0x{e:x})")
    print(f"目标字节    : {OLD.hex()} (const/4 v4,0x1) 出现 {seg.count(OLD)} 次")
    print(f"目标字节    : {NEW.hex()} (const/4 v4,0x0) 出现 {seg.count(NEW)} 次")
    # 打印前 24 个 code unit，人工核对
    print("insns 前 24 u16:", " ".join(f"{u16(b,s+2*i):04x}" for i in range(min(24, n))))
    print("全 dex 中 12 14 出现次数:", b.count(OLD), "（方法区间内应恰好 1 次）")


def fix_digest(buf):
    buf[0x0C:0x20] = hashlib.sha1(buf[0x20:]).digest()
    struct.pack_into("<I", buf, 0x08, zlib.adler32(buf[0x0C:]) & 0xFFFFFFFF)


def cmd_patch(src, dst):
    raw = Path(src).read_bytes()
    s, e, _, _ = find_code(raw)
    seg = raw[s:e]
    if seg.count(OLD) != 1:
        raise SystemExit(f"方法区间内 {OLD.hex()} 出现 {seg.count(OLD)} 次（期望 1），拒绝修改")
    buf = bytearray(raw)
    pos = s + buf[s:e].find(OLD)
    print(f"patch @0x{pos:x}: {buf[pos]:02x} {buf[pos+1]:02x} -> {NEW[0]:02x} {NEW[1]:02x}")
    buf[pos:pos + 2] = NEW
    fix_digest(buf)
    Path(dst).write_bytes(buf)

    # 复验
    chk = bytearray(Path(dst).read_bytes())
    s2, e2, _, _ = find_code(chk)
    assert len(chk) == len(raw)
    assert chk[s2:e2].count(NEW) == 1 and chk[s2:e2].count(OLD) == 0
    assert chk[0x0C:0x20] == hashlib.sha1(chk[0x20:]).digest()
    assert u32(chk, 0x08) == (zlib.adler32(chk[0x0C:]) & 0xFFFFFFFF)
    diff = [i for i, (x, y) in enumerate(zip(raw, chk)) if x != y]
    print(f"[OK] 输出 {dst}；共 {len(diff)} 处字节差异（含 20B SHA1 + 4B Adler32 + 2B 指令）：")
    print("     偏移:", [hex(i) for i in diff])
    print("[OK] SHA1/Adler32 重算通过，code 区间内 const/4 v4 立即数已为 0")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    if sys.argv[1] == "inspect":
        cmd_inspect(sys.argv[2])
    elif sys.argv[1] == "patch" and len(sys.argv) >= 4:
        cmd_patch(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(__doc__)
