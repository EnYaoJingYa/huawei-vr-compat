#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在 boot.img 的 ramdisk/init.rc 末尾追加一个 `on early-init` 段，让
persist.vendor.resolution.* 与 HWC 日志开关在 HWC 6.04s Init 之前就位。

设计要点（最小差分 / 可回退）：
  1. 只改 ramdisk 内的 init.rc 一个文件，追加纯文本行；
  2. 新 gzip 必须 <= 原 ramdisk_size，写回原偏移、尾部补 0；
     boot header（含 ramdisk_size / id）、kernel、second、dtb、所有段偏移
     全部保持原字节不变 —— Magisk 修补版 ramdisk 结构完整保留；
  3. 不刷机。产物是一份新 boot.img，原始文件不改动。

用法：
  python tools/make_boot_earlyprop.py \
      backup/box-2026-11-05/partitions/boot.img \
      build/boot-hvrglass-earlyprop.img

回退：把原始 boot.img 重新刷回 boot 分区即可。
"""

import gzip
import hashlib
import io
import struct
import sys

EARLY_INIT = """# HVRGlass: props ready before HWC Init (tools/make_boot_earlyprop.py)
# 注入点：/system/etc/init/hw/init.rc 会 import /init.rk30board.rc，
# 开机日志明确显示该文件被加入 import 列表但原本不存在。
on early-init
    setprop persist.vendor.resolution.main 3200x1600@70
    setprop persist.vendor.resolution.HDMI-A-0 3200x1600@70
    setprop vendor.hwc.enable_display_configs 1
    setprop vendor.hwc.log 1

"""


def make_entry(name, data, ino):
    """构造一个 cpio newc 普通文件条目（mode 0644, uid/gid 0）。"""
    def h(v):
        return ('%08x' % v).encode('ascii')
    hdr = (b'070701' + h(ino) + h(0x81a4) + h(0) + h(0) + h(1) + h(0)
           + h(len(data)) + h(0) + h(0) + h(0) + h(0)
           + h(len(name) + 1) + h(0))
    assert len(hdr) == 110, len(hdr)
    return {'hdr': hdr, 'name': name, 'data': data}


def parse_cpio(raw):
    """解析 newc cpio。filesize@54, namesize@94, check@102（易错点）。"""
    out = []
    pos = 0
    while pos + 110 <= len(raw):
        if raw[pos:pos + 6] not in (b'070701', b'070702'):
            break
        hdr = raw[pos:pos + 110]
        fsz = int(hdr[54:62], 16)
        nsz = int(hdr[94:102], 16)
        name = raw[pos + 110:pos + 110 + nsz - 1].decode('utf-8', 'replace')
        data_at = pos + ((110 + nsz + 3) & ~3)
        data = raw[data_at:data_at + fsz]
        out.append({'hdr': hdr, 'name': name, 'data': data})
        pos = data_at + ((fsz + 3) & ~3)
        if name == 'TRAILER!!!':
            break
    return out, pos


def serialize_entry(e):
    """把单个 cpio 条目序列化成字节块，用于外科手术式插入。"""
    hdr = bytearray(e['hdr'])
    hdr[54:62] = ('%08x' % len(e['data'])).encode('ascii')
    name = e['name'].encode('utf-8') + b'\x00'
    return (bytes(hdr) + name
            + b'\x00' * ((4 - (110 + len(name)) % 4) % 4)
            + e['data']
            + b'\x00' * ((4 - len(e['data']) % 4) % 4))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    img = bytearray(open(src, 'rb').read())
    ks, ka, rs, ra, ss, sa, ta, pg, hv, osv = struct.unpack_from('<10I', img, 8)
    if hv < 1 or pg <= 0:
        print('[FATAL] 非预期 boot header: hv=%d page=%d' % (hv, pg))
        return 1

    def al(x):
        return ((x + pg - 1) // pg) * pg

    k_off = pg
    r_off = pg + al(ks)
    print('[i] boot header v%d  page=%d  kernel=%d @%#x  ramdisk=%d @%#x  second=%d'
          % (hv, pg, ks, k_off, rs, r_off, ss))
    src_gz = bytes(img[r_off:r_off + rs])
    raw = gzip.decompress(src_gz)
    print('[i] ramdisk gzip %d -> cpio %d bytes' % (len(src_gz), len(raw)))

    entries, end = parse_cpio(raw)
    print('[i] cpio entries=%d  consumed=%#x / %#x' % (len(entries), end, len(raw)))
    if not entries or entries[-1]['name'] != 'TRAILER!!!':
        print('[FATAL] cpio 未解析到 TRAILER!!!，拒绝生成')
        return 1

    print('[i] ramdisk 文件:', [x['name'] for x in entries])
    names = [x['name'] for x in entries]
    if 'init.rk30board.rc' in names:
        print('[FATAL] ramdisk 已存在 init.rk30board.rc，拒绝覆盖')
        return 1

    before = {x['name']: hashlib.md5(x['data']).hexdigest() for x in entries}
    # 新增一个会被 init 自动 import 的 rc 文件，既有文件一个字节都不改。
    rc = make_entry('init.rk30board.rc', EARLY_INIT.encode('utf-8'),
                    max(int(x['hdr'][6:14], 16) for x in entries) + 1)
    entries.insert(len(entries) - 1, rc)   # 插在 TRAILER!!! 之前
    print('[i] 新增 init.rk30board.rc (%d bytes)，既有 %d 个文件全部保持原样'
          % (len(rc['data']), len(before)))
    # 外科手术：只在 TRAILER!!! 之前插入新条目字节块，
    # 前面 3MB cpio 数据逐字节不变，重新压缩后体积变化最小。
    t = raw.find(b'TRAILER!!!\x00') - 110
    if t < 0:
        print('[FATAL] 未找到 TRAILER!!! 条目，拒绝生成')
        return 1
    new_raw = raw[:t] + serialize_entry(rc) + raw[t:]

    import zlib
    orig = bytes(img)
    seg_limit = al(rs)                 # ramdisk 段的 page 对齐物理边界
    print('[i] ramdisk 段物理边界 %#x (header size=%d, 可容纳 %d)'
          % (r_off + seg_limit, rs, seg_limit))
    best = None
    for mem in (9, 8, 6):
        co = zlib.compressobj(9, zlib.DEFLATED, 31, mem, zlib.Z_DEFAULT_STRATEGY)
        gz = co.compress(new_raw) + co.flush()
        if best is None or len(gz) < len(best):
            best = gz
    new_gz = best
    print('[i] 新 ramdisk gzip = %d bytes (原 %d, 段内余量 %d)'
          % (len(new_gz), len(src_gz), seg_limit - len(new_gz)))
    if len(new_gz) > seg_limit:
        print('[FATAL] 超出 ramdisk 段物理边界，会覆盖 second 段，拒绝生成')
        return 1

    new_rs = max(rs, len(new_gz))
    if new_rs != rs:
        # 只改 header 的 ramdisk_size（4 字节）；对齐后段边界不变，
        # second / dtb / 后续所有段偏移都不动。
        struct.pack_into('<I', img, 16, new_rs)
        print('[i] header ramdisk_size %d -> %d（仍在同一 page 对齐段内）'
              % (rs, new_rs))

    img[r_off:r_off + seg_limit] = new_gz + b'\x00' * (seg_limit - len(new_gz))
    # header id (0x240..0x260) 保留原值：unlocked 设备 bootloader 不校验

    chk = bytes(img[r_off:r_off + new_rs])
    chk_entries, _ = parse_cpio(gzip.decompress(chk))
    chk_rc = [x for x in chk_entries if x['name'] == 'init.rk30board.rc']
    ok = (len(chk_rc) == 1
          and b'setprop persist.vendor.resolution.main 3200x1600@70' in chk_rc[0]['data']
          and len(chk_entries) == len(entries))
    other_same = all(
        before.get(x['name']) == hashlib.md5(x['data']).hexdigest()
        for x in chk_entries if x['name'] != 'init.rk30board.rc')
    print('[i] 自检: 重新解析 %d 条, 新 rc=%s, 既有文件字节一致=%s'
          % (len(chk_entries), ok, other_same))
    if not (ok and other_same):
        print('[FATAL] 自检失败，拒绝写出')
        return 1
    head_same = (bytes(img[:16]) == orig[:16]
                 and bytes(img[20:r_off]) == orig[20:r_off])
    tail_same = bytes(img[r_off + seg_limit:]) == orig[r_off + seg_limit:]
    print('[i] header(除 ramdisk_size)/kernel/second/尾部逐字节一致: %s / %s'
          % (head_same, tail_same))
    if not (head_same and tail_same):
        print('[FATAL] 段外字节发生变化，拒绝写出')
        return 1

    open(dst, 'wb').write(img)
    print('[OK] 已写出 %s (%d bytes)' % (dst, len(img)))
    print('     sha256 =', hashlib.sha256(img).hexdigest()[:32])
    print('[!] 本工具不刷机。原始 %s 保持不动，随时可刷回。' % src)
    return 0


if __name__ == '__main__':
    sys.exit(main())
