"""把 com.huawei.vrhandle 的 VrPoseJni 从「取 runtime 的 64 位 nativeLibraryDir」
改成「取自身的 32 位 nativeLibraryDir」，并把所需 4 个 32 位库打进 APK。

背景（2026-11-05 真机取证）
--------------------------
VrPoseJni.<clinit> 用 r0.y0.j0() 取
    createPackageContext("com.huawei.hvrsdkserverapp", 3)
        .getApplicationInfo().nativeLibraryDir
再拼 4 个 System.load(绝对路径)：
    libMobileSensor.so / libWalleAlg.so / libWalleDev.so / libvrpose.so
catch(UnsatisfiedLinkError) 只打日志，于是 native 方法全空，
VRHandleService 一被问 helmetPoseStart() 就崩。

当前盒子上 runtime 包 primaryCpuAbi=arm64-v8a，系统只解压
lib/arm64-v8a/（ELF64）到 lib/arm64/，lib/arm/ 是空的；
而 com.huawei.vrhandle 是 armeabi-v7a（32 位），加载 ELF64 必然失败。
历史 PATCH_AUDIT.md 6.1 节的成功路径是 runtime 为 32 位、lib/arm/ 有库。

本补丁不再依赖 runtime 的 ABI：
  1. 4 个 ELF32 库放进本包 lib/armeabi-v7a/；
  2. manifest 的 android:extractNativeLibs 改为 true，让系统解压到 lib/arm/；
  3. 新增 compat/HvrPoseLibPath.get()，优先返回自身 nativeLibraryDir
     （校验 libvrpose.so 存在），异常/缺失时 fallback 回原 r0.y0.j0()；
  4. VrPoseJni.<clinit> 里那一处 invoke-static 换成 helper。

不动任何开机脚本、不动系统分区、不动其它包；产物可随时用原包覆盖回退。
"""
from __future__ import annotations

import hashlib
import os
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
JAVA = Path("D:/Tools/AndroidSDK/jdk17tmp/jdk/bin/java.exe")
BT = Path("D:/Tools/AndroidSDK/build-tools/34.0.0")
BAKSMALI = ROOT / "tools/baksmali-fat.jar"
SMALI = ROOT / "tools/smali-fat.jar"
ZIPALIGN = BT / "zipalign.exe"
APKSIGNER = JAVA.parent / "java.exe"
APKSIGNER_JAR = BT / "lib/apksigner.jar"
KEYSTORE = ROOT / "fix/signing/hvr-compat-debug.jks"

BASE = HERE / "vrhandle_base.apk"          # 优先：设备上 pull 下来的原版
BASE_FALLBACK = ROOT / "fix/apks/com.huawei.vrhandle.apk"   # 仓库里的同一份原版
LIBS32 = HERE / "libs32"                    # 从 runtime APK lib/armeabi-v7a/ 解出
RUNTIME_APK = ROOT / "fix/patches/vrdesktop/com.huawei.hvrsdkserverapp-full.apk"
SMALI_DIR = HERE / "smali"
OUT_DEX = HERE / "classes_pose.dex"
UNSIGNED = HERE / "vrhandle_pose_unsigned.apk"
ALIGNED = HERE / "vrhandle_pose_aligned.apk"
SIGNED = HERE / "com.huawei.vrhandle-pose.apk"

POSE_LIBS = [
    "libMobileSensor.so",
    "libWalleAlg.so",
    "libWalleDev.so",
    "libvrpose.so",
]

HELPER_SMALI = r'''.class public final Lcom/huawei/vrhandle/compat/HvrPoseLibPath;
.super Ljava/lang/Object;
.source "HvrPoseLibPath.java"


# direct methods
.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public static get()Ljava/lang/String;
    .locals 3

    :try_start_0
    invoke-static {}, Lcom/huawei/vrhandle/application/VrHandleApplication;->c()Landroid/content/Context;

    move-result-object v0

    if-eqz v0, :cond_fallback

    invoke-virtual {v0}, Landroid/content/Context;->getApplicationInfo()Landroid/content/pm/ApplicationInfo;

    move-result-object v0

    iget-object v0, v0, Landroid/content/pm/ApplicationInfo;->nativeLibraryDir:Ljava/lang/String;

    if-eqz v0, :cond_fallback

    new-instance v1, Ljava/io/File;

    const-string v2, "libvrpose.so"

    invoke-direct {v1, v0, v2}, Ljava/io/File;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    invoke-virtual {v1}, Ljava/io/File;->exists()Z

    move-result v1

    if-eqz v1, :cond_fallback
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-object v0

    :catch_0
    move-exception v0

    :cond_fallback
    invoke-static {}, Lr0/y0;->j0()Ljava/lang/String;

    move-result-object v0

    return-object v0
.end method
'''

OLD_INVOKE = "invoke-static {}, Lr0/y0;->j0()Ljava/lang/String;"
NEW_INVOKE = ("invoke-static {}, "
              "Lcom/huawei/vrhandle/compat/HvrPoseLibPath;->get()Ljava/lang/String;")


def run(cmd):
    print("+", " ".join(str(x) for x in cmd), flush=True)
    subprocess.run([str(x) for x in cmd], check=True)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def step_disassemble():
    if SMALI_DIR.exists():
        shutil.rmtree(SMALI_DIR)
    run([JAVA, "-jar", BAKSMALI, "d", BASE, "-o", SMALI_DIR])
    target = SMALI_DIR / "com/huawei/vrhandle/VrPoseJni.smali"
    assert target.exists(), "VrPoseJni.smali 未找到"


def step_patch_smali():
    target = SMALI_DIR / "com/huawei/vrhandle/VrPoseJni.smali"
    text = target.read_text(encoding="utf-8")
    count = text.count(OLD_INVOKE)
    if count != 1:
        raise SystemExit("VrPoseJni.smali 中 j0() 调用点数量异常：%d" % count)
    target.write_text(text.replace(OLD_INVOKE, NEW_INVOKE), encoding="utf-8")
    print("VrPoseJni.<clinit> 已改用 HvrPoseLibPath.get()")

    dst = SMALI_DIR / "com/huawei/vrhandle/compat/HvrPoseLibPath.smali"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(HELPER_SMALI, encoding="utf-8")
    print("新增 helper:", dst.relative_to(SMALI_DIR))


def step_assemble():
    if OUT_DEX.exists():
        OUT_DEX.unlink()
    run([JAVA, "-jar", SMALI, "a", SMALI_DIR, "-o", OUT_DEX])
    assert OUT_DEX.stat().st_size > 100_000


def patch_extract_native_libs(blob: bytes) -> bytes:
    """只改 application 节点上 extractNativeLibs 的 boolean data：0 -> 0xffffffff。

    不重建 AXML，文件长度与其余字节完全不变。
    """
    import axml_edit as A  # noqa: F401  (仅需常量)

    outer_type, header_size, outer_size = struct.unpack_from("<HHI", blob, 0)
    if outer_type != 0x0003 or outer_size != len(blob):
        raise SystemExit("不是预期的 AXML 容器")

    pos = header_size
    pool = None
    chunks = []
    while pos + 8 <= outer_size:
        ctype, _chsize, csize = struct.unpack_from("<HHI", blob, pos)
        if csize < 8:
            break
        chunks.append((pos, ctype, csize))
        if ctype == 0x0001:
            pool = A.StringPool.parse(blob[pos:pos + csize])
        pos += csize
    if pool is None:
        raise SystemExit("未找到字符串池")

    name_index = pool.strings.index("extractNativeLibs")
    hits = []
    for cpos, ctype, _csize in chunks:
        if ctype != 0x0102:
            continue
        attr_start, attr_size, attr_count = struct.unpack_from("<HHH", blob, cpos + 24)
        base = cpos + 16 + attr_start
        for i in range(attr_count):
            off = base + i * attr_size
            _ns, aname, _raw = struct.unpack_from("<III", blob, off)
            if aname != name_index:
                continue
            size, res0, data_type, data = struct.unpack_from("<HBBI", blob, off + 12)
            hits.append((off, size, res0, data_type, data))
    if len(hits) != 1:
        raise SystemExit("extractNativeLibs 属性命中 %d 处，期望 1 处" % len(hits))
    off, size, res0, data_type, data = hits[0]
    if size != 8 or res0 != 0 or data_type != 0x12 or data != 0:
        raise SystemExit("属性形态异常：size=%d res0=%d type=0x%x data=0x%x"
                         % (size, res0, data_type, data))
    out = bytearray(blob)
    struct.pack_into("<I", out, off + 16, 0xFFFFFFFF)  # boolean true
    assert len(out) == len(blob)
    changed = [i for i, (a, b) in enumerate(zip(blob, out)) if a != b]
    print("AXML extractNativeLibs: false -> true，改动字节", changed)
    return bytes(out)


def step_repack():
    src = zipfile.ZipFile(BASE)
    names = src.namelist()
    dex = OUT_DEX.read_bytes()
    manifest = patch_extract_native_libs(src.read("AndroidManifest.xml"))

    new_libs = {}
    for name in POSE_LIBS:
        p = LIBS32 / name
        data = p.read_bytes()
        if data[4] != 1:
            raise SystemExit("%s 不是 ELF32 (EI_CLASS=%d)" % (name, data[4]))
        new_libs["lib/armeabi-v7a/" + name] = data
    overlap = [k for k in new_libs if k in names]
    if overlap:
        raise SystemExit("以下库条目已存在，需人工确认：%s" % overlap)

    with zipfile.ZipFile(UNSIGNED, "w") as out:
        for item in src.infolist():
            n = item.filename
            if n.startswith("META-INF/") and (
                    n.endswith(".RSA") or n.endswith(".SF") or n.endswith(".DSA")
                    or n == "META-INF/MANIFEST.MF"):
                continue
            data = dex if n == "classes.dex" else (
                manifest if n == "AndroidManifest.xml" else src.read(n))
            zi = zipfile.ZipInfo(n, date_time=item.date_time)
            zi.compress_type = item.compress_type
            zi.external_attr = item.external_attr
            zi.internal_attr = item.internal_attr
            zi.create_system = item.create_system
            zi.comment = item.comment
            out.writestr(zi, data)
        for n, data in new_libs.items():
            zi = zipfile.ZipInfo(n, date_time=(2026, 11, 5, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_STORED   # 原生库必须 STORED
            zi.external_attr = 0o644 << 16
            out.writestr(zi, data)
    src.close()

    # 逐条校验：除已知 3 类变化外，其余条目必须完全一致
    a, b = zipfile.ZipFile(BASE), zipfile.ZipFile(UNSIGNED)
    ca = {i.filename: i for i in a.infolist()}
    cb = {i.filename: i for i in b.infolist()}
    expected_changed = {"classes.dex", "AndroidManifest.xml"}
    expected_added = set(new_libs)
    expected_removed = {n for n in ca if n.startswith("META-INF/") and (
        n.endswith(".RSA") or n.endswith(".SF") or n.endswith(".DSA")
        or n == "META-INF/MANIFEST.MF")}
    removed = set(ca) - set(cb)
    added = set(cb) - set(ca)
    if removed != expected_removed:
        raise SystemExit("删除条目异常：%s" % sorted(removed))
    if added != expected_added:
        raise SystemExit("新增条目异常：%s" % sorted(added))
    changed = [n for n in ca.keys() & cb.keys()
               if a.read(n) != b.read(n) or ca[n].compress_type != cb[n].compress_type]
    if set(changed) != expected_changed:
        raise SystemExit("内容/压缩方式变化异常：%s" % sorted(changed))
    for n in expected_added:
        if cb[n].compress_type != zipfile.ZIP_STORED:
            raise SystemExit("%s 不是 STORED" % n)
    print("逐条校验通过：%d 条原样保留，%d 条改动，%d 条新增，%d 条旧签名剔除"
          % (len(ca) - len(expected_changed) - len(removed), len(expected_changed),
             len(expected_added), len(expected_removed)))
    print("新 APK dex sha256:", sha256(dex))


def step_sign():
    if ALIGNED.exists():
        ALIGNED.unlink()
    run([ZIPALIGN, "-f", "-p", "4", UNSIGNED, ALIGNED])
    if SIGNED.exists():
        SIGNED.unlink()
    run([JAVA, "-jar", APKSIGNER_JAR, "sign",
         "--ks", KEYSTORE,
         "--ks-key-alias", "hvrcompat",
         "--ks-pass", "pass:android",
         "--key-pass", "pass:android",
         "--v1-signing-enabled", "true",
         "--v2-signing-enabled", "true",
         "--out", SIGNED, ALIGNED])
    run([JAVA, "-jar", APKSIGNER_JAR, "verify", "--print-certs", SIGNED])
    print("产物:", SIGNED, SIGNED.stat().st_size, "bytes",
          sha256(SIGNED.read_bytes()))


def prepare_inputs():
    """让脚本在 build/tmp/vrhandle/ 或 fix/patches/vrdesktop/ 下都能独立跑。"""
    global BASE
    if not BASE.exists():
        if not BASE_FALLBACK.exists():
            raise SystemExit("缺少原版 vrhandle APK：%s / %s"
                             % (BASE, BASE_FALLBACK))
        BASE = BASE_FALLBACK
        print("使用仓库内原版基线:", BASE)
    if not LIBS32.exists():
        if not RUNTIME_APK.exists():
            raise SystemExit("缺少 runtime APK，无法解出 32 位库：%s" % RUNTIME_APK)
        LIBS32.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(RUNTIME_APK) as z:
            count = 0
            for n in z.namelist():
                if n.startswith("lib/armeabi-v7a/"):
                    (LIBS32 / os.path.basename(n)).write_bytes(z.read(n))
                    count += 1
        print("从 runtime APK 解出 %d 个 32 位库 -> %s" % (count, LIBS32))
    for name in POSE_LIBS:
        if not (LIBS32 / name).exists():
            raise SystemExit("缺少 32 位库：%s" % (LIBS32 / name))
    for p in (JAVA, BAKSMALI, SMALI, ZIPALIGN, APKSIGNER_JAR, KEYSTORE):
        if not p.exists():
            raise SystemExit("缺少：%s" % p)


def main():
    sys.path.insert(0, str(ROOT / "patches"))
    prepare_inputs()
    step_disassemble()
    step_patch_smali()
    step_assemble()
    step_repack()
    step_sign()


if __name__ == "__main__":
    main()
