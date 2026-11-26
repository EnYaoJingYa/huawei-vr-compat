#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在已注入 compat dex 的 launcherx 上，再补子进程 HvrContextProvider (ctx1)。

两步合成的最后一环：
  ① inject_compat_dex.py  -> launcherx_compat_unsigned.apk（补齐两个空壳 provider 的类）
  ② 本脚本               -> 给 android:process="com.huawei.vrservice" 的子进程补 provider

为什么必须补：launcherx 的 VRService 客户端组件跑在名为 com.huawei.vrservice 的
子进程里，那里没有任何 ContentProvider，ContextEx.application 永远是 null，
实测该进程每秒刷 "no application context; vr_system stays process-local"，
读不到注册表里的 vr_system binder，原生 SDK 的 CheckVrMode 拿到 NULL
pHelmetHandle 后主动 ApplicationQuit，VR 桌面起不来。
（docs/PATCH_AUDIT.md 64.4 在真机上就是这么修好的）

只改二进制 AndroidManifest.xml，其余条目（含新加的 classes4.dex、全部 .so）
压缩方式/属性原样保留，之后交给 zipalign -p 4 + apksigner。
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "patches"))
from patch_context_provider_processes import patch_binary, authority  # noqa: E402

PKG = "com.huawei.vrlauncherx"
PROCS = ["com.huawei.vrservice"]

# 输入是「已注入 compat dex、但尚未签名」的包，保证一次安装同时带上两项修复
SRC = ROOT / "build/tmp/ctxa/launcherx_compat_unsigned.apk"
OUT = ROOT / "build/tmp/ctxa/launcherx_full_unsigned.apk"
TMP_MF = ROOT / "build/tmp/ctxa/AndroidManifest.full.xml"


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def main():
    with zipfile.ZipFile(SRC) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}

    if "classes4.dex" not in blobs:
        raise SystemExit("输入包里没有 classes4.dex，先跑 inject_compat_dex.py")
    old_mf = blobs["AndroidManifest.xml"]
    if old_mf[:2] != b"\x03\x00":
        raise SystemExit("AndroidManifest.xml 不是二进制 AXML，停止")

    TMP_MF.write_bytes(old_mf)
    patch_binary(TMP_MF, PKG, PROCS)
    new_mf = TMP_MF.read_bytes()
    print("[1] manifest: %d -> %d bytes；新增 authority=%s process=%s"
          % (len(old_mf), len(new_mf), authority(PKG, 1), PROCS[0]))
    if new_mf == old_mf:
        raise SystemExit("manifest 未变化，可能 ctx1 已存在")
    blobs["AndroidManifest.xml"] = new_mf

    kept = [i for i in infos if not is_signature_entry(i.filename)]
    with zipfile.ZipFile(OUT, "w", allowZip64=True) as z:
        for i in kept:
            zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
            zi.compress_type = i.compress_type
            zi.external_attr = i.external_attr
            zi.internal_attr = i.internal_attr
            zi.create_system = i.create_system
            zi.comment = i.comment
            z.writestr(zi, blobs[i.filename])

    with zipfile.ZipFile(OUT) as a, zipfile.ZipFile(SRC) as b:
        if a.testzip():
            raise SystemExit("ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_signature_entry(i.filename)}
        diff = [k for k, v in cb.items() if ca.get(k) != v]
        if diff:
            raise SystemExit("压缩方式被改变：%s" % diff[:5])
        print("[2] 重打包 OK：条目 %d，压缩方式逐条一致，classes4.dex 保留"
              % len(kept))
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
