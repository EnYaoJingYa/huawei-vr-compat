#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apk-repack-sign.py —— 改 AndroidManifest 后就地重签（不依赖 JDK）

背景
----
本机的工程 JDK 是裁剪版（``jdk17tmp/jdk/bin`` 只有 ``server``，没有
``java.exe`` / ``javac.exe``），``apktool`` 与 ``apksigner`` 都跑不起来。
但重签只需要两件事：

  1. 改 ``AndroidManifest.xml`` 里的 ``android:sharedUserId``
     —— ``patches/axml_edit.py`` 已能直接改二进制 AXML；
  2. 用同一个密钥重算 v1 签名
     —— ``signing/hvr-compat-debug.jks`` 实际是 **PKCS#12**，
        ``openssl`` 能直接导出私钥，再用 ``openssl smime`` 生成 PKCS#7。

于是整条链只需要 Python + openssl。

适用范围
--------
只做 **v1（JAR）签名**。Android 11 仅在 ``targetSdkVersion >= 30`` 时强制
v2，本项目七个包的 targetSdk 是 26/28/29，v1 足够。

做了哪些事
----------
* 删除根 ``<manifest>`` 上的指定属性（默认 ``sharedUserId``）
* 丢掉原包的 ``META-INF/*.SF|*.RSA|*.DSA|*.EC|MANIFEST.MF``
* 用 SHA-256 重算 ``MANIFEST.MF`` / ``CERT.SF``，并调 openssl 生成 ``CERT.RSA``
* 按 Android 要求保持 ``resources.arsc`` 不压缩且 4 字节对齐
  （用 0xD935 padding extra field，等价于 zipalign）

用法
----
    python tools/apk-repack-sign.py <输入.apk> <输出.apk> \
        [--key .tmp-sign/key.pem] [--cert .tmp-sign/cert.pem] \
        [--drop sharedUserId] [--digest SHA-256]

只查看不写入：

    python tools/apk-repack-sign.py <输入.apk> --inspect
"""

import argparse
import base64
import hashlib
import io
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "patches"))

ALIGNMENT = 4
PADDING_EXTRA_ID = 0xD935  # zipalign 用的对齐填充字段

SIGNATURE_SUFFIXES = (".SF", ".RSA", ".DSA", ".EC")
MANIFEST_NAME = "META-INF/MANIFEST.MF"


def is_signature_entry(name: str) -> bool:
    upper = name.upper()
    if upper == MANIFEST_NAME:
        return True
    return upper.startswith("META-INF/") and upper.endswith(SIGNATURE_SUFFIXES)


# ---------------------------------------------------------------- manifest

def patch_manifest(data: bytes, drop_attrs) -> bytes:
    from axml_edit import BinaryXml  # noqa: E402

    document = BinaryXml(data)
    roots = document.find_start_elements("manifest")
    if not roots:
        raise SystemExit("AndroidManifest.xml 里找不到 <manifest> 根节点")
    position, manifest = roots[0]

    for attr in drop_attrs:
        # axml_edit 的 attribute() 在字符串池里没有该名字时会抛 ValueError，
        # 所以先查池子；池子里没有就等于整份 manifest 都没这个属性。
        if attr not in document.pool.strings:
            print("  %s: 本来就没有" % attr)
            continue
        old = document.attribute(manifest, attr)
        if old is None:
            print("  %s: 本来就没有" % attr)
            continue
        removed = document.drop_attribute(manifest, attr)
        if removed != 1:
            raise SystemExit("%s 期望删除 1 个属性，实际 %d" % (attr, removed))
        print("  %s: 已删除 (%r)" % (attr, old))

    return document.build()


def set_int_attribute(document, element_name: str, attr: str, value: int) -> int:
    """把某个元素的整数属性改成指定值（例如 uses-sdk 的 targetSdkVersion）。

    Android 11 起 ``targetSdkVersion >= 30`` 的应用**必须**带 v2+ 签名，
    本工具只做 v1，所以这类包需要把 targetSdk 降下来（与其余六包一致）。
    """
    changed = 0
    for _, element in document.find_start_elements(element_name):
        if attr not in document.pool.strings:
            break
        index = document.pool.index_of(attr)
        for i, (ns, aname, raw, size, res0, data_type, data) in enumerate(
                element.attributes):
            if aname != index:
                continue
            old = data if data_type != 0x03 else document.pool.strings[data]
            element.attributes[i] = (ns, aname, raw, size, res0, 0x10, value)
            print("  %s.%s: %r -> %d" % (element_name, attr, old, value))
            changed += 1
    if not changed:
        print("  %s.%s: 没找到（跳过）" % (element_name, attr))
    return changed


def inspect(path: str) -> int:
    from axml_edit import BinaryXml  # noqa: E402

    with zipfile.ZipFile(path) as zf:
        data = zf.read("AndroidManifest.xml")
    document = BinaryXml(data)
    for position, manifest in document.find_start_elements("manifest"):
        print("package      :", document.attribute(manifest, "package"))
        print("sharedUserId :", document.attribute(manifest, "sharedUserId"))
        print("versionName  :", document.attribute(manifest, "versionName"))
        break
    return 0


# ---------------------------------------------------------------- zip 重写

def alignment_for(name: str, compress: int) -> int:
    """未压缩条目要落在多少字节边界上（等价 zipalign / zipalign -p）。

    * ``.so``：``android:extractNativeLibs=false`` 时平台直接 mmap，要求
      **按页对齐**（4096）。不对齐装包时报
      ``INSTALL_FAILED_INVALID_APK: Failed to extract native libraries, res=-2``。
    * ``resources.arsc``：4 字节。
    * 其余未压缩条目：4 字节。
    """
    if compress != zipfile.ZIP_STORED:
        return 1
    if name.endswith(".so"):
        return 4096
    return 4


def align_extra(current_offset: int, name_len: int, alignment: int = 4) -> bytes:
    """算出让数据区落在 alignment 边界所需的 padding extra field。"""
    if alignment <= 1:
        return b""
    data_offset = current_offset + 30 + name_len
    pad = (-data_offset) % alignment
    if pad == 0:
        return b""
    if pad < 4:
        pad += alignment  # 至少放得下一个 extra 头的 4 字节
    payload = pad - 4
    if payload > 0xFFF0:
        return b""
    return struct.pack("<HH", PADDING_EXTRA_ID, payload) + b"\x00" * payload


def rewrite_zip(out_path: str, entries) -> None:
    """entries: [(name, data, compress_type, external_attr, date_time)]"""
    with open(out_path, "wb") as fp:
        with zipfile.ZipFile(fp, "w", allowZip64=False) as zf:
            for name, data, compress, external_attr, date_time in entries:
                info = zipfile.ZipInfo(name, date_time)
                info.compress_type = compress
                info.external_attr = external_attr
                info.create_system = 0
                if compress == zipfile.ZIP_STORED:
                    info.extra = align_extra(
                        fp.tell(), len(name.encode("utf-8")),
                        alignment_for(name, compress))
                else:
                    info.extra = b""
                info.file_size = len(data)
                zf.writestr(info, data)


# ---------------------------------------------------------------- v1 签名

def fold_line(line: bytes, width: int = 72) -> bytes:
    """按 JAR 规范折行：单行 <= 72 字节，续行以一个空格开头。"""
    if len(line) <= width:
        return line + b"\r\n"
    out = [line[:width]]
    rest = line[width:]
    while rest:
        out.append(b" " + rest[: width - 1])
        rest = rest[width - 1:]
    return b"\r\n".join(out) + b"\r\n"


def digest_b64(data: bytes, algorithm: str) -> bytes:
    h = hashlib.new(algorithm.replace("-", "").lower())
    h.update(data)
    return base64.b64encode(h.digest())


def build_manifest_mf(entries, algorithm: str) -> bytes:
    out = io.BytesIO()
    out.write(fold_line(b"Manifest-Version: 1.0"))
    out.write(fold_line(b"Created-By: hvr-compat apk-repack-sign"))
    out.write(b"\r\n")
    for name, data in entries:
        section = io.BytesIO()
        section.write(fold_line(("Name: " + name).encode("utf-8")))
        section.write(fold_line(
            f"{algorithm}-Digest: ".encode() + digest_b64(data, algorithm)))
        section.write(b"\r\n")
        out.write(section.getvalue())
    return out.getvalue()


def split_sections(manifest_mf: bytes):
    """把 MANIFEST.MF 切回 [(完整名字, 该段原始字节)]。

    注意：名字可能被折行（JAR 规范每行最多 72 字节），只取第一行会截断，
    必须把续行（以空格开头）拼回去，否则 CERT.SF 里的 Name 与真实条目对不上，
    安装时报 INSTALL_PARSE_FAILED_NO_CERTIFICATES。
    """
    sections = []
    for raw in manifest_mf.split(b"\r\n\r\n"):
        if not raw.startswith(b"Name: "):
            continue
        head, _, rest = raw.partition(b"\r\n")
        name = head[6:]
        while rest.startswith(b" "):
            line, _, rest = rest.partition(b"\r\n")
            name += line[1:]
        sections.append((name.decode("utf-8"), raw + b"\r\n\r\n"))
    return sections


def build_cert_sf(manifest_mf: bytes, algorithm: str) -> bytes:
    out = io.BytesIO()
    out.write(fold_line(b"Signature-Version: 1.0"))
    out.write(fold_line(b"Created-By: hvr-compat apk-repack-sign"))
    out.write(fold_line(
        f"{algorithm}-Digest-Manifest: ".encode()
        + digest_b64(manifest_mf, algorithm)))
    out.write(b"\r\n")
    for name, section in split_sections(manifest_mf):
        body = io.BytesIO()
        body.write(fold_line(("Name: " + name).encode("utf-8")))
        body.write(fold_line(
            f"{algorithm}-Digest: ".encode() + digest_b64(section, algorithm)))
        body.write(b"\r\n")
        out.write(body.getvalue())
    return out.getvalue()


def sign_cert_sf(cert_sf: bytes, key_path: str, cert_path: str) -> bytes:
    """生成 detached PKCS#7（Android 的 CERT.RSA）。"""
    with tempfile.NamedTemporaryFile(suffix=".sf", delete=False) as src:
        src.write(cert_sf)
        sf_path = src.name
    try:
        with tempfile.NamedTemporaryFile(suffix=".p7", delete=False) as dst:
            der_path = dst.name
        cmd = [
            "openssl", "smime", "-sign", "-binary", "-noattr",
            "-in", sf_path, "-signer", cert_path, "-inkey", key_path,
            "-outform", "DER", "-out", der_path,
        ]
        result = subprocess.run(cmd, capture_output=True)
        if result.returncode != 0:
            raise SystemExit("openssl smime 失败：%s"
                             % result.stderr.decode("utf-8", "replace"))
        with open(der_path, "rb") as fp:
            return fp.read()
    finally:
        for path in (sf_path, locals().get("der_path")):
            if path and os.path.exists(path):
                os.remove(path)


# ---------------------------------------------------------------- 主流程

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output", nargs="?")
    ap.add_argument("--inspect", action="store_true")
    ap.add_argument("--drop", action="append", default=None,
                    help="要删除的 manifest 属性，可多次；默认 sharedUserId")
    ap.add_argument("--digest", default="SHA-256")
    ap.add_argument("--target-sdk", type=int, default=None,
                    help="把 uses-sdk 的 targetSdkVersion 改成该值；"
                         ">=30 强制要求 v2 签名，本工具只做 v1")
    ap.add_argument("--key", default=os.path.join(REPO, ".tmp-sign/key.pem"))
    ap.add_argument("--cert", default=os.path.join(REPO, ".tmp-sign/cert.pem"))
    args = ap.parse_args()

    if args.inspect:
        return inspect(args.source)
    if not args.output:
        raise SystemExit("需要输出路径")

    drop_attrs = args.drop if args.drop is not None else ["sharedUserId"]

    with zipfile.ZipFile(args.source) as zf:
        infos = zf.infolist()
        blobs = {info.filename: zf.read(info.filename) for info in infos}

    print("[1/4] 改 AndroidManifest.xml")
    from axml_edit import BinaryXml  # noqa: E402

    manifest_bytes = patch_manifest(blobs["AndroidManifest.xml"], drop_attrs)
    if args.target_sdk is not None:
        document = BinaryXml(manifest_bytes)
        set_int_attribute(document, "uses-sdk", "targetSdkVersion", args.target_sdk)
        manifest_bytes = document.build()
    blobs["AndroidManifest.xml"] = manifest_bytes

    print("[2/4] 丢弃旧 v1 签名")
    dropped = [n for n in blobs if is_signature_entry(n)]
    for name in dropped:
        del blobs[name]
    print("  移除 %d 个：%s" % (len(dropped), ", ".join(sorted(dropped)) or "(无)"))

    print("[3/4] 计算 %s 摘要" % args.digest)
    order = [i.filename for i in infos if i.filename in blobs]
    # Android 要求 resources.arsc 必须不压缩
    digest_entries = [(n, blobs[n]) for n in order]
    manifest_mf = build_manifest_mf(digest_entries, args.digest)
    cert_sf = build_cert_sf(manifest_mf, args.digest)
    print("  MANIFEST.MF %d 字节，CERT.SF %d 字节" % (len(manifest_mf), len(cert_sf)))

    print("[4/4] openssl 生成 CERT.RSA 并重写 zip")
    cert_rsa = sign_cert_sf(cert_sf, args.key, args.cert)
    print("  CERT.RSA %d 字节" % len(cert_rsa))

    entries = []
    for info in infos:
        name = info.filename
        if name in ("AndroidManifest.xml",) or name in blobs:
            if is_signature_entry(name):
                continue
            compress = info.compress_type
            if name == "resources.arsc":
                compress = zipfile.ZIP_STORED
            entries.append((name, blobs[name], compress,
                            info.external_attr, info.date_time))
    for name, data in ((MANIFEST_NAME, manifest_mf),
                       ("META-INF/CERT.SF", cert_sf),
                       ("META-INF/CERT.RSA", cert_rsa)):
        entries.append((name, data, zipfile.ZIP_DEFLATED, 0o600 << 16,
                        (2026, 11, 2, 0, 0, 0)))

    rewrite_zip(args.output, entries)

    with zipfile.ZipFile(args.output) as zf:
        bad = zf.testzip()
        if bad:
            raise SystemExit("产物损坏：%s" % bad)
        stored = [i.filename for i in zf.infolist()
                  if i.compress_type == zipfile.ZIP_STORED]
        print("  产物 %s：%d 条目，STORED %d 个" %
              (args.output, len(zf.infolist()), len(stored)))
    print("完成：%s" % args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
