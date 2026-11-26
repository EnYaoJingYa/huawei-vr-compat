# 基线（未改动的原包）

| 包名 | 文件 | 字节 | sha256 |
|---|---|---|---|
| com.huawei.appmarket.vr | com.huawei.appmarket.vr.apk | 69766327 | 0B67AEA288B8ACA30388B2D2931D2B08172275159732DA84258B51F59B2250D6 |
| com.huawei.himovie.vr | com.huawei.himovie.vr.apk | 116811077 | D34ADA2B296794F6BDD89E1426577AD42CB99A6AEE17758565AD10F5918CE5EA |
| com.huawei.hvrsdkserverapp | com.huawei.hvrsdkserverapp.apk | 66871844 | E0AF366239D1C9C8AD384651A3173DFDFCCAC9BA221768F4DB6C5349101D1444 |
| com.huawei.vrhandle | com.huawei.vrhandle.apk | 8963026 | E947FC358E9692358AC42CFE4A565C112F7FC9349DA693643F863D08AF98B3D2 |
| com.huawei.vrlauncherx | com.huawei.vrlauncherx.apk | 59024225 | 1E91F00D596C636C3F52DDDC494EE6B745CDF90BB3A0838FF203F9AE54B92DD3 |
| com.huawei.vrvirtualscreen | com.huawei.vrvirtualscreen.apk | 14786134 | 229EBA319B78A94DD5B497C1AADD739DB07189FA5B8C4680473529350D70C7FE |
| com.huawei.vrservice | com.huawei.vrservice.apk | 5298141 | FD363DBEA8F8413E5DE0B984E3151432E27FC788E579B72EC542A2A48F02882D |

解码命令：`java -jar tools/apktool_2.10.0.jar d -f -p tools/framework -o decode/<包名> 原包/<包名>.apk`

`com.huawei.vrservice` 是第七个模块：用户手上的六个包里没有它，是从
HMA-AL00 EMUI 11.0.0.155 整包固件的 `hw_product` 分区里提取出来的
（`/region_comm/china/app/VRServiceX/VRServiceX.apk`），提取过程与镜像结构见
`docs/FIRMWARE_HMA11_EMUI11.md`。

> **版本更正（2026-11-26）**：早期文档把本包标为 `11.0.0.322` / 3,042,010 B /
> sha256 `317C0995…`，那是**最初从固件中提取时**的记录。当前 `原包/com.huawei.vrservice.apk`
> 实际是 **12.0.0.302**（DEX 内 `versionName` 字符串实测），5,298,141 B，
> sha256 `FD363DBE…`。用户 2026-11-26 提供的「华为 VR 服务_12.0.0.302.zip」解出的 APK
> 与本仓库内文件**逐字节相同**（同一 sha256），因此不需要替换；本表与下方哈希已按实际
> 文件更新。`docs/FIRMWARE_HMA11_EMUI11.md`、`docs/PATCH_AUDIT.md` 第 20 节、
> `docs/RK3566-部署记录.md`、`vr/README.md` 中的 `11.0.0.322` 是历史记录，
> 指提取当时的版本，请以此处为准。

## 解码方式与偏差

| 包名 | 工具 | 方式 | 说明 |
|---|---|---|---|
| `com.huawei.appmarket.vr` | apktool 2.10.0 | 全量 | 正常 |
| `com.huawei.vrlauncherx` | apktool 2.10.0 | 全量 | 正常 |
| `com.huawei.himovie.vr` | apktool 2.10.0 | 全量 | 正常 |
| `com.huawei.vrvirtualscreen` | apktool 2.10.0 | 全量 | 正常 |
| `com.huawei.vrhandle` | apktool 2.10.0 | 全量 | 正常 |
| `com.huawei.hvrsdkserverapp` | apktool 2.10.0 | `-r`（保留原始资源表与二进制 manifest） | 该包资源表内 `string/Hvr_wifi`(0x7f070009) 重复，apktool 2.10.0 全量解码报 `Multiple resources`，apktool 2.4.0 报 `Invalid chunk type`；两者都无法全量解。 |
| `com.huawei.vrservice` | apktool 2.10.0 | `-r`（保留原始资源表与二进制 manifest） | 同样是资源表内重复项（`string/download_first_set_wifi_network`，0x7f09000a）导致全量解码报 `Multiple resources`。manifest 改动由 `patches/patch_vrservice_manifest.py` 直接在二进制上做。 |

`com.huawei.hvrsdkserverapp` 的处理依据：

- 它的权限只有 `com.huawei.permission.sec.MDM.v2`、`android.permission.FOREGROUND_SERVICE`、
  `com.huawei.hvrsdkserverapp.permission.LOCAL_PERMISSION`，**没有 INTERNET**，
  本轮不需要改它的 manifest；
- 用 `-r` 解出的树能原样构建回去（已实测：`apktool b` 产出 63.8 MB APK）；
- 因此该包只做 smali/dex 层面的系统层替换，资源与二进制 manifest 原样保留。
