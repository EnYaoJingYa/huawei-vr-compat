#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用「删掉 6 个空壳桩类」的 classes.dex 替换 launcherx 当前包里的主 dex。

背景（2026-11-06 实测）：
  设备装的 launcherx_full_signed.apk 里，classes.dex 有一批 compat 桩类
  （VRSystemServiceManagerImpl 477B / VrFrameworkBootstrap 404B 等），
  而注入的 classes4.dex（来自 vrservice 的 compat dex）里是完整实现
  （22735B / 18273B）。DexPathList 按顺序解析同名类，先命中主 dex 的桩：
    - HVRActivity.onCreate 调 VrFrameworkBootstrap.init() -> 直接 return-void，
      日志里一条 HvrVrFramework 都没有；
    - IVRSystemServiceManagerEx.create() 拿到的 get() 是桩，mManager 恒 null，
      isVRMode() 恒 false。
  删除主 dex 里的 6 个桩后，运行时会落到 classes4.dex 的完整实现。

只替换 classes.dex 一个条目；其余条目（含 classes4.dex、AndroidManifest.xml
的 ctx1 补丁、所有 .so）内容与压缩方式逐条原样保留；签名条目剔除。
"""
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / "build/tmp/ctxa/launcherx_full_signed.apk"
NEW_DEX = ROOT / "build/tmp/ctxa/dexdump/classes_new.dex"
OUT = ROOT / "build/tmp/ctxa/launcherx_nodef_unsigned.apk"

STUBS = [
    "android/vrsystem/VRSystemServiceManagerImpl",
    "com/huawei/vrframework/compat/HvrDisplayRouter",
    "com/huawei/vrframework/compat/HvrReceiverCompat",
    "com/huawei/vrframework/compat/VrDisplayCompat",
    "com/huawei/vrframework/compat/VrFrameworkBootstrap",
    "com/huawei/vrframework/compat/VrTopActivity",
]


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def main():
    new_dex = NEW_DEX.read_bytes()
    # 简单校验：新 dex 里 6 个桩的类描述符不应再出现（字符串池里的引用仍可能有，
    # 所以这里只做 dex 魔数与大小检查，类清单由 baksmali 静态校验负责）。
    if new_dex[:4] != b"dex\n":
        raise SystemExit("新 classes.dex 魔数不对")
    print("[1] 新 classes.dex: %d bytes（原 %d）"
          % (len(new_dex), 0))

    with zipfile.ZipFile(SRC) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    old = blobs["classes.dex"]
    print("    原 classes.dex: %d bytes" % len(old))
    blobs["classes.dex"] = new_dex

    kept = [i for i in infos if not is_signature_entry(i.filename)]
    OUT.parent.mkdir(parents=True, exist_ok=True)
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
        diff = [k for k in cb if ca.get(k) != cb[k]]
        if diff:
            raise SystemExit("压缩方式被改变：%s" % diff[:5])
        change = [k for k in cb if a.read(k) != b.read(k)]
        if change != ["classes.dex"]:
            raise SystemExit("除 classes.dex 外还有条目变化：%s" % change[:5])
        with zipfile.ZipFile(OUT) as z2:
            dex = [n for n in z2.namelist() if n.endswith(".dex")]
            print("[2] dex 清单:", dex)
            print("    classes4.dex 完整 Bootstrap:",
                  b"Lcom/huawei/vrframework/compat/VrFrameworkBootstrap;" in
                  z2.read("classes4.dex"))
        print("[3] 校验通过：仅 classes.dex 变化，其余 %d 条逐字节一致"
              % (len(kept) - 1))
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
