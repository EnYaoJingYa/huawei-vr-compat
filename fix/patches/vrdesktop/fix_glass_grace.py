#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 VrPlatformCompat.hasGlassUsbIdentity() 补「USB 瞬态宽限」。

背景（2026-11-08 第四轮，见 fix/README.md 11.9）：
  设备上 launcherx 的 VrMonitor.isVRGlassDevExist() 走
  VrPlatformCompat.isVrGlassPresent(Context)，判据是
      usb = UsbManager.getDeviceList() 里有 12d1:1092 / 12d1:107e
      display = 有外置显示
      return usb && display
  眼镜 USB 会因 `usb usb1-port1: disabled by hub (EMI?)` 整条 hub 掉线
  重连 1~2 秒。窗口里 UsbManager 列表为空 -> usb=false -> 叠加
  isVRMode=false -> VrMonitor.checkVRMode() 凑够 2 个失败项 -> SDK 自杀
  -> 系统重新拉起桌面，用户看到「一打开 VR 桌面就闪退」。

修法：UsbManager 枚举不到眼镜时，回退到华为**原版**判据
  new File("/dev/hwvr1").exists()
  —— 这个节点由 hvrglass 守护维护，EMI 窗口里守护会用占位普通文件
  顶住它（service.sh 的 MISS 宽限），真拔出时才删除。于是
      EMI 窗口：usb 列表空，但节点在 -> true -> 桌面不自杀
      真拔出  ：节点被删，且外置显示也消失 -> false -> 正常退出
  与 VrPlatformCompat 源码头注释里描述的原版行为一致。

用法：
    python fix_glass_grace.py <smali_dir>          # 幂等 patch smali
由 apply_glass_grace.sh 调用；只改 classes4.dex 里这一个方法。
"""
import sys
from pathlib import Path

REL = "com/huawei/vrframework/compat/VrPlatformCompat.smali"
METHOD = ".method public static hasGlassUsbIdentity(Landroid/content/Context;)Z"
GRACE_NODE = "/dev/hwvr1"
MARKER = "glass-grace fallback"


def patch_smali(root):
    f = Path(root) / REL
    if not f.is_file():
        raise SystemExit(f"[FATAL] 找不到 {f}")
    text = f.read_text(encoding="utf-8").replace("\r\n", "\n")
    if MARKER in text:
        print("[=] 已打过 glass-grace 补丁，跳过（幂等）")
        return

    start = text.index(METHOD)
    end = text.index(".end method", start) + len(".end method")
    body = text[start:end]

    # context == null / UsbManager == null 的早退也统一走回退判据
    for cond, line in ((":cond_4", "84"), (":cond_10", "89")):
        old = f"    if-nez p0, {cond}\n\n    .line {line}\n    return v0\n"
        if old not in body:
            raise SystemExit(f"[FATAL] 找不到早退分支 {cond}（smali 版本不匹配）")
        body = body.replace(
            old,
            f"    if-nez p0, {cond}\n\n    .line {line}\n    goto :goto_5d\n",
        )

    tail = "    :goto_5d\n    return v0"
    if tail not in body:
        raise SystemExit("[FATAL] 找不到 :goto_5d 尾部（smali 版本不匹配）")

    fallback = f"""    :goto_5d
    # {MARKER}: UsbManager 枚举为空时回退华为原版节点判据（EMI 瞬态宽限）
    new-instance v0, Ljava/io/File;

    const-string v1, "{GRACE_NODE}"

    invoke-direct {{v0, v1}}, Ljava/io/File;-><init>(Ljava/lang/String;)V

    invoke-virtual {{v0}}, Ljava/io/File;->exists()Z

    move-result v0

    return v0"""
    body = body.replace(tail, fallback)

    f.write_text(text[:start] + body + text[end:], encoding="utf-8")
    print(f"[+] 已 patch {f}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("用法: python fix_glass_grace.py <smali_dir>")
    patch_smali(sys.argv[1])
