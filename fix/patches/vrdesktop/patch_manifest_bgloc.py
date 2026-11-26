#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 apktool 反编译出的 AndroidManifest.xml 里插入 ACCESS_BACKGROUND_LOCATION 声明。

背景（2026-11-07 实测）：vrhandle targetSdk=31 跑在 Android 11 上，
「仅在使用期间允许」的定位授权拦掉后台 Service 的 BLE 扫描结果：
    E BluetoothUtils: Permission denial: Need ACCESS_FINE_LOCATION ...
且 UID 级 appops COARSE_LOCATION 恒为 foreground，set/reset 改不掉。
唯一纯后台解法：Manifest 声明 ACCESS_BACKGROUND_LOCATION 后用 root
pm grant 授「始终允许」，后台扫描即放行。原包没声明这条权限，
pm grant 直接 SecurityException，所以必须打 Manifest。

用法:
    python patch_manifest_bgloc.py <apktool解码目录>
"""
import re
import sys
from pathlib import Path


def main():
    p = Path(sys.argv[1]) / "AndroidManifest.xml"
    s = p.read_text(encoding="utf-8")
    if "ACCESS_BACKGROUND_LOCATION" in s:
        print("[OK] 已含 ACCESS_BACKGROUND_LOCATION，跳过")
        return
    m = re.search(
        r"[ \t]*<uses-permission [^>]*android\.permission\.ACCESS_FINE_LOCATION"
        r"[^>]*/>[ \t]*\r?\n", s)
    assert m, "找不到 ACCESS_FINE_LOCATION 的 uses-permission 行"
    line = m.group(0)
    indent = re.match(r"[ \t]*", line).group(0)
    nl = "\r\n" if "\r\n" in line else "\n"
    new = line + (indent
                  + '<uses-permission android:name='
                    '"android.permission.ACCESS_BACKGROUND_LOCATION"/>'
                  + nl)
    s = s[:m.start()] + new + s[m.end():]
    assert "ACCESS_BACKGROUND_LOCATION" in s
    p.write_text(s, encoding="utf-8", newline="")
    print(f"[OK] 已插入 ACCESS_BACKGROUND_LOCATION: {p}")


if __name__ == "__main__":
    main()
