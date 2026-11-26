# 线缆固件 OTA：能不能「骗」服务器拉最新包

> 结论写在最前面：**协议层面可以骗，而且没有任何门槛；但服务端已经不给东西了。**
> 骗到手的是 `{"status":"1"}` —— 服务端在说「你已是最新」，不是「你不配」。
>
> 实测时间：2026-11-01　设备：P30 (ELE-AL00 / EMUI 11.0.0.155)，vrhandle v12.0.0.302

---

## 一、先把问题拆开

「骗服务器拉固件」需要同时成立三件事，任何一环断了都不成：

| 环节 | 要什么 | 现状 |
|---|---|---|
| ① 请求能伪造 | 无签名 / 无鉴权 / 无设备绑定 | ✅ 完全裸奔，全字段可改 |
| ② 服务端有货 | 该 Devicename 下有比本机新的包 | ❌ 实测一律返回「无更新」 |
| ③ 拿到了能刷进去 | 有 VLI 刷写通道 | ✅ 代码完整（但没 bin） |

所以答案是：**① 成立，③ 成立，卡在 ②**。这不是「骗不过校验」，是**对面货架空了**。

---

## 二、① 请求确实能伪造：它就是一段裸 JSON

### 端点

反编译 `c1/q1.smali`，base 由 GRS 解析（`grs_sdk_global_route_config.json` 里 `VersionCheckCommercial = https://query.dbankcloud.cn`），路径硬编码：

```
POST https://query.dbankcloud.cn/vr/v2/CheckEx.action?ruleAttr=true&lastest=true
Content-Type: application/json; charset=utf8
```

另有一个测试环境副本（`res/values/strings.xml`）：
`https://query.hwcloudtest.cn/vr/v2/CheckEx.action?...` —— 公网 443 直连超时，只在华为内网可达。

### 请求体（`c1/q1.y()` 逐字段还原）

```json
{
  "components": [{
    "Devicename":         "C-CV10-Cable-C2C01",
    "Firmware":           "52",
    "PackageName":        "com.huawei.vrhandle.c2c.firmware.6",
    "PackageVersionName": "52",
    "PackageVersionCode": "52",
    "IMEI":               ""
  }]
}
```

**没有任何 `X-HW-*` 签名头、没有 token、没有 appId、没有证书 pinning。** 连 IMEI 都可以留空 —— `e1/d0.J()` 根本没给 bean 的 IMEI 字段赋值。

### 字段真实取值（`e1/d0.smali`）

| 字段 | 来源 | 实际值 |
|---|---|---|
| `Devicename` | 硬编码 `const-string` | `C-CV10-Cable-C2C01` |
| `PackageName` | 硬编码 | `com.huawei.vrhandle.c2c.firmware.6` |
| `Firmware` / `...Name` / `...Code` | `m1/d.c()` | 版本号第 3 段 |

`m1/d.c()` 的逻辑（`CableDataUtils.getVersionNameHex`）：把 `c.9.52.6` 按 `.` 切开，**取 index 2** → `"52"`。

> 这一点很关键：Firmware 不是 `c.9.52.6`，是裸的 `52`。传错格式服务端一样认不出。

### 响应语义（`c1/s1.smali` + `e1/d0.smali`）

| status | 分支 | 动作 |
|---|---|---|
| `0` | `g.d(bean)` → `d0.w()` | handler 发 0xd2，带 `components`（url/size/version）→ 弹升级 |
| `1` | `g.f()` → `d0.C()` | 清状态收尾，`PAGE_VERSION_NEWEST` = 已是最新 |
| 其它 | `g.a()` | 失败 |

---

## 三、② 服务端没货：五组版本全打回来

`tools/cable-ota-check.py` 原样复刻这个请求，逐版本扫：

```
Firmware=0   => {"status":"1"}
Firmware=1   => {"status":"1"}
Firmware=47  => {"status":"1"}
Firmware=51  => {"status":"1"}
Firmware=52  => {"status":"1"}
Firmware=99  => {"status":"1"}
```

**连 `Firmware=0` 都说「已是最新」**，且 `components` 字段直接不存在。

换 Devicename 也不行：

```
Devicename=HUAWEI CF20 / PackageName=com.huawei.vrhandle.cf20.firmware  => {"status":"1"}
Devicename=C-CV10-Cable-C2C01 + 真 IMEI                                => {"status":"1"}
```

### 手机自己也这么说

抓 logcat 时你正好停在线缆升级页：

```
mResumedActivity: com.huawei.vrhandle/.otaupgrade.cableupgrade.ui.cable.CableActivity

vrhandle_C2C_CableData: getVersionNameHex enter: c 9 52 6
vrhandle_C2C_CableData: getVersionNameHex final : c.9.52.6
vrhandle_C2C_CableUsbUtils: Usb connected all device, find vid pid matched
vrhandle_C2C_CableUiPageManager: automatic check current page : PAGE_VERSION_NEWEST
vrhandle_C2C_CableDetailUiPanels: DETAILED_LOCAL_LATEST
vrhandle_C2C_CableDetailUiPanels: showLocalAlreadyLatest
```

`find vid pid matched` 说明 `2109:0105` 被正确识别为线缆；App 读到的固件是 **`c.9.52.6`**，UI 判定 `LOCAL_LATEST`。

### 为什么是空的

VR Glass 产品线 2021 年停产，配套的配件 OTA 已经不再发版。这个端点还活着（HTTP 200），但只是回一个固定 `status=1` 的空壳。

**所以「骗」这条路的天花板是：你能拿到的最多是一句「已是最新」。**

---

## 四、③ 就算弄到 bin，刷写链路是通的（留个底）

如果哪天从别的渠道搞到固件包，手机侧确实具备刷写能力 —— 逻辑全在 `m1/o.smali`（`CableUpgradingUtils`）。

### 通道

```java
UsbDeviceConnection.controlTransfer(0xC0, 0xE0, wValue, wIndex, buf, len, 1000)
//                              bmRequestType=IN|Vendor|Device, bRequest=0xE0 (VLI 私有命令)
```

### 关键命令

| 动作 | 命令 / 方法 |
|---|---|
| 读线缆类型 | `n()` → `C(conn, 0xF7, buf[8])`；`buf[0] & 0x80` 为 0 返 2，否则返 3 |
| 读固件版本 | `k()` → `{0x80,0xE2,0x01,0,0,4,0,0}` |
| 读能力位 | `o()` → 返 0 时打印 `"firmware above 47, but the cable is not support connecting two side"` |
| 进 ROM | `jumpToRom()` |
| SPI 擦写 | `spiWriteEnable` → `spiEraseAllProcess` → `spiWriteStatus` → `spi_Write_Data` → `spi_Read_Data` 校验 |
| 重启 | `restartFirmware()` |

错误码对应关系也已反编译出来：11 找不到设备 / 12 找不到连接 / 13 打不开固件 / 21 清寄存器 / 22 擦除超时 / 23 擦除 / 31 写 / 32 读 / 33 校验。

**只有一个前提没满足：APK 里没有任何 `.bin`。** 863 个条目全查过，固件只能从服务端来。

---

## 五、真正卡住的不是固件，是下游枚举

刚才 `dumpsys usb`（只插线缆、没接眼镜和 6DoF）只有**一个**设备：

```
name=/dev/bus/usb/002/008
vendor_id=8457      (0x2109  VIA Labs)
product_id=261      (0x0105)
class=17            (0x11 Billboard Device Class)
product_name=USB 2.0 BILLBOARD
serial_number=0000000000000001
interfaces: 1 个, class=17
num_connects=139    ← 反复重枚举 139 次
```

三个反常点：

1. **`class=17 Billboard`** —— 这是 Type-C Alt Mode 协商出问题时才上报的「错误通知设备」。正常 hub 应该是 `class=9`。
2. **只有 1 个接口，`class=17`** —— 没有 `class=9`(hub)、没有 `class=14`(video)，说明 hub 的下游根本没被枚举。
3. **`num_connects=139`** —— 总线在反复重连，链路不稳。

而日志里**没有**出现 `firmware above 47 ... not support connecting two side`，说明 `o()` 返回非 0，即 hub 能力位认为「**支持双挂**」。

> 也就是说：线缆这边（固件 `c.9.52.6`，第 3 段 `52` > 47，能力位正常）没有拒你，
> 是**下游设备压根没被枚举出来** —— 之前看到的 `12d1:3a09` 只有一个 `class=14 subclass=1`、缺 `VideoStreaming`，同源。

---

## 六、下一步怎么办

按性价比排序：

1. **先排除物理层**（最便宜）
   拔插线缆两端、换一根确认支持双挂的线、确认 6DoF 模组是插在线缆下游口而不是手机直连。
   如果 `dumpsys usb` 里始终只有 `2109:0105 BILLBOARD` 而没有 `12d1:3a09` + `12d1:1092` 同时出现，那就是线缆/接口问题，跟固件无关。

2. **量一次 USB 拓扑**（判断是否带宽问题）
   接全三件，跑：
   ```sh
   adb shell dumpsys usb | grep -E "name=/dev|vendor_id|product_id|class=|product_name"
   ```
   看 `12d1:3a09` 下有几个 interface、`bNumEndpoints` 多少、`bAlternateSetting` 有几个。

3. **放弃 OTA 幻想**
   服务端已退役，`tools/cable-ota-check.py` 可以把「没好包」这件事随时复验一遍，不用再猜。

4. **如果确认是 DP Alt Mode 抢走了 USB3 通道**
   那才是「升级鸿蒙 2 就好」的真正原因（鸿蒙 2 的显示栈对 DP 通道数 / USB 带宽的分配策略不同），
   和线缆固件无关 —— 因为固件已经是 52，且服务端没有 53。

---

## 附：复现命令

```sh
# 一次扫全部版本
python tools/cable-ota-check.py --sweep

# 单次查询，指定版本
python tools/cable-ota-check.py --firmware 0

# 查眼镜/手柄固件
python tools/cable-ota-check.py --devicename "HUAWEI CF20" \
    --package com.huawei.vrhandle.cf20.firmware --firmware 0
```

裸 curl 版本：

```sh
curl -sS -m 15 -X POST \
  "https://query.dbankcloud.cn/vr/v2/CheckEx.action?ruleAttr=true&lastest=true" \
  -H "Content-Type: application/json; charset=utf8" \
  --data '{"components":[{"Devicename":"C-CV10-Cable-C2C01","Firmware":"0","PackageName":"com.huawei.vrhandle.c2c.firmware.6","PackageVersionName":"0","PackageVersionCode":"0","IMEI":""}]}'
# => {"status":"1"}
```
