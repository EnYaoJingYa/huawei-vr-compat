#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 assets/arm64-v8a 的 64 位原生库正式放进 lib/arm64-v8a/。

实测（2026-11-06）：
  盒子 primaryCpuAbi=arm64-v8a。原包只有 lib/armeabi-v7a/（29 个 32 位库），
  当前 fix 包额外加了 lib/arm64-v8a/ 里 3 个 C++ 运行库，于是系统把整包判成
  64 位，但其余 26 个 64 位库还留在 assets/arm64-v8a/ 没进 lib 路径：
      MyService.<clinit> -> dlopen failed: library "libHVRSDKServerApp.so" not found
      -> setServiceContext 无实现 -> FATAL -> 服务崩溃循环
  运行时把 29 个库 push 进 /data/app/.../lib/arm64/ 后 MyService 稳定常驻，
  但那是临时手段，重装/覆盖安装就会丢。这里把它固化进 APK。

  依赖闭包已核实：libHVRSDKServerApp.so 只多要 libipcserver.so，
  其余全是公开系统库，assets 里全都有，无需外部补库。

只新增条目，不改任何现有条目（含已修好的 AndroidManifest.xml 与 3 个
已有 64 位 C++ 运行库）；签名条目剔除，交由 zipalign + apksigner 重签。
"""
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / "build/tmp/ctxa/hvrsdkserverapp_manifest_signed.apk"
OUT = ROOT / "build/tmp/ctxa/hvrsdkserverapp_full_unsigned.apk"


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def main():
    with zipfile.ZipFile(SRC) as z:
        infos = z.infolist()
        names = set(z.namelist())
        assets = sorted(n for n in names
                        if n.startswith("assets/arm64-v8a/") and n.endswith(".so"))
        add = []
        for n in assets:
            target = "lib/arm64-v8a/" + n.split("/")[-1]
            if target not in names:
                add.append((n, target))
        print("[1] assets/arm64-v8a 共 %d 个库，需补进 lib/arm64-v8a 的 %d 个"
              % (len(assets), len(add)))
        if not add:
            raise SystemExit("没有需要补的库，可能已经固化过")

        kept = [i for i in infos if not is_signature_entry(i.filename)]
        with zipfile.ZipFile(OUT, "w", allowZip64=True) as out:
            for i in kept:
                zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
                zi.compress_type = i.compress_type
                zi.external_attr = i.external_attr
                zi.internal_attr = i.internal_attr
                zi.create_system = i.create_system
                zi.comment = i.comment
                out.writestr(zi, z.read(i.filename))
            # 原生库必须 STORED 且 4 字节对齐，交给后续 zipalign -p 4 处理。
            for src, dst in add:
                zi = zipfile.ZipInfo(dst, date_time=(2026, 11, 6, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_STORED
                zi.external_attr = 0o100644 << 16
                zi.create_system = 3
                out.writestr(zi, z.read(src))

    with zipfile.ZipFile(OUT) as a, zipfile.ZipFile(SRC) as b:
        if a.testzip():
            raise SystemExit("ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_signature_entry(i.filename)}
        diff = [k for k in cb if ca.get(k) != cb[k]]
        if diff:
            raise SystemExit("已有条目压缩方式被改变：%s" % diff[:5])
        changed = [k for k in cb if a.read(k) != b.read(k)]
        if changed:
            raise SystemExit("已有条目内容被改变：%s" % changed[:5])
        lib64 = [n for n in a.namelist()
                 if n.startswith("lib/arm64-v8a/") and n.endswith(".so")]
        print("[2] lib/arm64-v8a 共 %d 个库；现有条目逐字节未变" % len(lib64))
        print("    libHVRSDKServerApp.so:",
              "lib/arm64-v8a/libHVRSDKServerApp.so" in lib64)
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
