#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统一 SDK 类副本：把 Activity 交给 native SetClass 实际持有的那份 Class。

背景（2026-11-06 冷启动 logcat 实证，见 shared/java/.../HvrSdkBridge.java）：
  LibUpdate 走 1.0 fallback + common app，用 DexClassLoader(hvrframework.dex)
  定义 VrFramework 等 5 个类，经 LibUpdateClient.loadClass(int, Object) 交给
  native SetClass；VrFrameworkBootstrap 另建 DexClassLoader(base.apk) 定义第
  二份 VrFramework，把 init(Activity) 调在它上面。静态字段按类对象隔离 ->
  native 侧 VrFramework.mAppActivity 恒 null ->
  E VrSystemClient: App activity is null -> CheckVrMode not VRMode ->
  ApplicationQuit。

改法（只动 launcherx 的 classes.dex，一个条目）：
  1) 新增 compat/HvrSdkBridge.smali（由 javac + d8 + baksmali 生成，见
     shared/java/com/huawei/vrframework/compat/HvrSdkBridge.java）；
  2) LibUpdateClient.loadClass() 入口 -> HvrSdkBridge.offer(index, cls)；
  3) HVRActivity.onCreate() 在 runUpdate() 之前 -> HvrSdkBridge.setActivity(this)；
  4) 重编译 classes.dex，替换进 launcherx_libupd_signed.apk；
     其余 1219 条（含 classes4.dex、所有 .so、AXML）逐字节与压缩方式原样保留。

不改系统分区、不改开机脚本、不动 SDK/runtime 包、不伪造 VR 状态。
回退：装回 com.huawei.vrlauncherx-full.apk 即可。
"""
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DX = ROOT / "build/tmp/ctxa/dexdump"
SMALI = DX / "smali1"
BRIDGE_SRCDIR = ROOT / "build/tmp/ctxa/bridge/smali/com/huawei/vrframework/compat"
BRIDGE_DSTDIR = SMALI / "com/huawei/vrframework/compat"

CLIENT = SMALI / "com/huawei/hvr/LibUpdateClient.smali"
ACTIVITY = SMALI / "com/huawei/vrlab/HVRActivity.smali"

BRIDGE = "Lcom/huawei/vrframework/compat/HvrSdkBridge;"

OFFER_OLD = """    .line 1
    :try_start_0
    invoke-static {p0, p1}, Lcom/huawei/hvr/LibUpdateClient;->setClass(ILjava/lang/Object;)V
"""
OFFER_NEW = """    .line 1
    :try_start_0
    invoke-static {p0, p1}, %s->offer(ILjava/lang/Object;)V

    invoke-static {p0, p1}, Lcom/huawei/hvr/LibUpdateClient;->setClass(ILjava/lang/Object;)V
""" % BRIDGE

ACT_OLD = """    .line 5
    :cond_23
    :try_start_libupd
"""
ACT_NEW = """    .line 5
    :cond_23
    invoke-static {p0}, %s->setActivity(Landroid/app/Activity;)V

    :try_start_libupd
""" % BRIDGE

# VrSystemClient.init(Activity) 用 activity.getSystemService("vr_system")；
# 通用安卓没有这个系统服务，补一个由 SetClass 类加载器生成的动态代理。
SYSSVC_OLD = """.end method

.method public onKeyDown(ILandroid/view/KeyEvent;)Z
"""
SYSSVC_NEW = """.end method

.method public getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    .registers 3

    invoke-static {p1}, %s->getSystemService(Ljava/lang/String;)Ljava/lang/Object;

    move-result-object v0

    if-eqz v0, :cond_hvr_super

    return-object v0

    :cond_hvr_super
    invoke-super {p0, p1}, Lcom/huawei/vrlab/UnityPlayerActivity;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;

    move-result-object v0

    return-object v0
.end method

.method public onKeyDown(ILandroid/view/KeyEvent;)Z
""" % BRIDGE


def patch(path, old, new, marker):
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print("    [skip] %s 已打过补丁" % path.name)
        return
    n = text.count(old)
    if n != 1:
        raise SystemExit("锚点不唯一/不存在：%s count=%d" % (path.name, n))
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("    [ok] %s" % path.name)


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def build_apk(src_apk, new_dex, out_apk):
    new = new_dex.read_bytes()
    if new[:4] != b"dex\n":
        raise SystemExit("新 dex 魔数不对")
    with zipfile.ZipFile(src_apk) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    old = blobs["classes.dex"]
    print("[3] classes.dex: %d -> %d bytes" % (len(old), len(new)))
    blobs["classes.dex"] = new

    kept = [i for i in infos if not is_signature_entry(i.filename)]
    out_apk.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_apk, "w", allowZip64=True) as z:
        for i in kept:
            zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
            zi.compress_type = i.compress_type
            zi.external_attr = i.external_attr
            zi.internal_attr = i.internal_attr
            zi.create_system = i.create_system
            zi.comment = i.comment
            z.writestr(zi, blobs[i.filename])

    with zipfile.ZipFile(out_apk) as a, zipfile.ZipFile(src_apk) as b:
        if a.testzip():
            raise SystemExit("ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_signature_entry(i.filename)}
        diff = [k for k in cb if ca.get(k) != cb[k]]
        if diff:
            raise SystemExit("压缩方式被改变：%s" % diff[:5])
        changed = [k for k in cb if a.read(k) != b.read(k)]
        if changed != ["classes.dex"]:
            raise SystemExit("除 classes.dex 外还有条目变化：%s" % changed[:5])
        print("[4] 校验通过：仅 classes.dex 变化，其余 %d 条逐字节一致"
              % (len(kept) - 1))


def main():
    import sys
    print("[1] 注入 HvrSdkBridge*.smali 与三处调用点")
    BRIDGE_DSTDIR.mkdir(parents=True, exist_ok=True)
    for f in sorted(BRIDGE_SRCDIR.glob("HvrSdkBridge*.smali")):
        shutil.copyfile(f, BRIDGE_DSTDIR / f.name)
        print("    [ok] %s (%d bytes)" % (f.name, f.stat().st_size))
    patch(CLIENT, OFFER_OLD, OFFER_NEW, "->offer(ILjava/lang/Object;)V")
    patch(ACTIVITY, ACT_OLD, ACT_NEW, "->setActivity(Landroid/app/Activity;)V")
    patch(ACTIVITY, SYSSVC_OLD, SYSSVC_NEW, "->getSystemService(Ljava/lang/String;)Ljava/lang/Object;")
    if "--patch-only" in sys.argv:
        print("[2] --patch-only：只改 smali，跳过打包")
        return

    src = ROOT / "build/tmp/ctxa/launcherx_libupd_signed.apk"
    dex = ROOT / "build/tmp/ctxa/dexdump/classes_bridge4.dex"
    out = ROOT / "build/tmp/ctxa/launcherx_bridge4_unsigned.apk"
    print("[2] 重编译的 dex = %s" % dex)
    if not dex.exists():
        raise SystemExit("先运行 smali 重编译生成 classes_bridge.dex")
    build_apk(src, dex, out)
    print("完成（未签名）：%s" % out)


if __name__ == "__main__":
    main()
