#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hw-unpack.py —— 华为 UPDATE.APP 内层镜像解包（Android sparse / LP 动态分区）

背景：
  HW-Update-Extractor 只拆到 UPDATE.APP 这一层，倒出来的 SUPER.img / PRELOAD.img
  仍是 Android sparse 格式（magic 0xED26FF3A），SUPER.img 内部还是 LP
  （logical partition）动态分区表。本脚本负责这两层。

特点：
  - 不需要先把 sparse 转成 raw，用块索引随机读，省磁盘（SUPER 4.1G 免落地）
  - LP 元数据直接解析，按 extent 抽取分区，跳过 DONTCARE 空洞

用法：
  python hw-unpack.py info       <img>                    镜像类型 / 块数
  python hw-unpack.py lp-list    <super.img>             列出动态分区
  python hw-unpack.py lp-extract <super.img> <outdir> [名字...]
  python hw-unpack.py raw        <sparse.img> <out.img>  转成 raw（需要空间）
"""
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW, CHUNK_FILL, CHUNK_DONT_CARE, CHUNK_CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4

LP_GEOM_MAGIC = 0x616C4467
LP_HEADER_MAGIC = 0x414C5030
SECTOR = 512


# ------------------------------------------------------------------ sparse
class SparseImage:
    """Android sparse 镜像的随机读取器。非 sparse 时退化为普通文件读取。"""

    def __init__(self, path):
        self.path = path
        self.f = open(path, 'rb')
        self.is_sparse = False
        self.chunks = []          # (chunk_off, chunk_type, out_off, size_bytes, extra)
        self.block_size = SECTOR
        self.total_blocks = 0
        self.size = os.path.getsize(path)
        head = self.f.read(28)
        if len(head) >= 28 and struct.unpack('<I', head[:4])[0] == SPARSE_MAGIC:
            self.is_sparse = True
            (_, _maj, _min, file_hdr_sz, chunk_hdr_sz,
             blk, total_blks, total_chunks, _crc) = struct.unpack('<IHHHHIIII', head)
            self.block_size = blk
            self.total_blocks = total_blks
            self.chunk_hdr_sz = chunk_hdr_sz
            self._index(file_hdr_sz, chunk_hdr_sz, total_chunks)
        else:
            self.f.seek(0, 2)
            self.total_blocks = self.size // SECTOR

    def _index(self, file_hdr_sz, chunk_hdr_sz, total_chunks):
        pos = file_hdr_sz
        out_off = 0
        while len(self.chunks) < total_chunks:
            self.f.seek(pos)
            hdr = self.f.read(chunk_hdr_sz)
            if len(hdr) < 12:
                break
            ctype, _res, chunk_sz, total_sz = struct.unpack('<HHII', hdr[:12])
            data_off = pos + chunk_hdr_sz
            nbytes = chunk_sz * self.block_size
            if ctype == CHUNK_RAW:
                self.chunks.append((data_off, ctype, out_off, nbytes, None))
            elif ctype == CHUNK_FILL:
                fill = self.f.read(4) if chunk_hdr_sz >= 16 else b'\0' * 4
                self.chunks.append((data_off, ctype, out_off, nbytes, fill))
            else:  # DONTCARE / CRC32
                self.chunks.append((data_off, CHUNK_DONT_CARE, out_off, nbytes, None))
            out_off += nbytes
            pos += total_sz
        self.chunks.sort(key=lambda c: c[2])
        self.raw_size = out_off

    def read_at(self, off, size):
        """读取逻辑偏移 off 处 size 字节（越界补零）。"""
        if not self.is_sparse:
            self.f.seek(off)
            buf = self.f.read(size)
            return buf + b'\0' * (size - len(buf))
        out = bytearray()
        end = off + size
        for data_off, ctype, o_off, nbytes, fill in self.chunks:
            c_end = o_off + nbytes
            if c_end <= off:
                continue
            if o_off >= end:
                break
            lo = max(off, o_off)
            hi = min(end, c_end)
            need = hi - lo
            skip = lo - o_off
            if ctype == CHUNK_RAW:
                self.f.seek(data_off + skip)
                out += self.f.read(need)
            elif ctype == CHUNK_FILL:
                pre = skip % 4
                pat = fill[pre:] + fill[:pre]
                out += (pat * ((need + 3) // 4))[:need]
            else:
                out += b'\0' * need
        if len(out) < size:
            out += b'\0' * (size - len(out))
        return bytes(out[:size])

    def close(self):
        try:
            self.f.close()
        except Exception:
            pass


# ---------------------------------------------------------------------- LP
def _cstr(b):
    return b.split(b'\0', 1)[0].decode('utf-8', 'replace')


def find_lp_base(img):
    """定位 super 起始（有的包装会多出 4096 字节前缀）。"""
    for base in (0, 4096, 8192, 1 << 20):
        if struct.unpack('<I', img.read_at(base, 4))[0] == LP_GEOM_MAGIC:
            return base
    # 兜底：在前 1MB 里找第一个几何 magic
    blob = img.read_at(0, 1 << 20)
    i = blob.find(b'\x67\x44\x6c\x61')
    return i if i >= 0 else None


def parse_lp_geometry(img):
    """兼容标准几何块(24B) 与 SHA256 变体(52B)。

    标准布局（liblp）：0..4096 为 LP_PARTITION_RESERVED_BYTES 保留区，
    几何块在 4096 / 8192 两个位置，元数据槽从 12288 起。
    若文件前面还有额外包装，prefix 会体现出来。
    """
    geo_off = find_lp_base(img)
    if geo_off is None:
        return None
    g = img.read_at(geo_off, 4096)
    magic, struct_size = struct.unpack('<II', g[:8])
    if magic != LP_GEOM_MAGIC:
        return None
    if struct_size >= 52:
        # magic(4) size(4) sha256(32) max_size(4) slot_count(4) logical_block_size(4)
        meta_max, slot_cnt, lb_size = struct.unpack('<III', g[40:52])
    else:
        _magic, _sz, _csum, meta_max, slot_cnt, lb_size = struct.unpack('<IIIIII', g[:24])
    return dict(prefix=geo_off - 4096, geo_off=geo_off,
                metadata_max_size=meta_max, slot_count=slot_cnt,
                logical_block_size=lb_size, struct_size=struct_size)


def _pick_header_layout(meta):
    """判断元数据头布局：A=传统(u32 checksum)，B=SHA256 变体。"""
    for layout in ('B', 'A'):
        if layout == 'B':
            tables_size = struct.unpack('<I', meta[44:48])[0]
            doff = 80
        else:
            tables_size = struct.unpack('<I', meta[16:20])[0]
            doff = 24
        desc = [struct.unpack('<III', meta[doff + i * 12: doff + i * 12 + 12]) for i in range(4)]
        # 校验：分区表 entry_size 应为 52，且各表落在 tables_size 内
        ok = desc[0][2] == 52 and tables_size > 0
        for off, num, esz in desc:
            if num and (off + num * esz) > tables_size:
                ok = False
                break
        if ok:
            return layout, tables_size, desc
    raise SystemExit('无法识别 LP 元数据头布局')


def parse_lp_metadata(img, geom):
    """返回 (header, partitions, extents, groups, devices)。"""
    base = geom['prefix'] + 4096 * 3      # 保留区 + 两份几何块之后是元数据槽
    meta = None
    for slot in range(max(geom['slot_count'], 1)):
        off = base + slot * geom['metadata_max_size']
        hdr = img.read_at(off, 256)
        if struct.unpack('<I', hdr[:4])[0] == LP_HEADER_MAGIC:
            meta = hdr
            meta_off = off
            break
    if meta is None:
        raise SystemExit('未找到 LP metadata（不是动态分区镜像？）')

    (magic, major, minor, header_size) = struct.unpack('<IHHI', meta[:12])
    layout, tables_size, desc = _pick_header_layout(meta)

    # 表偏移相对"头部末尾"；若偏移本身已大于 header_size 则视为相对头部起点
    tbl_base = meta_off + header_size if desc[0][0] < header_size else meta_off

    def table(idx):
        doff, num, esz = desc[idx]
        if num == 0:
            return []
        raw = img.read_at(tbl_base + doff, num * esz)
        return [raw[i * esz:(i + 1) * esz] for i in range(num)]

    parts, exts, grps, devs = table(0), table(1), table(2), table(3)

    partitions = []
    for p in parts:
        name = _cstr(p[:36])
        attrs, first_ext, num_ext, grp = struct.unpack('<IIII', p[36:52])
        partitions.append(dict(name=name, attributes=attrs,
                               first_extent_index=first_ext,
                               num_extents=num_ext, group_index=grp))

    extents = []
    for e in exts:
        num_sectors, target_type, target_data, target_source = struct.unpack('<QIQI', e[:24])
        extents.append(dict(num_sectors=num_sectors, target_type=target_type,
                            target_data=target_data, target_source=target_source))

    groups = []
    for g in grps:
        name = _cstr(g[:36])
        flags = struct.unpack('<I', g[36:40])[0]
        max_size = struct.unpack('<Q', g[40:48])[0]
        groups.append(dict(name=name, flags=flags, maximum_size=max_size))

    devices = []
    for d in devs:
        fls, align, align_off, size = struct.unpack('<QIIQ', d[:24])
        name = _cstr(d[24:60])
        devices.append(dict(partition_name=name, first_logical_sector=fls,
                            size=size, alignment=align))

    return dict(major=major, minor=minor, header_size=header_size,
                tables_size=tables_size), partitions, extents, groups, devices


FS_MAGIC = [
    (0xEF53, 'ext4/ext2', 0x438, '<H'),
    (0xE0F5E1E2, 'erofs', 0x400, '<I'),
    (0x3153464A, 'f2fs', 0x400, '<I'),
]


def detect_fs(img, off=0, size=4096):
    head = img.read_at(off, size)
    if len(head) < 0x440:
        return '?'
    for magic, name, moff, fmt in FS_MAGIC:
        if moff + 4 <= len(head):
            try:
                if struct.unpack(fmt, head[moff:moff + struct.calcsize(fmt)])[0] == magic:
                    # f2fs magic 是反序存的，单独确认
                    if name == 'f2fs':
                        if struct.unpack('<I', head[moff:moff + 4])[0] == 0x3153464A:
                            return name
                        continue
                    return name
            except Exception:
                pass
    if head[257:262] == b'ustar':
        return 'tar'
    if head[:4] == b'\x7fELF':
        return 'elf'
    return '?'


# ------------------------------------------------------------------- 命令
def cmd_info(path):
    img = SparseImage(path)
    print(f'文件      : {path}')
    print(f'大小      : {img.size:,} 字节')
    print(f'sparse    : {img.is_sparse}')
    if img.is_sparse:
        print(f'块大小    : {img.block_size}')
        print(f'块数      : {img.total_blocks:,}')
        print(f'展开大小  : {img.raw_size:,} 字节 ({img.raw_size/1024/1024/1024:.2f} GB)')
        print(f'chunk 数  : {len(img.chunks)}')
    print(f'文件系统  : {detect_fs(img)}')
    img.close()


def cmd_lp_list(path):
    img = SparseImage(path)
    geom = parse_lp_geometry(img)
    if not geom:
        print('不是 LP 动态分区镜像')
        return
    hdr, parts, exts, groups, devs = parse_lp_metadata(img, geom)
    print(f'prefix={geom["prefix"]}')
    print(f'逻辑块    : {geom["logical_block_size"]}   槽位 {geom["slot_count"]}   '
          f'meta_max {geom["metadata_max_size"]}')
    print(f'块设备    : ' + ', '.join(d['partition_name'] for d in devs))
    print()
    print(f'{"分区":<24}{"大小":>14}  {"extents":>7}  分组')
    print('-' * 62)
    total = 0
    for p in parts:
        size = sum(exts[i]['num_sectors'] for i in
                   range(p['first_extent_index'],
                         p['first_extent_index'] + p['num_extents'])) * SECTOR
        total += size
        grp = groups[p['group_index']]['name'] if p['group_index'] < len(groups) else '-'
        print(f'{p["name"]:<24}{size:>14,}  {p["num_extents"]:>7}  {grp}')
    print('-' * 62)
    print(f'{"合计":<24}{total:>14,}')
    print()
    print('分组: ' + ', '.join(f'{g["name"]}({g["maximum_size"]//1024//1024 if g["maximum_size"] else "无上限"}MB)'
                            for g in groups))
    img.close()


def cmd_lp_extract(path, outdir, only):
    img = SparseImage(path)
    geom = parse_lp_geometry(img)
    if not geom:
        raise SystemExit('不是 LP 动态分区镜像')
    _hdr, parts, exts, _g, _d = parse_lp_metadata(img, geom)
    os.makedirs(outdir, exist_ok=True)
    for p in parts:
        name = p['name']
        if only and name not in only:
            continue
        el = exts[p['first_extent_index']:p['first_extent_index'] + p['num_extents']]
        size = sum(e['num_sectors'] for e in el) * SECTOR
        outp = os.path.join(outdir, name + '.img')
        print(f'抽取 {name:<24} {size:>14,} 字节 … ', end='', flush=True)
        written = 0
        with open(outp, 'wb') as fo:
            for e in el:
                n = e['num_sectors'] * SECTOR
                if e['target_type'] == 0:  # LINEAR
                    src = geom['prefix'] + e['target_data'] * SECTOR
                    step = 8 << 20
                    left = n
                    while left > 0:
                        k = min(step, left)
                        fo.write(img.read_at(src, k))
                        src += k
                        left -= k
                else:                       # ZERO
                    step = 8 << 20
                    left = n
                    z = b'\0' * min(step, left)
                    while left > 0:
                        k = min(len(z), left)
                        fo.write(z[:k])
                        left -= k
                written += n
        with open(outp, 'rb') as fh:
            head = fh.read(0x440)
        fs = '?'
        for magic, fname, moff, fmt in FS_MAGIC:
            if moff + 4 <= len(head):
                if struct.unpack(fmt, head[moff:moff + struct.calcsize(fmt)])[0] == magic:
                    fs = fname
                    break
        print(f'完成 → {os.path.basename(outp)}  [{fs}]')
    img.close()


def cmd_raw(path, outp):
    img = SparseImage(path)
    if not img.is_sparse:
        print('本来就不是 sparse，无需转换')
        return
    print(f'展开 {path} → {outp} ({img.raw_size:,} 字节)')
    step = 16 << 20
    with open(outp, 'wb') as fo:
        off = 0
        while off < img.raw_size:
            k = min(step, img.raw_size - off)
            fo.write(img.read_at(off, k))
            off += k
            print(f'\r  {off*100//img.raw_size}%', end='', flush=True)
    print('\r  100%')
    img.close()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == 'info':
        cmd_info(sys.argv[2])
    elif cmd == 'lp-list':
        cmd_lp_list(sys.argv[2])
    elif cmd == 'lp-extract':
        cmd_lp_extract(sys.argv[2], sys.argv[3], set(sys.argv[4:]))
    elif cmd == 'raw':
        cmd_raw(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)


if __name__ == '__main__':
    main()
