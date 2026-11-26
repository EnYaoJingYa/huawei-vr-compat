#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 launcherx 注入现成的 compat dex，补齐两个悬空 provider 的类。

根因（2026-11-05 实测）：
  com.huawei.vrlauncherx 的 AndroidManifest.xml 声明了两个 provider
    com.huawei.vrframework.compat.HvrContextProvider
    com.huawei.vrlauncherx.compat.VrSystemRegistryProvider
  但 launcherx 的 classes.dex/2/3 里两个类都不存在 —— 进程一启动就
  ClassNotFoundException 崩溃循环；vrservice 又依赖
  com.huawei.vrlauncherx.registry，被 "depends on provider in dying proc"
  连带杀死，于是 VRService 永远起不来、vr_system 永远 process-local。

修法：com.huawei.vrservice 的 classes4.dex（88KB）里已经编译好全套
compat 类（含上面两个 provider + CompatAppContext + ContextEx），
把它作为 classes4.dex 追加进 launcherx 即可，无需重新编译 Java，
也无需改 manifest（两个 provider 本来就在 <application> 内，位置正确）。

只做最小差分：保留原有每个条目的压缩方式（.so 必须保持 STORED）、
剔除旧签名，之后交给 zipalign -p 4 + apksigner。
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

SRC = ROOT / "build/tmp/ctxa/launcherx_device.apk"      # 设备上正在运行的基线
COMPAT = ROOT / "build/tmp/ctxa/vrservice_device.apk"    # 现成 compat dex 的来源
OUT = ROOT / "build/tmp/ctxa/launcherx_compat_unsigned.apk"
DEX_NAME = "classes4.dex"

REQUIRED = [
    b"Lcom/huawei/vrframework/compat/HvrContextProvider;",
    b"Lcom/huawei/vrlauncherx/compat/VrSystemRegistryProvider;",
    b"Lcom/huawei/vrservice/compat/CompatAppContext;",
]


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def main():
    # ① 取出已编译好的 compat dex 并核对类
    with zipfile.ZipFile(COMPAT) as z:
        compat_dex = z.read(DEX_NAME)
    if not compat_dex.startswith(b"dex\n"):
        raise SystemExit("compat dex magic 不对，停止")
    missing = [r.decode() for r in REQUIRED if r not in compat_dex]
    if missing:
        raise SystemExit("compat dex 缺类：%s" % missing)
    print("[1] compat dex: %s = %d bytes，三个必需类齐全" %
          (DEX_NAME, len(compat_dex)))

    # ② 以设备基线重打包，只追加一个 dex
    with zipfile.ZipFile(SRC) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    if DEX_NAME in blobs:
        raise SystemExit("基线里已经有 %s，停止（避免重复注入）" % DEX_NAME)

    kept, dropped = [], []
    for i in infos:
        if is_signature_entry(i.filename):
            dropped.append(i.filename)
        else:
            kept.append(i)

    with zipfile.ZipFile(OUT, "w", allowZip64=True) as z:
        for i in kept:
            zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
            zi.compress_type = i.compress_type
            zi.external_attr = i.external_attr
            zi.internal_attr = i.internal_attr
            zi.create_system = i.create_system
            zi.comment = i.comment
            z.writestr(zi, blobs[i.filename])
        zi = zipfile.ZipInfo(DEX_NAME, date_time=kept[0].date_time)
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, compat_dex)

    print("[2] 重打包 %s（条目 %d -> %d，剔除旧签名 %d 个）" %
          (OUT.name, len(infos), len(kept) + 1, len(dropped)))

    # ③ 逐条断言：原条目一个不少、压缩方式不变、.so 全部 STORED
    with zipfile.ZipFile(OUT) as a, zipfile.ZipFile(SRC) as b:
        if a.testzip():
            raise SystemExit("ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_signature_entry(i.filename)}
        diff = [k for k, v in cb.items() if ca.get(k) != v]
        if diff:
            raise SystemExit("以下条目压缩方式被改变（.so 会装不上）：%s" % diff[:5])
        so = [(k, v) for k, v in ca.items()
              if k.startswith("lib/") and k.endswith(".so")]
        stored = [k for k, v in so if v == zipfile.ZIP_STORED]
        if DEX_NAME not in ca:
            raise SystemExit("新 dex 没写进去")
        # 注意：这版 launcherx 是 extractNativeLibs=true，.so 本来就是 DEFLATED。
        # 安全条件是「与原包逐条一致」（上面的 diff 已断言），不能硬性要求 STORED。
        print("[3] 校验通过：原条目压缩方式逐条一致；.so 共 %d（STORED %d，"
              "与原包一致）；%s 已注入" % (len(so), len(stored), DEX_NAME))
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
