#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 com.huawei.hvrsdkserverapp 二进制 AXML 里「挂在 <application> 外面」的
5 个补丁组件，在 <application> 内原样克隆一份。

实测（2026-11-06）：
  fix/apks/com.huawei.hvrsdkserverapp.apk（= 设备上装的包，md5 7cb3e564…）
  的 aapt dump xmltree 里：
      46/50 行  service  .compat.VrGlassWatchService / .MyService
      54/58/63  provider hvrcompat.ctx / ctx1 / ctx2
      68 行     E: application
  即 5 个组件全是 <manifest> 的直接子节点，PackageParser 直接忽略 ——
  所以 dumpsys package 一个都查不到，am start-service 报 "not found"。
  类其实都在 dex 里：
      classes4.dex  -> VrGlassWatchService / HvrContextProvider / ContextEx
      classes.dex   -> MyService / VrHelmetExt
  assets/hvrframework.dex 里还有 VrHelmetExt。

这是 com.huawei.vrservice ctx0 那个已验证 bug 的同款（节点 pos 小于
<application> pos）。沿用 add_ctx0_vrservice.py 的已验证做法：保留错位节点
（系统忽略、无害），在 <application> 内 append 一份属性逐条相同的实例。

只改 AndroidManifest.xml；其余条目（含 123MB 的 .so/assets）压缩方式与内容
逐条原样保留；签名条目剔除，交由 zipalign + apksigner 重新签。
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "patches"))
import axml_edit  # noqa: E402

SRC = ROOT / "fix/apks/com.huawei.hvrsdkserverapp.apk"
OUT = ROOT / "build/tmp/ctxa/hvrsdkserverapp_manifest_unsigned.apk"

EXPECTED_NAMES = {
    ".compat.VrGlassWatchService",
    ".MyService",
}
EXPECTED_AUTHORITIES = {
    "com.huawei.hvrsdkserverapp.hvrcompat.ctx",
    "com.huawei.hvrsdkserverapp.hvrcompat.ctx1",
    "com.huawei.hvrsdkserverapp.hvrcompat.ctx2",
}


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def patch(manifest_bytes):
    doc = axml_edit.BinaryXml(manifest_bytes)
    apps = doc.find_start_elements("application")
    if len(apps) != 1:
        raise SystemExit("期望恰好一个 <application>，实际 %d" % len(apps))
    app_pos = apps[0][0]

    misplaced = []
    for tag in ("service", "provider"):
        for pos, el in doc.find_start_elements(tag):
            if pos < app_pos:
                misplaced.append((pos, tag, el))
    misplaced.sort()
    print("    错位组件（pos < application=%d）:" % app_pos)
    for pos, tag, el in misplaced:
        key = doc.attribute(el, "name")
        auth = doc.attribute(el, "authorities")
        print("      pos=%-3d %-8s name=%-45s auth=%s" % (pos, tag, key, auth))

    names = {doc.attribute(el, "name") for _, tag, el in misplaced
             if tag == "service"}
    auths = {doc.attribute(el, "authorities") for _, tag, el in misplaced
             if tag == "provider"}
    if names != EXPECTED_NAMES:
        raise SystemExit("错位 service 集合不符：%s" % (names,))
    if auths != EXPECTED_AUTHORITIES:
        raise SystemExit("错位 provider 集合不符：%s" % (auths,))
    if len(misplaced) != 5:
        raise SystemExit("期望 5 个错位组件，实际 %d" % len(misplaced))

    # 每个错位节点都是叶子（无 intent-filter 等子节点），属性是完整 7 元组，
    # 直接交给 ElementTree 原样重建，不丢任何 android:* 属性与数据类型。
    clones = [axml_edit.ElementTree(el.name_index, el.attributes)
              for _, _, el in misplaced]
    doc.append_children(app_pos, clones)
    out = doc.build()

    check = axml_edit.BinaryXml(out)
    app2 = check.find_start_elements("application")[0][0]
    in_app = [(pos, tag, check.attribute(el, "name"),
               check.attribute(el, "authorities"))
              for tag in ("service", "provider")
              for pos, el in check.find_start_elements(tag)
              if pos > app2]
    print("    修之后 <application> 内的组件（pos > application=%d）:" % app2)
    for row in in_app:
        print("      pos=%-3d %-8s name=%-45s auth=%s" % row)
    got_names = {r[2] for r in in_app if r[1] == "service"}
    got_auths = {r[3] for r in in_app if r[1] == "provider"}
    if not EXPECTED_NAMES.issubset(got_names):
        raise SystemExit("service 未全部落进 <application>：%s" % got_names)
    if not EXPECTED_AUTHORITIES.issubset(got_auths):
        raise SystemExit("provider 未全部落进 <application>：%s" % got_auths)
    return out


def main():
    with zipfile.ZipFile(SRC) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}
    old = blobs["AndroidManifest.xml"]
    print("[1] 修补二进制 AXML: %d bytes" % len(old))
    new = patch(old)
    print("    -> %d bytes" % len(new))
    if new == old:
        raise SystemExit("manifest 未变化")
    blobs["AndroidManifest.xml"] = new

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
        # 除 manifest 外内容也必须逐字节一致
        content_diff = [k for k in cb
                        if k != "AndroidManifest.xml" and a.read(k) != b.read(k)]
        if content_diff:
            raise SystemExit("非 manifest 条目内容被改变：%s" % content_diff[:5])
        so = [(k, v) for k, v in ca.items()
              if k.startswith("lib/") and k.endswith(".so")]
        print("[2] 重打包 OK：条目 %d -> %d；压缩方式与其他条目内容逐条一致"
              % (len(infos), len(kept)))
        print("    .so 共 %d，STORED %d" %
              (len(so), len([1 for _, v in so if v == zipfile.ZIP_STORED])))
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
