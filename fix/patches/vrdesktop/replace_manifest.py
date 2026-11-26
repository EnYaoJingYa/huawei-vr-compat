#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 APK 里的 AndroidManifest.xml 换成编译好的二进制 AXML，其余条目原样保留。

与 replace_dex.py 同一套保真逻辑：逐条目复用原压缩方式 / 属性，
输出 unsigned APK，交给 zipalign + apksigner 处理。

用法:
    python replace_manifest.py <src.apk> <manifest.axml> <out-unsigned.apk>
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
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    src, newmnf, out = sys.argv[1:4]
    new = Path(newmnf).read_bytes()
    if not new.startswith(b"\x03\x00\x08\x00"):
        raise SystemExit("manifest 不是二进制 AXML（缺少 RES_XML_TYPE 头）")

    entry = "AndroidManifest.xml"
    with zipfile.ZipFile(src) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    if entry not in blobs:
        raise SystemExit(f"APK 里没有 {entry}")
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

    # 复验：除 manifest 外必须逐字节一致
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
    # 新 manifest 里必须有 ACCESS_BACKGROUND_LOCATION（二进制串池是 UTF-16LE）
    key = "ACCESS_BACKGROUND_LOCATION".encode("utf-16-le")
    assert key in new, "新 manifest 里没有 ACCESS_BACKGROUND_LOCATION"
    print(f"[OK] AndroidManifest.xml: {len(old)} -> {len(new)} B（含后台定位声明）")
    print(f"[OK] 其余 {len(kept)-1} 条目压缩方式与内容逐字节一致")
    print(f"[OK] unsigned APK: {outp} ({outp.stat().st_size} B)")


if __name__ == "__main__":
    main()
