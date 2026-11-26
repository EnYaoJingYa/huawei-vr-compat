#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 com.huawei.vrservice 的 manifest 里定义 com.huawei.android.permission.VR。

实测（2026-11-06）：
  VrParamsProviderService 声明
      android:permission="com.huawei.android.permission.VR"
  但系统里这个权限**没有任何包定义**（pm grant 报 Unknown permission）。
  launcherx 虽然声明了 uses-permission，仍拿不到，绑定被拒：
      ActivityManager: Permission Denial: Accessing service
      com.huawei.vrservice/com.huawei.vrinstaller.service.VrParamsProviderService
      ... requires com.huawei.android.permission.VR
  -> HvrSystemClient.cpp:Init(84) "init failed, or on mobile mode"
  -> UnityPlugin: CheckVrMode, is not VRMode, exit -> ApplicationQuit。

  EMUI 上这是框架（android 包）定义的权限；通用安卓得由同签名的 VR 包自己定义。
  项目里 CLIENT_SERVICE / VR.DEVICE_MESSAGE 就是这么补的（PATCH_AUDIT 5.3）。
  protectionLevel 用 signature(0x2)，不用 signature|privileged(0x3)：
  launcherx 是普通应用，同签名即可自动授予。

位置：必须是 <manifest> 直接子级（<application> 之外），和已有 <permission>
节点同层；这次不是"挂错位置"那个 bug，别往 application 里塞。
只改 AndroidManifest.xml，其余条目逐字节原样；签名条目剔除。
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "patches"))
import axml_edit  # noqa: E402

SRC = ROOT / "build/tmp/ctxa/vrservice_ctx0_signed.apk"
OUT = ROOT / "build/tmp/ctxa/vrservice_perm_unsigned.apk"
PERM = "com.huawei.android.permission.VR"


def is_signature_entry(name):
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def starts(doc, tag):
    """按元素名遍历。

    不用 BinaryXml.find_start_elements()：它在字符串池存在重复条目时，
    index_of() 取到的索引和节点实际 name_index 可能不同（实测 vrservice
    的 "permission" 就命中了这个坑，明明有 2 个节点却返回空）。
    """
    return [(pos, payload) for pos, (ctype, payload) in enumerate(doc.entries)
            if ctype == axml_edit.RES_XML_START_ELEMENT_TYPE
            and doc.element_name(payload) == tag]


def attr_string(doc, el, name):
    for ns, aname, raw, size, res0, dtype, data in el.attributes:
        if doc.pool.strings[aname] == name:
            if dtype == axml_edit.TYPE_STRING:
                return doc.pool.strings[data]
            return data
    return None


def patch(data):
    doc = axml_edit.BinaryXml(data)
    apps = starts(doc, "application")
    if len(apps) != 1:
        raise SystemExit("期望恰好一个 <application>，实际 %d" % len(apps))
    app_pos = apps[0][0]

    perm_nodes = starts(doc, "permission")
    existing = [attr_string(doc, el, "name") for _, el in perm_nodes]
    if PERM in existing:
        raise SystemExit("权限已定义，无需重复添加：%s" % existing)
    print("    已有 <permission>:", existing)

    android_ns = doc.pool.index_of("http://schemas.android.com/apk/res/android")
    # 复制现有 <permission> 节点的 protectionLevel 属性元组，只把值改成
    # signature(0x2)，保持 size/res0/data_type 编码与原包完全一致。
    proto = None
    for _, el in perm_nodes:
        for attr in el.attributes:
            if doc.pool.strings[attr[1]] == "protectionLevel":
                proto = attr
                break
        if proto:
            break
    if proto is None:
        raise SystemExit("找不到现成的 protectionLevel 属性模板")

    name_attr = axml_edit.StartElement.string_attribute(
        android_ns, doc.pool.add("name"), doc.pool.add(PERM))
    prot_attr = (proto[0], proto[1], proto[2], proto[3], proto[4],
                 proto[5], 0x2)  # TYPE_INT_HEX/DEC 沿用，值改成 signature
    tree = axml_edit.ElementTree(doc.pool.add("permission"),
                                 [name_attr, prot_attr])
    doc.insert_before(app_pos, [tree])
    out = doc.build()

    check = axml_edit.BinaryXml(out)
    app2 = starts(check, "application")[0][0]
    found = [(pos, attr_string(check, el, "name"), pos < app2)
             for pos, el in starts(check, "permission")]
    print("    修之后 <permission>:", found)
    hit = [f for f in found if f[1] == PERM]
    if len(hit) != 1 or not hit[0][2]:
        raise SystemExit("新权限不在 <application> 之外，停止")
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
        changed = [k for k in cb if a.read(k) != b.read(k)]
        if changed != ["AndroidManifest.xml"]:
            raise SystemExit("除 manifest 外还有条目变化：%s" % changed[:5])
        print("[2] 校验通过：仅 manifest 变化，其余 %d 条逐字节一致"
              % (len(kept) - 1))
    print("完成（未签名）：%s" % OUT)


if __name__ == "__main__":
    main()
