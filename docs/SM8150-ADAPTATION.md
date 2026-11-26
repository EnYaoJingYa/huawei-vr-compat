# 华为 VR 兼容层 → OnePlus 7T (SM8150 / Android 11) 适配方案

> 2026-11-26。目标机：**OnePlus 7T / hotdogb / SM8150**，LineageOS 18.1（Android 11）。
> 源工程验证基线：**SM-F731U1（骁龙 888）/ Android 16**。
> 本文只讲「从已验证基线迁到 7T」需要改什么、怎么验，不重复 `PROJECT_STATUS.md` 的架构说明。

---

## 0. 先明确三件事

1. **本工程已经是高通适配**，不是麒麟工程。所有`/dev/hwvr1`、`hid_vr`、`vr.kirin980.so`
   等麒麟专属件都已被标准 HID / 公开 API 等价物替换，7T（高通）方向与工程路线一致。
2. **第七个包 `vrservice` 无需更换**。用户提供的「华为 VR 服务 12.0.0.302.zip」与
   `原包/com.huawei.vrservice.apk` 逐字节相同（sha256 `FD363DBE…`），工程里已是最新版；
   仅文档版本标注过时，已在 `BASELINE.md` / `PROJECT_STATUS.md` 更正。
3. **7T 相比验证基线的两个根本差异**：
   - **Android 16 → 11**：一批「Android 14+ 新增限制」的补丁在 11 上要么不需要、要么行为不同；
   - **SM-F731U1 → SM8150**：不过两者都是高通 + 标准 HID + DP Alt Mode，链路同构，
     且 7T 内核（`hotdogb-boot`）已按本项目需求开好 `CONFIG_HIDRAW` 与 DP 4-lane（见第 2 节）。

---

## 1. 为什么 7T 是比验证基线更「顺」的目标

`hotdogb-boot`（本工程配套的 boot 工程）已经为 VR Glass 做过内核级准备：

| 事项 | 7T 现状 | 对兼容层的意义 |
|---|---|---|
| `CONFIG_HIDRAW=y` | `clean` 档默认已开（实测可开机） | 眼镜 HID 接口枚举成 `/dev/hidrawN`，KSU 模块可直接用，无需改内核 |
| DP 4-lane | 补丁强制 pin assignment D，4×HBR2 = 17.28 Gbps | 3200×1600@70/90Hz 24bpp 带宽够，不会被降到 18bpp |
| 外接屏判定 | DP Alt Mode 走标准 Type-C | `VrPlatformCompat` 的「USB 身份 + 外接屏」双信号在 7T 上成立 |
| AVB/boot | 只换 kernel 段、test-keys 无签名 hash footer | 可自由刷入带 HID/DP 补丁的内核，不影响 system/vendor |

**结论**：内核与显示硬件层 7T 已就绪，移植工作集中在**应用层 Android 版本适配**。

---

## 2. Android 16 → 11 的版本适配清单

按「必须改 / 可保留 / 不适用」三档分类。原补丁在 Android 11 上的行为逐条给出。

### 2.1 必须调整

| 项 | 基线（Android 16）做法 | Android 11 调整 | 依据 |
|---|---|---|---|
| 动态广播导出标志 | `patch_receiver_exports.py` 改写 88 处 `registerReceiver`，补 `RECEIVER_EXPORTED` | **可跳过**：Android 11 无此强制；但 `HvrReceiverCompat` 若做了版本判断可保留，最稳妥是**保留补丁**（在 11 上传带该标志是合法的，API 26+ 起 `Context.registerReceiver(receiver, filter, flags)` 就存在） | `patch_receiver_exports.py` 头注 |
| `vrhandle` targetSdk 31 | 基线用 apksigner v2 签名，无需降级 | **需降到 29**：Android 11 的 v1 自签路线要求 targetSdk<30；若仍用项目 `apksigner` 则不必。走 Python 重签路线时按 `docs/RK3566-部署记录.md` 卡点 3 处理 | `RK3566-部署记录.md` §二 |
| `SYSTEM_ALERT_WINDOW` 声明 | `patch_platform_permissions.py` 给各包补声明 + `appops allow` | **必须补且必须声明**：Android 11 同样靠此豁免后台启动 Activity/前台服务；未声明权限时 `appops set` 静默失败（仍是 default） | `RK3566-部署记录.md` §五遗留 |
| `WRITE_SETTINGS` / `WRITE_SECURE_SETTINGS` | manifest 声明 + grant | **必须**：Android 11 禁止应用写 `Settings.System` 非公开键（`PRIVACY_ACCEPTED`），需 shell/root 预置 | `VR应用测试-2026-11-02.md` §127 |

### 2.2 可保留（Android 11 已支持）

| 项 | 说明 |
|---|---|
| `<queries>` 包可见性 | Android 11（API 30）引入，7T 上**正是必需**，四个 patch 里的 `queries` 全部保留 |
| 前台服务权限 `FOREGROUND_SERVICE` | Android 9 起就有，保留 |
| 包可见性 `QUERY_ALL_PACKAGES` 替代 | 已用逐包 `<queries>`，保留 |
| `sharedUserId` 移除 | 与 Android 版本无关，任何通用安卓都必须，保留 |
| `androidhwext` 主题父级改公共 | 资源层，与版本无关，保留 |

### 2.3 不适用（基线特有，7T 上别启用）

| 项 | 原因 |
|---|---|
| `ForegroundServiceStartNotAllowedException` 相关豁免（Android 12+） | Android 11 无后台前台服务限制，`install-six.ps1` 里对应 appops 做了也无害，但不必作为排障目标 |
| `FOREGROUND_SERVICE_MEDIA_PROJECTION`（Android 14+） | 仅 `sample-app` 投屏用，Android 11 无需 |
| `RECEIVER_NOT_EXPORTED` 语义差异 | Android 11 上两参数 `registerReceiver` 合法；`HvrReceiverCompat` 里的版本判断需确认在 11 上走的是原语义 |

> 一句话：**真正需要动手的只有 targetSdk（若走自签）和权限声明；其余补丁在 Android 11 上要么直接可用、要么无害**。这也是 RK3566（同为 Android 11）已经验证过的路线。

---

## 3. 落地步骤（7T 专用）

### 3.1 前置

- 7T 已 root（KernelSU，因为 KSU 模块 `hwvr_compat` 用 `service.sh` + `mknod`），
  SELinux 保持 Enforcing（模块用 `null_device` 标签，已验证不需要宽容模式）；
- 内核为 `hotdogb-boot` 的 `clean` 档（HIDRAW + DP 4-lane），`fastboot flash boot` 已刷入；
- ADB 可连（7T 建议 USB，无线调试也可）；
- 补齐 `com.huawei.himovie.vr.apk`（111 MB，超 GitHub 单文件上限，从 Release `original-apks-v1` 下载放入 `原包/`）。

### 3.2 构建（沿用工程工具链）

工程脚本是 PowerShell，若在你的环境可用：

```powershell
.\build\build-all.ps1 -Revision r15
.\install-six.ps1 -Revision r15
```

若只有 Python + openssl（无 JDK），走 RK3566 已验证的纯 Python 路线：

```bash
openssl pkcs12 -in signing/hvr-compat-debug.jks -nodes -passin pass:android \
    -nocerts -out .tmp/key.pem
openssl pkcs12 -in signing/hvr-compat-debug.jks -nokeys -passin pass:android \
    -clcerts -out .tmp/cert.pem
# 有 sharedUserId 的四个：去 uid + 重签
python tools/apk-repack-sign.py 原包/com.huawei.vrservice.apk        .tmp/a6.apk
python tools/apk-repack-sign.py 原包/com.huawei.hvrsdkserverapp.apk  .tmp/a3.apk
python tools/apk-repack-sign.py 原包/com.huawei.vrvirtualscreen.apk  .tmp/a7.apk
python tools/apk-repack-sign.py 原包/com.huawei.vrlauncherx.apk      .tmp/a5.apk
# targetSdk 31 的 vrhandle 降到 29
python tools/apk-repack-sign.py 原包/com.huawei.vrhandle.apk .tmp/a4.apk --target-sdk 29
# 其余两个只统一签名
python tools/apk-repack-sign.py 原包/com.huawei.appmarket.vr.apk .tmp/a1.apk
python tools/apk-repack-sign.py 原包/com.huawei.himovie.vr.apk   .tmp/a2.apk
adb install -r -d .tmp/a{1,2,3,4,5,6,7}.apk
```

> 注意：`apktool` / `aapt2` 打不开中文路径，先把 APK 复制到 ASCII 目录再处理。

### 3.3 装 KSU 模块 + 授权

```bash
# 1) 打包 KSU 模块（源码 -> 可安装 zip）。仓库已附 build/hwvr_compat.zip；
#    若改过 ksu/hwvr_compat/ 下的脚本或探测二进制，需重新生成：
python tools/build-ksu-module.py
# 2) 推到设备并用 KernelSU 安装（造 /dev/hwvr1 + 对齐 1600x3200 横屏）
adb push build/hwvr_compat.zip /data/local/tmp/hwvr_compat.zip
su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/hwvr_compat.zip"
# 软重启即可触发模块脚本
# 3) 补授权（按 install-six.ps1 / grant-vr-perms.sh 的清单）
sh tools/grant-vr-perms.sh <设备地址>
```

关键授权（缺一会导致主线断裂）：
`SYSTEM_ALERT_WINDOW`（各包 manifest 要先声明）、`WRITE_SETTINGS`、
`WRITE_SECURE_SETTINGS`、`READ_PHONE_STATE`，以及 deviceidle 白名单。

### 3.4 验证判据

| 层面 | 命令 / 判据 | 期望 |
|---|---|---|
| 节点 | `ls -l /dev/hwvr1` | 存在，指向应答 HID feature report 的控制接口（`12d1:107e`） |
| 在位 | `logcat -s VrPlatformCompat` | `glass probe: usb=true externalDisplay=true` |
| USB | `dumpsys usb` | `12d1:1092` CV10 + `12d1:107e` HID 同时出现 |
| 显示 | `dumpsys display` | 含 `HUAWEIAV03` 外接屏（DP Alt Mode） |
| 主线 | `logcat \| grep -E 'VrSystemActor\|start 3D Launcher\|UsingCtrl'` | 握手 → 准备页 → 3D Launcher → `status 5` |
| 姿态 | `logcat -s UnityPlugin` | `HVR_GetSensorState` 四元数随头动变化 |
| 画面 | **肉眼/外接录像** | 眼镜双眼各占面板一半、双眼重合、卡片文字朝向正确 |

> 提醒：`PatchAudit` 第 11.3 节已确认该层 `screencap` 不可信（抓到的始终是同一张黑图），
> **不要用截图判断眼镜有没有画面**。

---

## 4. 7T 上可能踩的专属坑（预研，非已验证）

| 现象 | 可能原因 | 处理方向 |
|---|---|---|
| 眼镜插上无外接屏 | 7T 的 DP Alt Mode 未协商成 4-lane，或用了不支持 Alt Mode 的线 | 确认 `hotdogb-boot` DP 补丁已刷；换支持 DP 的 Type-C 线；`dumpsys display` 看有无 `HUAWEIAV03` |
| `/dev/hwvr1` 建不出 | 7T KernelSU 的 `service.sh` 未跑，或 hidraw 路径不同 | 确认 KSU 模块在 late_start 拉起；`find_control_iface` 用协议探测而非写死设备名，应能自适应 |
| 平台类 ClassNotFound 刷屏 | `shared/java` 的 40 个类未注入 | Android 11 上需 LSPosed 或 bundled dex 才生效；`lsposed/hvr-display-routing` 需启用 |
| 投屏只有一只眼 | 若走 sample-app，`MediaProjection` 多 VirtualDisplay 在 Android 13+ 才有问题，11 上两路 SurfaceView 可用 | 用工程自带 `HvrMirrorService` 即可 |
| 主界面点「开启 VR 之旅」无反应 | `vr_system` 门禁：眼镜不在位或 `com.huawei.vrservice` 没注册 binder | 按 `PATCH_AUDIT.md` 第 18/20 节查第七个包是否真正起来 |

---

## 5. 与已归档状态的关系

- 本方案**不改动任何应用逻辑与接口**，符合 `PORTING_METHOD.md` 口径；
- 已验证基线（SM-F731U1/Android 16）的未完成项（眼镜输出层前缓冲直出、
  重投影 90Hz、CF20 长期配对稳定）在 7T 上同样未完成，属同一路线图，不因换机而改变；
- 用户提供的 12.0.0.302 包与工程内一致，无替换动作；文档版本标注已更正。

---

## 6. 一句话总结

7T 的内核/DP/HIDRAW 层已由 `hotdogb-boot` 备好，兼容层本身已是高通路线；
迁移到 Android 11 真正要动的只有**权限声明**与（若自签）**vrhandle 的 targetSdk**，
其余补丁直接沿用。可参照同为 Android 11 的 `RK3566-部署记录.md` 走纯 Python 重签路线，
按第 3 节步骤落地，按第 3.4 节判据验收。
