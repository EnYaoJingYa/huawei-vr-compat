#!/usr/bin/env python3
"""把 AutoScanCompat 注入 baksmali 反编译出来的 vrhandle smali 目录。

用法：
    python3 inject_autoscan.py <smali_dir> <AutoScanCompat.smali>

做两件事（幂等，可反复执行）：
  1. 把 AutoScanCompat.smali 复制成
     <smali_dir>/com/huawei/vrhandle/AutoScanCompat.smali
  2. 在 VRHandleService.smali 里插入 kick 调用：
       - onCreate()V       -> 最后一个 return-void 之前（冷启动立即扫）
       - onStartCommand(..) -> .registers/.locals 之后（每次 RECONNECT 心跳）
         配合 AutoScanCompat 内部的 60 秒节流，避免重复启动扫描。
  3. 在 VRHandleService$d.a(BluetoothDevice)（扫描回调）里插入
     onDeviceFound 调用：纯后台复刻「配对页点击连接」+ 入库持久化。

只做文本插入，不改任何寄存器数量：kick / onDeviceFound 都是 static
方法，参数（Service 实例 / 扫到的 BluetoothDevice）在调用点本来就有，
try/catch 全在 AutoScanCompat 内部。
"""
import shutil
import sys
from pathlib import Path

CALL = ("    invoke-static {p0}, "
        "Lcom/huawei/vrhandle/AutoScanCompat;"
        "->kick(Lcom/huawei/vrhandle/service/VRHandleService;)V\n")
MARK = "AutoScanCompat;->kick"
CALL_FOUND = ("    invoke-static {p1}, "
              "Lcom/huawei/vrhandle/AutoScanCompat;"
              "->onDeviceFound(Landroid/bluetooth/BluetoothDevice;)V\n")
MARK_FOUND = "AutoScanCompat;->onDeviceFound"


def method_span(lines, prefix):
    """返回 (start, end) 行索引，end 为 .end method 所在行。"""
    start = next((i for i, l in enumerate(lines)
                  if l.startswith(prefix)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith(".end method")), None)
    if end is None:
        raise SystemExit(f"[FATAL] {prefix} 找不到 .end method")
    return start, end


def inject_once(lines, prefix, mode, call=CALL, mark=MARK):
    span = method_span(lines, prefix)
    if span is None:
        raise SystemExit(f"[FATAL] 找不到方法 {prefix}")
    start, end = span
    if any(mark in l for l in lines[start:end]):
        print(f"  {prefix}: 已注入，跳过")
        return lines, False

    if mode == "before_last_return":
        rets = [i for i in range(start, end)
                if lines[i].strip() == "return-void"]
        if not rets:
            raise SystemExit(f"[FATAL] {prefix} 里没有 return-void")
        at = rets[-1]
        lines.insert(at, "\n" + call)
    else:  # after_registers
        reg = next((i for i in range(start, end)
                    if lines[i].strip().startswith((".registers", ".locals"))),
                   None)
        if reg is None:
            raise SystemExit(f"[FATAL] {prefix} 里没有 .registers/.locals")
        at = reg + 1
        lines.insert(at, "\n" + call)
    print(f"  {prefix}: 已插入 @ 行 {at + 1}")
    return lines, True


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    smali_dir = Path(sys.argv[1])
    src_compat = Path(sys.argv[2])
    if not smali_dir.is_dir():
        raise SystemExit(f"[FATAL] smali 目录不存在：{smali_dir}")
    if not src_compat.is_file():
        raise SystemExit(f"[FATAL] AutoScanCompat.smali 不存在：{src_compat}")

    dst_compat = smali_dir / "com/huawei/vrhandle/AutoScanCompat.smali"
    dst_compat.parent.mkdir(parents=True, exist_ok=True)
    if dst_compat.exists() and dst_compat.read_bytes() == src_compat.read_bytes():
        print("  AutoScanCompat.smali: 已存在且一致")
    else:
        shutil.copyfile(src_compat, dst_compat)
        print("  AutoScanCompat.smali: 已复制")

    svc = smali_dir / "com/huawei/vrhandle/service/VRHandleService.smali"
    if not svc.is_file():
        raise SystemExit(f"[FATAL] 找不到 {svc}\n"
                         "（可能反编译错了 dex，应找含 VRHandleService 的那个）")
    lines = svc.read_text(encoding="utf-8").splitlines(True)
    lines, _ = inject_once(lines, ".method public onCreate()V",
                           "before_last_return")
    lines, _ = inject_once(lines, ".method public onStartCommand(",
                           "after_registers")
    svc.write_text("".join(lines), encoding="utf-8")

    total = sum(1 for l in lines if MARK in l)
    print(f"  VRHandleService 共 {total} 处 kick 调用（应为 2）")
    if total != 2:
        raise SystemExit("[FATAL] kick 调用数不为 2，拒绝继续")

    # 扫描回调 VRHandleService$d.a(BluetoothDevice)：p1 即扫到的设备
    dcb = (smali_dir
           / "com/huawei/vrhandle/service/VRHandleService$d.smali")
    if not dcb.is_file():
        raise SystemExit(f"[FATAL] 找不到 {dcb}")
    dlines = dcb.read_text(encoding="utf-8").splitlines(True)
    dlines, _ = inject_once(dlines, ".method public a(Landroid/bluetooth/BluetoothDevice;)V",
                            "after_registers", call=CALL_FOUND, mark=MARK_FOUND)
    dcb.write_text("".join(dlines), encoding="utf-8")
    found_n = sum(1 for l in dlines if MARK_FOUND in l)
    print(f"  VRHandleService$d 共 {found_n} 处 onDeviceFound 调用（应为 1）")
    if found_n != 1:
        raise SystemExit("[FATAL] onDeviceFound 调用数不为 1，拒绝继续")


if __name__ == "__main__":
    main()
