#!/usr/bin/env python3
"""在 VRService.smali 的 onCreate 里给 mDeviceNodeMonitor 补 start()。

用法：
    python3 inject_monitor_start.py <smali_dir>

背景（2026-11-08）：
  com.huawei.vrservice 的 VRService.onCreate 创建了 mDeviceNodeMonitor
  （读取 /dev/ttyUSB1 vcom 通道，解析 PROXIMITY/HEADSET/BATTERY 缓冲），
  但 onCreate 里不 start()。原厂在 startHelmetMonitor() 里会 start 两个
  monitor，而那条链依赖 isVRHelmetConnectJNI() 的 HID 初始化时序，本机
  不触发 -> 遮挡传感器事件全断，VR 桌面无法黑屏/亮屏。

  修法：onCreate 里 iput-object mDeviceNodeMonitor 之后补一句
      invoke-interface {v0}, Lcom/huawei/vrservice/monitor/VRMonitor;->start()V
  与 mBroadcastMonitor 同样待遇。start() 有 mMonitorStarted 幂等保护，
  startHelmetMonitor 再 start 一次无害。

幂等，可重复执行。只做文本插入，不改寄存器。
"""
import sys
from pathlib import Path

MARK = "VRMonitor;->start()V"
IPUT = ("iput-object v0, p0, Lcom/huawei/vrservice/VRService;"
        "->mDeviceNodeMonitor:Lcom/huawei/vrservice/monitor/VRMonitor;")
INSERT = """
    # 补丁：onCreate 直接启动节点监控，不等 startHelmetMonitor 的 HID 时序
    invoke-interface {v0}, Lcom/huawei/vrservice/monitor/VRMonitor;->start()V
"""


def main():
    smali_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    svc = smali_dir / "com/huawei/vrservice/VRService.smali"
    if not svc.exists():
        raise SystemExit(f"[FATAL] 找不到 {svc}")
    lines = svc.read_text(encoding="utf-8").splitlines(keepends=True)

    # 幂等检查：onCreate 里是否已有对 mDeviceNodeMonitor 附近的 start()
    idx = [i for i, l in enumerate(lines) if IPUT in l]
    if not idx:
        raise SystemExit("[FATAL] 找不到 mDeviceNodeMonitor 的 iput-object")
    at = idx[0]
    window = "".join(lines[at:at + 6])
    if MARK in window:
        print("  已注入，跳过")
        return
    lines.insert(at + 1, INSERT)
    svc.write_text("".join(lines), encoding="utf-8")
    print(f"  已在 iput 后插入 start() @ 行 {at + 2}")


if __name__ == "__main__":
    main()
