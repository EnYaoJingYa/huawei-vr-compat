#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cable-ota-check.py —— 复刻 vrhandle 的线缆固件版本查询（HOTA CheckEx）

用途
----
vrhandle 的 CableVersionCheckManager 会向华为 HOTA 服务发一个**完全匿名**的
POST 请求，用 (Devicename, Firmware, PackageName) 三元组换取最新固件包的
下载地址。本脚本按反编译结果原样复刻该请求，用于：

  1. 观察服务端对任意固件版本会返回什么（验证"能不能骗"）
  2. 抓取服务端可能下发的 url / size / version

反编译依据
----------
  c1/q1.smali  C()  -> base + "/vr/v2/CheckEx.action?ruleAttr=true&lastest=true"
  c1/q1.smali  y()  -> 请求体只有 6 个字段
  e1/d0.smali  J()  -> 字段取值来源
  m1/d.smali   c()  -> Firmware 实际是版本号第 3 段，如 "c.9.52.6" -> "52"

实测结论（2026-11）
------------------
  服务端对该端点一律返回 {"status":"1"}（= 无可用更新），不返回 components。
  status 语义：0 = 有新版本（走 d() 分支，带 components）
               1 = 已是最新（走 f() 分支 -> C() 收尾）
               其它 = 查询失败（走 a() 分支）

用法
----
  python tools/cable-ota-check.py                      # 默认：线缆 C2C01，Firmware=52
  python tools/cable-ota-check.py --firmware 0         # 伪造极旧版本
  python tools/cable-ota-check.py --devicename "HUAWEI CF20" \
      --package com.huawei.vrhandle.cf20.firmware      # 查眼镜/手柄固件
  python tools/cable-ota-check.py --host query.dbankcloud.com
"""

import argparse
import json
import ssl
import sys
import urllib.request

DEFAULT_HOST = "query.dbankcloud.cn"
DEFAULT_PATH = "/vr/v2/CheckEx.action?ruleAttr=true&lastest=true"
DEFAULT_DEVICE = "C-CV10-Cable-C2C01"
DEFAULT_PACKAGE = "com.huawei.vrhandle.c2c.firmware.6"
DEFAULT_FIRMWARE = "52"

STATUS_MEANING = {
    "0": "有新版本（服务端会带 components[url/size/version]）",
    "1": "已是最高版本 / 无可用更新",
    "-1": "查询失败（请求为 null）",
}


def build_body(devicename: str, firmware: str, package: str) -> dict:
    """严格按 c1/q1.y() 的字段顺序与命名构造请求体。"""
    return {
        "components": [
            {
                "Devicename": devicename,
                "Firmware": firmware,
                "PackageName": package,
                "PackageVersionName": firmware,
                "PackageVersionCode": firmware,
                "IMEI": "",  # 反编译显示该字段允许为空，服务端不校验
            }
        ]
    }


def post(host: str, body: dict, timeout: int = 20) -> tuple:
    url = f"https://{host}{DEFAULT_PATH}"
    data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json; charset=utf8",
            "Connection": "keep-alive",
            "Accept-Encoding": "identity",
        },
    )
    # 反编译里没有任何证书 pinning，用默认上下文即可
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        return None, f"<请求失败: {exc}>"


def parse(resp_text: str) -> dict:
    """按 c1/q1.z() 解析：status 顶层，components[] 里是 size/url/version 等。"""
    try:
        obj = json.loads(resp_text)
    except Exception:  # noqa: BLE001
        return {"_raw": resp_text, "_error": "非 JSON"}
    out = {"status": obj.get("status"), "components": obj.get("components") or []}
    for comp in out["components"]:
        for key in ("name", "version", "versionID", "url", "size", "description"):
            if key in comp:
                out.setdefault("_fields", {})[key] = comp[key]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="复刻 vrhandle 线缆固件 OTA 查询")
    ap.add_argument("--host", default=DEFAULT_HOST, help=f"默认 {DEFAULT_HOST}")
    ap.add_argument("--devicename", default=DEFAULT_DEVICE)
    ap.add_argument("--package", dest="pkg", default=DEFAULT_PACKAGE)
    ap.add_argument("--firmware", default=DEFAULT_FIRMWARE,
                    help="固件版本；线缆取 c.9.52.6 的第 3 段，即 52")
    ap.add_argument("--sweep", action="store_true",
                    help="依次试 0/1/47/51/52/99，看服务端是否随版本变化")
    args = ap.parse_args()

    print(f"[*] endpoint : https://{args.host}{DEFAULT_PATH}")
    print(f"[*] Devicename={args.devicename}  PackageName={args.pkg}")

    versions = ["0", "1", "47", "51", "52", "99"] if args.sweep else [args.firmware]

    for fw in versions:
        body = build_body(args.devicename, fw, args.pkg)
        print(f"\n[>] Firmware={fw}")
        print(f"    body: {json.dumps(body, ensure_ascii=False)}")
        code, text = post(args.host, body)
        if code is None:
            print(f"    {text}")
            continue
        print(f"    HTTP {code}  raw: {text}")
        info = parse(text)
        status = str(info.get("status"))
        print(f"    status={status}  -> {STATUS_MEANING.get(status, '未知')}")
        if info.get("components"):
            for comp in info["components"]:
                print(f"    [!] 发现固件: {json.dumps(comp, ensure_ascii=False)}")
        else:
            print("    components 缺失 -> 服务端没有下发任何包")

    print("\n[结论] 若所有版本都返回 status=1 且无 components，"
          "说明服务端对该设备已无发布内容，第 1 步走不通。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
