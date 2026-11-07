#!/usr/bin/env python3
"""给 launcherx 兼容层 HvrSdkBridge 补上「绑定 RuntimeService」这一步。

背景（2026-11-08 真机取证）
--------------------------
VrParamsRequester.bindRuntimeService() 是 6DoF 整条链的唯一入口：
它 bindService(ACTION_GET_INTERNAL_INTERFACE)，onServiceConnected 才会把
mRuntimeInterface 填上。而 isHW6DoFAvailable(index) 第一行就是

    if (mRuntimeInterface == null) return false;

所以只要没绑定，Huawei 6Dof Header / left / right 永远 false，
VrHelmetExt.isEnable() 拿不到 mVRDeviceExt，6DoF 设备永不上报。

全 SDK 里 registerReceivers() 没有任何调用点（死代码），而它内部
TemperatureReceiver.register() 才是 bindRuntimeService 的唯一调用者。
这就是现场 `bind RuntimeService : 0` 的由来。

为什么改 HvrSdkBridge 而不是 VrFrameworkBootstrap
------------------------------------------------
见 HvrSdkBridge.java 头部注释：LibUpdate 用 hvrframework.dex 建了 L4，
把 VrFramework 的 Class 对象交给 native SetClass；Bootstrap 另建了指向
base.apk 的 L3。Java 静态字段按「类对象」隔离，在 L3 上绑定不会影响
L4 那份 VrParamsRequester 单例。HvrSdkBridge.find() 拿到的正是 native
在用的那份 Class，用 type.getClassLoader() 加载 VrParamsRequester 才能
保证同一个单例。

补丁内容
--------
1) 新增 private static bindRuntime()，反射调用
   VrParamsRequester.getInstance().bindRuntimeService(activity)，全程
   捕获 Throwable，任何失败只记日志、不影响原有初始化。
2) 在 offer() 的 FRAMEWORK 分支里 applyFramework() 之后插一行调用。

为什么注入点是 offer() 而不是 setActivity() / applyFramework()
------------------------------------------------------------
真实时序（2026-11-08 tag 过滤抓取）：
  HVRActivity.onCreate -> setActivity(activity)          （此时 CLASSES 还是空的）
  ... LibUpdate 逐个 offer() ...
  offer[0] VrFramework -> CLASSES.put -> applyFramework() -> init OK
所以放在 setActivity 里会因 find(FRAMEWORK)==null 静默 return（实测无任何
HvrSdkBridge 绑定日志）；放在 applyFramework() 的 Log.i 之后则会触发
  VerifyError: [0x30] register v2 has type java.lang.reflect.Method
               but expected java.lang.String
（applyFramework 有 try/catchall，v2 先装 Method 后装 String，加指令就会让
dex verifier 在异常合并点拒绝整个类，getSystemService 直接崩）。
offer() 的这段位于 monitor-exit 之后，是直线代码，插入零风险，且此时
CLASSES 已放入 VrFramework、activity 也已设好 —— 正是绑定的时机。

幂等：已打过补丁则直接跳过。
"""
import sys
from pathlib import Path

CLASS_PATH = "com/huawei/vrframework/compat/HvrSdkBridge.smali"

OFFER_HEAD = ".method public static offer("
APPLY_CALL = (
    "    invoke-static {}, Lcom/huawei/vrframework/compat/HvrSdkBridge;->applyFramework()V\n"
)
BIND_CALL = (
    "    invoke-static {}, Lcom/huawei/vrframework/compat/HvrSdkBridge;->bindRuntime()V\n"
)

METHOD = r'''
.method private static bindRuntime()V
    .registers 9

    :try_start_0
    sget-object v0, Lcom/huawei/vrframework/compat/HvrSdkBridge;->activity:Landroid/app/Activity;

    if-nez v0, :cond_0

    return-void

    :cond_0
    const-string v1, "com.huawei.vrframework.VrFramework"

    invoke-static {v1}, Lcom/huawei/vrframework/compat/HvrSdkBridge;->find(Ljava/lang/String;)Ljava/lang/Class;

    move-result-object v1

    if-nez v1, :cond_1

    return-void

    :cond_1
    invoke-virtual {v1}, Ljava/lang/Class;->getClassLoader()Ljava/lang/ClassLoader;

    move-result-object v2

    const-string v1, "com.huawei.vrframework.VrParamsRequester"

    const/4 v3, 0x1

    invoke-static {v1, v3, v2}, Ljava/lang/Class;->forName(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;

    move-result-object v1

    # VrParamsRequester.getInstance()
    const-string v2, "getInstance"

    const/4 v3, 0x0

    new-array v4, v3, [Ljava/lang/Class;

    invoke-virtual {v1, v2, v4}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v2

    new-array v4, v3, [Ljava/lang/Object;

    const/4 v5, 0x0

    invoke-virtual {v2, v5, v4}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v2

    if-nez v2, :cond_2

    return-void

    :cond_2
    # bindRuntimeService(Context)
    const-string v5, "bindRuntimeService"

    const/4 v6, 0x1

    new-array v4, v6, [Ljava/lang/Class;

    const-class v6, Landroid/content/Context;

    aput-object v6, v4, v3

    invoke-virtual {v1, v5, v4}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v1

    const/4 v6, 0x1

    new-array v4, v6, [Ljava/lang/Object;

    aput-object v0, v4, v3

    invoke-virtual {v1, v2, v4}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    const-string v0, "HvrSdkBridge"

    const-string v1, "bindRuntimeService OK on SetClass copy"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    return-void

    :catch_0
    move-exception v0

    const-string v1, "HvrSdkBridge"

    const-string v2, "bindRuntimeService failed (6DoF stays unavailable)"

    invoke-static {v1, v2, v0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    return-void
.end method

'''


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: fix_runtime_bind.py <smali 目录>")
        return 2
    target = Path(sys.argv[1]) / CLASS_PATH
    if not target.is_file():
        print(f"[FAIL] 找不到 {target}")
        return 1
    text = target.read_text(encoding="utf-8")

    if ".method private static bindRuntime()V" in text:
        print("[SKIP] HvrSdkBridge 已有 bindRuntime()，补丁幂等跳过")
        return 0

    if OFFER_HEAD not in text:
        print("[FAIL] 找不到 offer 方法，拒绝盲改")
        return 1
    start = text.index(OFFER_HEAD)
    end = text.index(".end method", start)
    body = text[start:end]
    if body.count(APPLY_CALL) != 1:
        print(f"[FAIL] offer 内 applyFramework 调用出现 "
              f"{body.count(APPLY_CALL)} 次（期望 1），拒绝盲改")
        return 1
    body = body.replace(APPLY_CALL, APPLY_CALL + "\n" + BIND_CALL, 1)
    text = text[:start] + body + text[end:]

    marker = ".method private static declared-synchronized applyHelmet()V"
    if marker not in text:
        print("[FAIL] 找不到 applyHelmet 方法头，无法确定新方法插入位置")
        return 1
    text = text.replace(marker, METHOD.lstrip("\n") + marker, 1)

    target.write_text(text, encoding="utf-8")
    print("[OK] HvrSdkBridge.smali：offer 的 FRAMEWORK 分支追加 bindRuntime()，"
          "并新增反射绑定方法")
    return 0


if __name__ == "__main__":
    sys.exit(main())
