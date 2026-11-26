#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用修复 vrservice <-> launcherx 跨进程 Messenger 的非 Parcelable 载荷。

背景（2026-11-06 真机回归）：
  fix_prepare_msg.py 只把 sendSystemPrepareDoneMsg() 的 Message.obj 置 null，
  短时间窗口看似通了，随后每 ~30s 稳定出现两类 FATAL：

    E AndroidRuntime: FATAL EXCEPTION: VRService_Client_VRWorkThread
        java.lang.NullPointerException: 'int java.lang.Integer.intValue()'
        at t0.c.D -> t0.c.G -> t0.c.b -> t0.c$b.handleMessage
    E AndroidRuntime: FATAL EXCEPTION: VRWorkerThread
        java.lang.RuntimeException: Can't marshal non-Parcelable objects
        across processes.
        at android.os.Message.writeToParcel(Message.java:639)
        at com.huawei.vrservice.ServiceConnector.sendMessageToClient
        at com.huawei.vrservice.VRService.handleEarphonePlugged

根因：Android 的 Message.writeToParcel 只允许 obj 是 Parcelable；原厂 vrservice
用 sendMessageToClient(I, Object) 发送标量（0x3ea Integer、0x3ed Boolean），
EMUI 上这条链多半同进程，通用 Android 跨进程后必然抛异常。而接收端
launcherx 的 t0/c.D(Message) state=4 又要 check-cast Integer，简单置 null
只会把发送端崩溃换成接收端 NPE。

本补丁采用「Bundle 中转 + 接收端还原」，一次覆盖全部调用点：

  [vrservice / classes*.dex / ServiceConnector.smali]
    sendMessageToClient(I, Object) 在装配 Message 时：
      - obj 是 Parcelable -> 原样保留；
      - obj 是 Integer / Boolean / CharSequence -> 写进 Message.data 的
        hvr_compat_int / hvr_compat_bool / hvr_compat_str，obj 置 null；
      - 其它非 Parcelable -> obj 置 null（宁可丢载荷也不崩）。
    VRService.smali 里 13 个发送点全部经此方法，无需逐个改。

  [launcherx / classes*.dex / t0/c$b.smali]
    handleMessage(Message) 在分发给 Lt0/c->b/c/d/e 之前，按 Bundle key
    把 obj 还原成 Integer / Boolean / String，之后所有原厂分支（Integer
    强转、Boolean 判断、Intent/String check-cast）语义完全不变。

另外：vrservice 以 com.huawei.vrservice-full.pre-preparemsg.apk 建立新基准，
等于撤销 fix_prepare_msg.py 的「置 null」错误补丁（它已废弃）。该基准
仍包含 sidemode / hwext / runtime 之前的全部已验证修复。

第二处改动（HvrProximityCompat，2026-11-06 新增）：
  真机上 /dev/ttyUSB* 不存在，vcom 打不开（日志 "5 times can not open
  vcom, stop try."），getProximityNativeJNI() 恒返回 -1。而接收端
  t0/c.P(I) 只有 p1==1 才真正启动 3D 桌面，否则打 "helmet away now,
  wait for proximity msg to start." 后 return —— 这就是修复崩溃链之后
  栈顶停 VRPrepareActivity、UnityMain=0 的原因。
  sendSystemPrepareDoneMsg() 里在读数 <=0（传感器无效）时按「已佩戴」
  处理为 1；若将来 vcom 修好、读数 >0，仍保留原值。这是通用 Android
  盒子上模拟 EMUI 眼镜在位的 compat 适配，可用 --restore 整体回退。

两包都只替换含目标类的那一个 classes*.dex，其余条目逐字节不动，
zipalign -p 4 + apksigner(v1+v2) 沿用 hvr-compat 证书；首次执行自动
备份 *.pre-messenger.apk，之后以备份为基准幂等重生成。

用法：
    python fix/patches/vrdesktop/fix_messenger_payload.py
    python fix/patches/vrdesktop/fix_messenger_payload.py --restore
"""
from __future__ import annotations

import hashlib
import re
import shutil
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
APKSIGNER_JAR = BT / "lib/apksigner.jar"
KEYSTORE = ROOT / "fix/signing/hvr-compat-debug.jks"

MARK = "hvr_compat_int"

# ---------------------------------------------------------------------------
# smali 方法体：整体替换，避免依赖 baksmali 是否输出 .line 调试行
# ---------------------------------------------------------------------------

SERVICE_BODY = """\
.method public sendMessageToClient(ILjava/lang/Object;)V
    .locals 5

    new-instance v0, Landroid/os/Message;

    invoke-direct {v0}, Landroid/os/Message;-><init>()V

    iput p1, v0, Landroid/os/Message;->what:I

    # HvrMessengerPayload: Message.writeToParcel 只接受 Parcelable。
    # 标量载荷改走 Message.data，obj 置 null；接收端 t0/c$b.handleMessage 还原。
    if-eqz p2, :cond_hvr_done

    instance-of v1, p2, Landroid/os/Parcelable;

    if-nez v1, :cond_hvr_done

    invoke-virtual {v0}, Landroid/os/Message;->getData()Landroid/os/Bundle;

    move-result-object v1

    const-string v2, "hvr_compat_int"

    const-string v3, "hvr_compat_bool"

    instance-of v4, p2, Ljava/lang/Integer;

    if-eqz v4, :cond_hvr_bool

    check-cast p2, Ljava/lang/Integer;

    invoke-virtual {p2}, Ljava/lang/Integer;->intValue()I

    move-result v4

    invoke-virtual {v1, v2, v4}, Landroid/os/Bundle;->putInt(Ljava/lang/String;I)V

    goto :cond_hvr_clear

    :cond_hvr_bool
    instance-of v4, p2, Ljava/lang/Boolean;

    if-eqz v4, :cond_hvr_str

    check-cast p2, Ljava/lang/Boolean;

    invoke-virtual {p2}, Ljava/lang/Boolean;->booleanValue()Z

    move-result v4

    invoke-virtual {v1, v3, v4}, Landroid/os/Bundle;->putBoolean(Ljava/lang/String;Z)V

    goto :cond_hvr_clear

    :cond_hvr_str
    instance-of v4, p2, Ljava/lang/CharSequence;

    if-eqz v4, :cond_hvr_clear

    const-string v4, "hvr_compat_str"

    invoke-virtual {p2}, Ljava/lang/Object;->toString()Ljava/lang/String;

    move-result-object v2

    invoke-virtual {v1, v4, v2}, Landroid/os/Bundle;->putString(Ljava/lang/String;Ljava/lang/String;)V

    :cond_hvr_clear
    const/4 p2, 0x0

    :cond_hvr_done
    iput-object p2, v0, Landroid/os/Message;->obj:Ljava/lang/Object;

    invoke-virtual {p0, v0}, Lcom/huawei/vrservice/ServiceConnector;->sendMessageToClient(Landroid/os/Message;)V

    return-void
.end method
"""

LAUNCHER_BODY = """\
.method public handleMessage(Landroid/os/Message;)V
    .locals 3

    if-nez p1, :cond_0

    invoke-static {}, Lt0/c;->a()Ljava/lang/String;

    move-result-object p1

    const-string v0, "handleMessage param error"

    invoke-static {p1, v0}, Lt1/b0;->r(Ljava/lang/String;Ljava/lang/String;)V

    return-void

    :cond_0
    # HvrMessengerPayload: 分发前还原 vrservice 编进 Message.data 的标量载荷
    invoke-virtual {p1}, Landroid/os/Message;->getData()Landroid/os/Bundle;

    move-result-object v0

    const-string v1, "hvr_compat_int"

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->containsKey(Ljava/lang/String;)Z

    move-result v2

    if-eqz v2, :cond_hvr_bool

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->getInt(Ljava/lang/String;)I

    move-result v2

    invoke-static {v2}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;

    move-result-object v2

    iput-object v2, p1, Landroid/os/Message;->obj:Ljava/lang/Object;

    goto :cond_hvr_done

    :cond_hvr_bool
    const-string v1, "hvr_compat_bool"

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->containsKey(Ljava/lang/String;)Z

    move-result v2

    if-eqz v2, :cond_hvr_str

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->getBoolean(Ljava/lang/String;)Z

    move-result v2

    invoke-static {v2}, Ljava/lang/Boolean;->valueOf(Z)Ljava/lang/Boolean;

    move-result-object v2

    iput-object v2, p1, Landroid/os/Message;->obj:Ljava/lang/Object;

    goto :cond_hvr_done

    :cond_hvr_str
    const-string v1, "hvr_compat_str"

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->containsKey(Ljava/lang/String;)Z

    move-result v2

    if-eqz v2, :cond_hvr_done

    invoke-virtual {v0, v1}, Landroid/os/Bundle;->getString(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v2

    iput-object v2, p1, Landroid/os/Message;->obj:Ljava/lang/Object;

    :cond_hvr_done
    iget-object v0, p0, Lt0/c$b;->a:Lt0/c;

    invoke-static {v0, p1}, Lt0/c;->b(Lt0/c;Landroid/os/Message;)Z

    move-result v0

    if-eqz v0, :cond_1

    return-void

    :cond_1
    iget-object v0, p0, Lt0/c$b;->a:Lt0/c;

    invoke-static {v0, p1}, Lt0/c;->c(Lt0/c;Landroid/os/Message;)Z

    move-result v0

    if-eqz v0, :cond_2

    return-void

    :cond_2
    iget-object v0, p0, Lt0/c$b;->a:Lt0/c;

    invoke-static {v0, p1}, Lt0/c;->d(Lt0/c;Landroid/os/Message;)Z

    move-result v0

    if-eqz v0, :cond_3

    return-void

    :cond_3
    iget-object v0, p0, Lt0/c$b;->a:Lt0/c;

    invoke-static {v0, p1}, Lt0/c;->e(Lt0/c;Landroid/os/Message;)Z

    return-void
.end method
"""

# sendSystemPrepareDoneMsg() 的 proximity 读数定点 compat（只在方法体内替换 1 次）。
# 用正则而非整段替换，是因为真机 APK 反编译出的 VrLog 类名 / .registers 写法
# 与仓库 decode/ 旧产物不一致，不能照抄旧文本。
PROX_OLD_RE = re.compile(
    r"    move-result v2\n\n"
    r"    invoke-static \{v2\}, Ljava/lang/Integer;->valueOf\(I\)Ljava/lang/Integer;"
)
PROX_NEW = """\
    move-result v2

    # HvrProximityCompat: vcom 缺失时 getProximityNativeJNI() 返回 -1，
    # t0/c.P(I) 只认 1；读数 <=0（传感器无效）时按「已佩戴」处理。
    if-lez v2, :cond_hvr_prox_force

    goto :cond_hvr_prox_ok

    :cond_hvr_prox_force
    const/4 v2, 0x1

    :cond_hvr_prox_ok
    invoke-static {v2}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;"""

# (产物 APK, 基准备份, 首次基准来源, 目标 smali, dex 定位串, 方法签名, 新方法体)
JOBS = [
    dict(
        name="vrservice",
        apk=HERE / "com.huawei.vrservice-full.apk",
        backup=HERE / "com.huawei.vrservice-full.pre-messenger.apk",
        seed=HERE / "com.huawei.vrservice-full.pre-preparemsg.apk",
        smali="com/huawei/vrservice/ServiceConnector.smali",
        needle=b"Lcom/huawei/vrservice/ServiceConnector;",
        signature=".method public sendMessageToClient(ILjava/lang/Object;)V",
        body=SERVICE_BODY,
        extra=dict(
            smali="com/huawei/vrservice/VRService.smali",
            signature=".method private sendSystemPrepareDoneMsg()V",
        ),
    ),
    dict(
        name="launcherx",
        apk=HERE / "com.huawei.vrlauncherx-full.apk",
        backup=HERE / "com.huawei.vrlauncherx-full.pre-messenger.apk",
        seed=None,
        smali="t0/c$b.smali",
        needle=b"Lt0/c$b;",
        signature=".method public handleMessage(Landroid/os/Message;)V",
        body=LAUNCHER_BODY,
    ),
]


def is_signature_entry(name: str) -> bool:
    u = name.upper()
    if u == "META-INF/MANIFEST.MF":
        return True
    return u.startswith("META-INF/") and u.endswith((".SF", ".RSA", ".DSA", ".EC"))


def run(cmd):
    print("  +", " ".join(str(x) for x in cmd), flush=True)
    subprocess.run([str(x) for x in cmd], check=True)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def replace_method(text: str, signature: str, body: str) -> str:
    """按方法签名整体替换方法体，不依赖 .line 等调试行。"""
    n = text.count(signature)
    if n != 1:
        raise SystemExit("方法签名锚点数量异常：%d（期望 1）: %s" % (n, signature))
    start = text.index(signature)
    end = text.index(".end method", start)
    # body 自带 .end method，必须把原来那一行整行吃掉，否则 smali 会报
    # "missing EOF at '.end method'"（重复的方法结束标记）。
    after = text.index("\n", end) + 1
    return text[:start] + body.strip("\n") + "\n" + text[after:]


def pick_dex(blobs: dict, needle: bytes) -> tuple[str, bytes]:
    """用 dex string table 里的类描述符定位目标 dex。"""
    for name in sorted(n for n in blobs if n.startswith("classes") and n.endswith(".dex")):
        if needle in blobs[name]:
            return name, blobs[name]
    raise SystemExit("未找到含 %s 的 dex" % needle.decode())


def build(job: dict, work: Path) -> None:
    apk, backup, seed = job["apk"], job["backup"], job["seed"]
    print("\n=== [%s] ===" % job["name"])

    if not backup.exists():
        src = seed if (seed is not None and seed.exists()) else apk
        shutil.copy2(src, backup)
        print("[0] 建立基准备份 %s <- %s" % (backup.name, src.name))
        if seed is not None and seed.exists():
            print("    （vrservice 从 pre-preparemsg 出发，撤销废弃的置 null 补丁）")
    else:
        print("[0] 基准包（备份）: %s" % backup.name)

    with zipfile.ZipFile(backup) as z:
        infos = z.infolist()
        blobs = {i.filename: z.read(i.filename) for i in infos}

    dex_name, old_dex = pick_dex(blobs, job["needle"])
    print("[1] %s: %d bytes, sha256=%s" % (dex_name, len(old_dex), sha256(old_dex)[:16]))

    jwork = work / job["name"]
    if jwork.exists():
        shutil.rmtree(jwork)
    jwork.mkdir(parents=True)
    raw = jwork / "classes.orig.dex"
    raw.write_bytes(old_dex)
    tree = jwork / "smali"
    run([JAVA, "-jar", BAKSMALI, "d", raw, "-o", tree])

    target = tree / job["smali"]
    if not target.exists():
        raise SystemExit("未找到 %s" % job["smali"])
    text = target.read_text(encoding="utf-8")
    if job["signature"] not in text:
        raise SystemExit("未找到方法 %s" % job["signature"])
    text = replace_method(text, job["signature"], job["body"])
    target.write_text(text, encoding="utf-8")
    print("[2] 已替换 %s" % job["signature"])

    if job.get("extra"):
        ex = job["extra"]
        ep = tree / ex["smali"]
        etext = ep.read_text(encoding="utf-8")
        head = etext.index(ex["signature"])
        end = etext.index(".end method", head)
        ebody = etext[head:end]
        n = len(PROX_OLD_RE.findall(ebody))
        if n != 1:
            raise SystemExit("proximity 锚点数量异常：%d（期望 1）" % n)
        etext = etext[:head] + PROX_OLD_RE.sub(PROX_NEW, ebody, count=1) + etext[end:]
        ep.write_text(etext, encoding="utf-8")
        print("[2b] 已补 HvrProximityCompat（vcom 缺失时 proximity 视为 1）")

    new_dex_path = jwork / "classes.new.dex"
    run([JAVA, "-jar", SMALI, "a", tree, "-o", new_dex_path])
    new_dex = new_dex_path.read_bytes()
    if new_dex[:4] != b"dex\n" or MARK.encode() not in new_dex:
        raise SystemExit("新 dex 异常（缺少 %s 标记）" % MARK)
    print("[3] 新 dex: %d bytes, sha256=%s" % (len(new_dex), sha256(new_dex)[:16]))
    blobs[dex_name] = new_dex

    kept = [i for i in infos if not is_signature_entry(i.filename)]
    unsigned = jwork / "unsigned.apk"
    print("[4] 重打包 %d 条 ..." % len(kept))
    with zipfile.ZipFile(unsigned, "w", allowZip64=True) as z:
        for i in kept:
            zi = zipfile.ZipInfo(i.filename, date_time=i.date_time)
            zi.compress_type = i.compress_type
            zi.external_attr = i.external_attr
            zi.internal_attr = i.internal_attr
            zi.create_system = i.create_system
            zi.comment = i.comment
            z.writestr(zi, blobs[i.filename])

    with zipfile.ZipFile(unsigned) as a, zipfile.ZipFile(backup) as b:
        if a.testzip():
            raise SystemExit("ZIP 损坏")
        ca = {i.filename: i.compress_type for i in a.infolist()}
        cb = {i.filename: i.compress_type for i in b.infolist()
              if not is_signature_entry(i.filename)}
        diff = [k for k, v in cb.items() if ca.get(k) != v]
        if diff:
            raise SystemExit("压缩方式被改变：%s" % diff[:5])
        changed = [k for k in cb if a.read(k) != b.read(k)]
        if changed != [dex_name]:
            raise SystemExit("除 %s 外还有条目变化：%s" % (dex_name, changed[:5]))
        print("[5] 校验通过：%d 条逐条一致，仅 %s 变化" % (len(cb), dex_name))

    aligned = jwork / "aligned.apk"
    signed = jwork / "signed.apk"
    run([ZIPALIGN, "-f", "-p", "4", unsigned, aligned])
    run([JAVA, "-jar", APKSIGNER_JAR, "sign",
         "--ks", KEYSTORE, "--ks-key-alias", "hvrcompat",
         "--ks-pass", "pass:android", "--key-pass", "pass:android",
         "--v1-signing-enabled", "true", "--v2-signing-enabled", "true",
         "--out", signed, aligned])
    run([JAVA, "-jar", APKSIGNER_JAR, "verify", signed])
    print("[6] 签名完成 sha256=%s" % sha256(signed.read_bytes())[:16])
    shutil.copy2(signed, apk)


def main() -> int:
    if "--restore" in sys.argv:
        for job in JOBS:
            if job["backup"].exists():
                shutil.copy2(job["backup"], job["apk"])
                print("[restore] %s <- %s" % (job["apk"].name, job["backup"].name))
        return 0

    for p in (JAVA, BAKSMALI, SMALI, ZIPALIGN, APKSIGNER_JAR, KEYSTORE):
        if not p.exists():
            raise SystemExit("缺少：%s" % p)
    for job in JOBS:
        if not job["apk"].exists():
            raise SystemExit("缺少：%s" % job["apk"])
    work = ROOT / "build/tmp/messenger_payload"
    work.mkdir(parents=True, exist_ok=True)
    for job in JOBS:
        build(job, work)
    print("\n[done] 两包已覆盖（回退：python %s --restore）" % Path(__file__).name)
    print("       注意：fix_prepare_msg.py 已废弃，不要再单独执行/回退。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
