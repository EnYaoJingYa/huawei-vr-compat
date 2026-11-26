#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""恢复 HVRActivity.onCreate 里被历史补丁删掉的 LibUpdateClient.runUpdate()。

取证（2026-11-06）：
  设备 APK 的 classes.dex 里 HVRActivity.onCreate 尾部只剩
      invoke-static {p0}, ...VrFrameworkBootstrap->init(Activity)V
      return-void
  而 patches/patch_vrframework_bootstrap.py 的原始 ANCHOR 是
      invoke-virtual {p1}, Lcom/huawei/hvr/LibUpdateClient;->runUpdate()Z
  说明原厂这行被删了（decode 树注释「禁用 LibUpdate 动态注入」）。

  后果：LibUpdate.loadLibInFullApp() 里的 callParentSetClass() 从不执行，
  native 层 FrameworkClass 恒 null：
      HvrFramework.cpp:Init(1030) FrameworkClass is null
      Unity_HVRRenderMgrCore: CheckVRMode FAIL, SDK Quit -> System.exit
  VrFrameworkBootstrap 只能调 Java 的 init(Activity)，补不上 native 的类注册。

  真机（PATCH_AUDIT 第 16 节）成功日志证明这条链是通的：
      W LibUpdateCall: App is 32 bit
      I LibUpdateServer: Lib dir : .../lib/arm
      ... Load libXXX.so succeed ...
      I HvrFramework: SetClass HVR_*_CLASS_INDEX
      I VrHelmetExt: getInstanceObject
      I LibUpdateCall: Run update 2.0 succeed
  LibUpdate.smali 有 mIs64Bit 分支（arm64-v8a / armeabi-v7a），
  launcherx 的 Unity 是 armeabi-v7a，走的就是真机验证过的 32 位路径。

改法：在 bootstrap 调用之前插一次 runUpdate()（new + <init>(Context) + runUpdate()Z），
用 try/catch 包住 Throwable —— LibUpdate 失败也不能让 Activity 崩溃，
bootstrap 照常执行。只改这一个方法的尾部，其余不动。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TARGET = ROOT / "build/tmp/ctxa/dexdump/smali1/com/huawei/vrlab/HVRActivity.smali"

OLD = """    .line 5
    :cond_23
    invoke-static {p0}, Lcom/huawei/vrframework/compat/VrFrameworkBootstrap;->init(Landroid/app/Activity;)V

    return-void
.end method
"""

NEW = """    .line 5
    :cond_23
    :try_start_libupd
    new-instance v2, Lcom/huawei/hvr/LibUpdateClient;

    invoke-direct {v2, p0}, Lcom/huawei/hvr/LibUpdateClient;-><init>(Landroid/content/Context;)V

    invoke-virtual {v2}, Lcom/huawei/hvr/LibUpdateClient;->runUpdate()Z

    :try_end_libupd
    .catch Ljava/lang/Throwable; {:try_start_libupd .. :try_end_libupd} :catch_libupd

    goto :goto_libupd

    :catch_libupd
    move-exception v2

    :goto_libupd
    invoke-static {p0}, Lcom/huawei/vrframework/compat/VrFrameworkBootstrap;->init(Landroid/app/Activity;)V

    return-void
.end method
"""


def main():
    text = TARGET.read_text(encoding="utf-8")
    if "runUpdate()Z" in text:
        raise SystemExit("已恢复过 runUpdate，勿重复执行")
    if text.count(OLD) != 1:
        raise SystemExit("锚点不唯一或不存在：count=%d" % text.count(OLD))
    TARGET.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print("patched: %s" % TARGET)
    print("  插入 new LibUpdateClient / <init>(Context) / runUpdate()Z（try-catch 保护）")


if __name__ == "__main__":
    main()
