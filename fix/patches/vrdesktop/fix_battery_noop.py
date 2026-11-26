#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 VRDeviceNodeMonitor.processBattery() 的两个低电量分支 no-op 化。

用法：
    python3 fix_battery_noop.py <smali_dir>

背景（2026-11-08，见 fix/2026-11-08-眼镜黑屏排查分析.md 第二章）：
  R1 补丁让 mDeviceNodeMonitor 真正跑起来之后，本机 BATTERY 通道走
  Broken pipe 恒读 0，于是 processBattery(0) 每次都命中 below-5 分支，
  发 0x12 给 mHandler -> VRService.handleGlassShutdown() -> 发
  0x3ef(1007) 给客户端 -> launcher 放弃 VR 准备流程，眼镜黑屏。

  below-20（0x11 低电量弹窗）同样基于这个假 0 值，一并封掉。
  真实电量上报走 vcom BATTERY 帧，但本机 MCU 通道不可用，本来就没有
  真实电量可读，封掉是安全的。

做法：只删「取 mHandler -> obtainMessage -> sendMessage」这段指令，
  保留 VrLog 日志行和 return-void，便于现场确认代码确实走到了。
  不引入新寄存器、不改方法签名、不改 .locals/.registers，smali 可直接回编。

幂等：已打过（方法体内没有 mHandler 引用）则跳过。
"""
import re
import sys
from pathlib import Path

REL = "com/huawei/vrservice/monitor/VRDeviceNodeMonitor.smali"
METHOD_START = ".method private processBattery(I)V"
METHOD_END = ".end method"
HANDLER_GET = re.compile(r"^\s*iget-object .*?->mHandler:Landroid/os/Handler;\s*$")
SEND = re.compile(
    r"^\s*invoke-virtual \{[^}]*\}, "
    r"Landroid/os/Handler;->sendMessage\(Landroid/os/Message;\)Z\s*$"
)
MARK = "# [hvr-compat] broken-pipe battery channel: notify suppressed, no-op"
NOOP_BLOCK = (
    "\n"
    f"    {MARK}\n"
    "\n"
)


def patch_method(body: str):
    """返回 (新方法体, 删除的分支数)。找不到目标结构时抛错。"""
    lines = body.splitlines(keepends=True)
    out = []
    i = 0
    removed = 0
    while i < len(lines):
        if not HANDLER_GET.match(lines[i]):
            out.append(lines[i])
            i += 1
            continue
        # 收集到 sendMessage 为止；中途遇到 return-void / 方法结束就放弃
        j = i + 1
        found = False
        while j < len(lines):
            if lines[j].strip() == "return-void" or lines[j].strip() == METHOD_END:
                break
            if SEND.match(lines[j]):
                found = True
                break
            j += 1
        if not found:
            raise SystemExit(
                "[FATAL] mHandler 块结构不符合预期（未找到 sendMessage），拒绝改动"
            )
        out.append(NOOP_BLOCK)
        removed += 1
        i = j + 1
    return "".join(out), removed


def main():
    smali_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    target = smali_dir / REL
    if not target.exists():
        raise SystemExit(f"[FATAL] 找不到 {target}")

    text = target.read_text(encoding="utf-8")
    start = text.find(METHOD_START)
    if start < 0:
        raise SystemExit("[FATAL] 找不到 processBattery(I)V")
    end = text.find(METHOD_END, start)
    if end < 0:
        raise SystemExit("[FATAL] processBattery 缺少 .end method")
    end += len(METHOD_END)

    body = text[start:end]
    if MARK in body:
        print("  已注入，跳过")
        return
    if "->mHandler:Landroid/os/Handler;" not in body:
        print("  方法体内已无 mHandler 引用（可能是其它版本补丁），跳过")
        return

    new_body, removed = patch_method(body)
    if removed != 2:
        raise SystemExit(
            f"[FATAL] 预期 no-op 化 2 个分支，实际 {removed} 个；拒绝改动"
        )
    target.write_text(text[:start] + new_body + text[end:], encoding="utf-8")
    print(f"  已 no-op 化 below-5 / below-20 两个分支（{removed} 处），保留日志与 return-void")


if __name__ == "__main__":
    main()
