#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 APK 里指定的 dex 条目换成新文件，其余条目逐条原样保留（含压缩方式）。

签名条目会被剔除，输出的是 unsigned APK，交给 zipalign + apksigner 处理。

用法:
    python replace_dex.py <src.apk> <dex_entry> <new.dex> <out-unsigned.apk>
"""
import sys
import zipfile
from pathlib import Path


def is_sig(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    src, entry, newdex, out = sys.argv[1:5]
    new = Path(newdex).read_bytes()
    if new[:4] != b"dex\n":
        raise SystemExit("新文件不是 dex")

    with zipfile.ZipFile(src) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    if entry not in blobs:
        raise SystemExit(f"APK 里没有 {entry}，可用: "
                         f"{[n for n in blobs if n.endswith('.dex')]}")
    old = blobs[entry]
    blobs[entry] = new
    kept = [i for i in infos if not is_sig(i.filename)]

    outp = Path(out)
    outp.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(outp, "w", allowZip64=True) as z:
        for i in kept:
            zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
            zi.compress_type = i.compress_type
            zi.external_attr = i.external_attr
            zi.internal_attr = i.internal_attr
            zi.create_system = i.create_system
            zi.comment = i.comment
            z.writestr(zi, blobs[i.filename])

    # 复验：压缩方式 + 内容，除目标条目外必须逐字节一致
    with zipfile.ZipFile(outp) as a, zipfile.ZipFile(src) as b:
        if a.testzip():
            raise SystemExit("输出 ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_sig(i.filename)}
        if ca != cb:
            diff = [k for k in cb if ca.get(k) != cb[k]]
            raise SystemExit(f"压缩方式变化: {diff[:5]}")
        changed = [k for k in cb if a.read(k) != b.read(k)]
        if changed != [entry]:
            raise SystemExit(f"非目标条目变化: {changed[:5]}")
    print(f"[OK] {entry}: {len(old)} -> {len(new)} B")
    print(f"[OK] 其余 {len(kept)-1} 条目压缩方式与内容逐字节一致")
    print(f"[OK] unsigned APK: {outp} ({outp.stat().st_size} B)")


if __name__ == "__main__":
    main()
