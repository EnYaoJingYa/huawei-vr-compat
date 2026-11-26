# ELE-AL00 固件解包分析（HarmonyOS 2.0.0.171）

> 目录：`系统/`　｜　分析日期：2026-11-01

## 一、结论速览

| 项 | 结果 |
|---|---|
| 机型 | ELE-AL00（P30，`ELE-LGRP1-CHN`） |
| 系统 | **HarmonyOS 2.0.0.171**（构建号 `System 102.0.0.51`，OHOS API 5） |
| 版本 | 升级前基线 base **10.1.0.182**　cust **10.1.0(C00) / 10.1.0.162(C00E160R2P11)**　preload **R3** |
| Android 兼容层 | 10（SDK 29），`ro.build.version.emui=EmotionUI_11.1.0`，构建时间 2021-09-23 |
| 分区布局 | 动态分区（super / LP metadata），`system` `hw_product` 为 EROFS |
| 本包真正有数据的 | **只有 system + hw_product**（cust / vendor / odm 在 super 内是空区） |
| VR 相关 | 有框架与 HAL，但**没有** `vr.jar` 实体实现、没有 `vrvirtualscreen` |
| 关键收获 | `hw_product/region_comm/china/app/VRServiceX/VRServiceX.apk` = **com.huawei.vrservice v11.1.0.320** |

## 一附、这确实是鸿蒙 2.0（版本判定依据）

镜像里 `ro.build.version.release=10`、`ro.build.version.emui=EmotionUI_11.1.0` 只是
**兼容层**（鸿蒙 2 为跑安卓应用保留的谎报值），真正的系统标识在下面几处，全部指向
HarmonyOS 2.0：

| 证据 | 值 | 出处 |
|---|---|---|
| 鸿蒙平台版本 | `hw_sc.build.platform.version=2.0.0` | `system/emui/base/prop/local.prop:34` |
| 鸿蒙 OS 版本 | `hw_sc.build.os.version=2.1.0`　`hw_sc.build.os.apiversion=5` | `system/build.prop` |
| 产品基础版本 | `ro.comp.hl.product_base_version=ELE-LGRP1-CHN 2.0.0.171` | `hw_product/etc/prop/local.prop:395` |
| 产品版本（内部） | `ro.comp.product_version=Product-ELE 102.0.0(0000)` | 同上 |
| 构建号 | `ro.build.display.id=System 102.0.0.51(2SD2)` | `system/build.prop` |
| 组件版本串 | `System 102.0.0.51(X.21042101.ALL.B100RLS.051.21092301.GENERIC_A15_CHINA_FULL_DPI480_EXT4)` | `system/etc/component_version.txt` |
| `ro.build.description` | `ELE-AL00-user 102.0.0 HUAWEIELE-AL00 171-CHN-LGRP1 release-keys` | `hw_product/hw_oem/ELE-AL00/prop/local.prop` |
| 鸿蒙安全补丁页 | `https://device.harmonyos.com/...` | `system/emui/base/xml/hw_hmos_security_patch_url.xml` |

结构层面的鸿蒙特征（EMUI 是拿不出这些的）：

- `/system/bin/{aa, bm, hidumper}` —— OpenHarmony 的 **Ability 助手 / Bundle 管理器 / 转储工具**（`hidumper` 53KB、`bm` 64KB 均为真实 ELF，非占位）
- `/system/lib64/*.z.so` 共 **245 个**，含 `libsamgr_proxy.z.so`、`libipc_single.z.so`、`libappexecfwk_core.z.so`、`libeventhandler.z.so` —— OHOS 的 SA 管理 / IPC / 应用框架
- `/system/etc/preloaded-harmony-classes` —— 预置 `ohos.app.AbilityContext / Application / Context …` 类白名单
- `/system/etc/permissions/ohos_sa.xml` —— OHOS 的 uid/gid ↔ 权限映射
- `libace_engine_v8.z.so` / `libace_engine_qjs.z.so` —— ArkUI(ACE) 引擎

> **对之前"10.1.0.182"的更正**：那是 `base` 包 `SOFTWARE_VER_LIST.mbn` 里写的**升级前基线**
> （增量包要求手机先处于 EMUI 10.1.0.182），不是本包推进去的系统版本。实际 system 镜像是
> 鸿蒙 2.0.0.171。cust 包仍是 EMUI 时代的 `10.1.0.162(C00E160R2P11)` 命名，鸿蒙升级沿用旧 cust，属正常。

## 二、包结构（三层）

```
UPDATE.APP  (华为私有容器：sec 头 + CRC.img + SHA256RSA.img 签名)
   ↓  HW-Update-Extractor
*.img       (Android sparse，magic 0xED26FF3A，块 4096)
   ↓  tools/hw-unpack.py
分区镜像     (SUPER.img 内是 LP 动态分区；分区本身是 EROFS)
   ↓  tools/erofs/erofs-extract.py
文件树
```

三个包分别对应：

| 目录 | 包用途 | 内容 |
|---|---|---|
| `系统/1` | 基础包 | `SUPER.img` 4.14G(sparse) + 内核/调制解调器/引导等 47 个镜像 |
| `系统/2` | 预置包 | `PRELOAD.img`（第三方预装 22 个 APK） |
| `系统/3` | 定制包 | `VERSION.img`（cust 分区，实内容仅 176KB） |

## 三、分区表（super 内 LP 元数据）

```
分区              大小            内容状态
system        2,776,629,248      EROFS，真实数据
hw_product    1,778,384,896      EROFS，真实数据
cust             92,274,688      ★ 全零（本包不更新 cust）
vendor          987,758,592      ★ 全零（本包不更新 vendor）
odm             234,881,024      ★ 全零（本包不更新 odm）
```

**为什么 cust/vendor/odm 是空的**：`SUPER.img` 的 sparse chunk 表里，从逻辑偏移
`0x10DF00000` 到结尾（1.25GB）整段是 `DONTCARE`，正好覆盖这三个分区。
说明这是**增量式更新包**，只推 system 与 hw_product；vendor/odm 沿用设备现有版本，
cust 走独立的 `update_sd_cust` 包（`系统/3`）。

> 注：`SUPER.img` 头部有 `LP_PARTITION_RESERVED_BYTES`(4096) 保留区，几何块在
> 4096 / 8192，元数据槽在 12288；且其几何块与元数据头都是 **SHA256 变体**
> （geometry struct_size=52，元数据表描述符从偏移 80 开始）——标准 lpunpack 会认不出来，
> 这就是 `tools/hw-unpack.py` 里要做兼容的原因。

## 四、文件规模

| 分区 | 文件数 | 解出体积 | APK | JAR | .so |
|---|---:|---:|---:|---:|---:|
| system | 8,555 | 3.83 GB | 291 | 114 | 2,803 |
| hw_product | 2,562 | 2.06 GB | 117 | 4 | 213 |
| preload | 71 | 1.23 GB | 22 | 0 | 27 |
| cust | 19 | 176 KB | 2 | 0 | 0 |

## 五、VR 相关盘点（和本项目直接相关）

### 5.1 system 分区里有的

| 路径 | 大小 | 说明 |
|---|---|---|
| `/system/framework/vr.jar` | 200 B | 空壳（EMUI 把实现放 vdex） |
| `/system/framework/vr.vdex` | 4.4 KB | `vr` 引导 classpath 的真实字节码 |
| `/system/framework/hwPartVr.jar` | 24.7 KB | 华为 VR 平台扩展（有实体代码） |
| `/system/framework/hwPartVrService.jar` | 22 B | 空壳，实体在 `boot-hwPartVr.vdex` |
| `/system/framework/{arm64/}boot-hwPartVr.vdex/.art` | 小 | 预编译产物 |
| `/system/lib64/libhivrar_service.so` | 528 KB | **Huawei AR 服务**（hivrar HAL 客户端） |
| `/system/lib64/vendor.huawei.hardware.hivrar@1.0/2.0/2.1/2.2.so` | 100K~492K | AR HAL 各版本 AIDL/HIDL |
| `/system/bin/hivrarserver` | 11.6 KB | AR 服务进程 |
| `/system/etc/init/hivrarserver.rc` | 237 B | 由 `hal.hivrarddk.exist` 触发，**默认 disabled** |
| `/system/etc/permissions/android.software.vr.xml` | — | `android.software.vr.mode` 特征 **被注释掉** |

### 5.2 system 里**没有**的

`com.huawei.vrservice`、`com.huawei.vrvirtualscreen`、`vrlauncherx`、`vrhandle`、
`hvrsdkserverapp`、`appmarket.vr`、`himovie.vr` —— 这些都不在 ELE-AL00 基础包内。
这与之前实测「设备上 `vr_system` binder 不存在、投屏 APK 起不来」完全吻合。

### 5.3 hw_product 里挖到的关键 APK

```
/hw_product/region_comm/china/app/VRServiceX/VRServiceX.apk   4,838,214 B
  package    : com.huawei.vrservice
  versionName: 11.1.0.320
  组件要点   :
    com.huawei.vrservice.VRSystemApp            ← 系统侧入口
    com.huawei.vrservice.CLIENT_SERVICE         ← 对外 binder（就是 vr_system）
    VRSysAppRequestService / VRGlassUpgradeActivity / GlassesDegreeAdjustmentActivity
    com.huawei.vrinstaller.*                    ← 眼镜侧 APK 的安装器（Welcome/Install/GlassesTip）
  权限       : com.huawei.vrservice.permission.VR、android.huawei.MARKETED_SYSTEM_APP
  sharedUserId: 有（系统级共享 uid）
```

**它不在区域预装清单里**（`region_comm/china/xml/APKInstallListEMUI5Release.txt` 十项中没有它），
所以出厂不会被 `region_comm` 自动装上，而是等 VR 流程触发时才装。这正是设备上
`pm install-existing` 失败、`vr_system` 起不来的原因——APK 本体其实一直躺在系统里。

> 可行的下一步：把该 APK 直接 `pm install`（signature 与平台同源，sharedUserId 有机会通过），
> 或 push 到 `/system/hw_product/...` 后用 system 身份安装，再验证 `isClientServiceAlive("vr_system")`。
> 需要眼镜在位时跑，用于确认「门禁放行」链路是否随之打开。

## 六、产物

源包（`系统/1`、`系统/2`、`系统/3`，共约 5.3 GB）已按要求在解包完成后删除，
`系统/` 现在只剩解包结果：

```
系统/extracted/
  system.img        2.78 GB   ← 可直接用于 patching / 挂载
  hw_product.img    1.78 GB
  boot/             321  MB   ← 47 个引导链镜像（KERNEL/RAMDISK/ERECOVERY/
                                 XLOADER/DTO/VBMETA…，从基础包里保留下来的）
  vr/VRServiceX.apk 4.8  MB   ← com.huawei.vrservice v11.1.0.320
系统/tree/{system,hw_product,preload,cust}/   完整文件树（权限/符号链接降级为普通文件）
系统/listing/*.txt                            各分区完整文件清单（含字节数）
系统/listing/region-APKInstallList.txt        区域预装清单（VRServiceX 不在其中）
```

未保留：`SUPER.img`（4.14G 源）、`PRELOAD.img`、`VERSION.img`——内容已全部进
`tree/` 与 `extracted/*.img`。cust / preload 的原始镜像也删了，因为其内容
（176 KB / 1.23 GB）已完整出现在 `tree/cust`、`tree/preload` 里。


## 七、工具链（本仓库）

```bash
# 1) UPDATE.APP → *.img  ：用 系统/HW-Update-Extractor-v1.1/HW-Update-Extractor.exe（GUI）

# 2) sparse / LP 解包（免落地，直接随机读）
python tools/hw-unpack.py info       <img>
python tools/hw-unpack.py lp-list    SUPER.img
python tools/hw-unpack.py lp-extract SUPER.img <outdir> [分区名...]
python tools/hw-unpack.py raw        <sparse.img> <out.img>

# 3) EROFS 解包
python tools/erofs/erofs-extract.py list    <img> [路径]
python tools/erofs/erofs-extract.py walk    <img> [路径] [out目录] [文件名正则]
python tools/erofs/erofs-extract.py extract <img> <镜像内路径> <输出文件>
python tools/erofs/erofs-extract.py find    <img> <关键字>
```
