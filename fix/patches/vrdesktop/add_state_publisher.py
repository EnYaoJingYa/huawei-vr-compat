#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把真实的 SystemServiceBinder 发布到 vr_system_state 注册表（runtime 侧）。

只改 hvrsdkserverapp 的 classes4.dex 一个条目：
  * 新增 HvrStatePublisher.smali（javac + d8 + baksmali 生成）；
  * VrSystemActor.sendConnectHandshake() 在 new SystemServiceBinder(this) 之后
    多调一次 HvrStatePublisher.publish(context, binder)。

不动原有 handshake、不改任何 VR 状态、不改系统分区、不改开机脚本。
回退：装回 com.huawei.hvrsdkserverapp-full.apk 的上一版。
"""
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SMALI = ROOT / "build/tmp/ctxa/runtime_smali4"
HELPER_SRCDIR = ROOT / "build/tmp/ctxa/statepub/smali/com/huawei/hvrsdkserverapp/compat"
HELPER_DSTDIR = SMALI / "com/huawei/hvrsdkserverapp/compat"
ACTOR = SMALI / "com/huawei/hvrsdkserverapp/compat/VrSystemActor.smali"

OLD = """    const-string v4, "system_service_binder"

    invoke-virtual {v2, v4, v3}, Landroid/os/Bundle;->putBinder(Ljava/lang/String;Landroid/os/IBinder;)V

    .line 360
"""
NEW = """    const-string v4, "system_service_binder"

    invoke-virtual {v2, v4, v3}, Landroid/os/Bundle;->putBinder(Ljava/lang/String;Landroid/os/IBinder;)V

    iget-object v4, p0, Lcom/huawei/hvrsdkserverapp/compat/VrSystemActor;->context:Landroid/content/Context;

    invoke-static {v4, v3}, Lcom/huawei/hvrsdkserverapp/compat/HvrStatePublisher;->publish(Landroid/content/Context;Landroid/os/IBinder;)V

    .line 360
"""

SRC_APK = ROOT / "fix/patches/vrdesktop/com.huawei.hvrsdkserverapp-full.apk"
NEW_DEX = ROOT / "build/tmp/ctxa/classes4_statepub.dex"
OUT = ROOT / "build/tmp/ctxa/hvrsdkserverapp_statepub_unsigned.apk"


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def main():
    import sys
    HELPER_DSTDIR.mkdir(parents=True, exist_ok=True)
    files = sorted(HELPER_SRCDIR.glob("HvrStatePublisher*.smali"))
    if not files:
        raise SystemExit("先编译 HvrStatePublisher.java 生成 smali")
    for f in files:
        shutil.copyfile(f, HELPER_DSTDIR / f.name)
        print("[1] helper: %s (%d bytes)" % (f.name, f.stat().st_size))

    text = ACTOR.read_text(encoding="utf-8")
    if "HvrStatePublisher;->publish" in text:
        print("[2] VrSystemActor.smali 已打过补丁")
    else:
        if text.count(OLD) != 1:
            raise SystemExit("锚点不唯一/不存在：count=%d" % text.count(OLD))
        ACTOR.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
        print("[2] VrSystemActor.sendConnectHandshake 插入发布调用")

    if "--patch-only" in sys.argv:
        print("[--patch-only] 只改 smali，跳过打包")
        return

    new = NEW_DEX.read_bytes()
    if new[:4] != b"dex\n":
        raise SystemExit("新 dex 魔数不对")
    with zipfile.ZipFile(SRC_APK) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    print("[3] classes4.dex: %d -> %d bytes"
          % (len(blobs["classes4.dex"]), len(new)))
    blobs["classes4.dex"] = new

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

    with zipfile.ZipFile(OUT) as a, zipfile.ZipFile(SRC_APK) as b:
        if a.testzip():
            raise SystemExit("ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_signature_entry(i.filename)}
        diff = [k for k in cb if ca.get(k) != cb[k]]
        if diff:
            raise SystemExit("压缩方式被改变：%s" % diff[:5])
        changed = [k for k in cb if a.read(k) != b.read(k)]
        if changed != ["classes4.dex"]:
            raise SystemExit("除 classes4.dex 外还有条目变化：%s" % changed[:5])
        print("[4] 校验通过：仅 classes4.dex 变化，其余 %d 条逐字节一致"
              % (len(kept) - 1))
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
