# vr/ —— VR Glass 与 6DoF 相关资产总仓

从固件（HarmonyOS 2.0.0.171 / ELE-AL00）、反编译产物、原包 APK 里挑出来的 VR 相关内容，按层分类。
**共约 473 MB**，来源路径都写在每节末尾，想回溯可以直接去原树找。

```
vr/
├── 01-6DoF算法与模型/     75M   ★ 真正的 6DoF：SLAM + 手柄光点检测 + 标定文件
├── 02-系统服务/            1.1M hivrarserver、hivrar 服务端库
├── 03-框架JAR与VDEX/      55K   hwPartVr.jar（唯一可直接调的 VR 接口）
├── 04-HAL-hivrar-桩/       1.5M vendor 那边 HAL 的客户端桩（4 个版本）
├── 05-VR显示合成/         690K  rendercomposer + VR composer HAL
├── 06-应用APK/            300M  华为 VR 全家桶 / AR·XR / HiAI 视觉插件
├── 07-反编译/             140K  框架层 smali + 其余包的索引
├── 08-文档/               40K   6DoF 软件栈、固件分析、手柄协议
└── 09-上机核验/            4K   probe-vr.sh（一条命令把驱动/HAL 全查出来）
```

---

## 01-6DoF算法与模型 ★

`com.huawei.hvrsdkserverapp` 的 `assets/` 全量（38MB so + 37MB 模型/贴图/配置）。

| 文件 | 大小 | 作用 |
|---|---|---|
| `arm64-v8a/libarvr_slam.so` | 12.0M | VIO SLAM（`HW_SLAM::HandlerOutputPose`） |
| `arm64-v8a/libVR6Dof.so` | 6.5M | 6DoF 总控；手柄光点检测 `BlobDetection`、`ARVR_CONTROLLER::Controller::PushControllerIMU`、pose 平滑 |
| `arm64-v8a/libWalleAlg.so` | 416K | IMU 姿态 `VrPoseState`（磁/倾斜校准），IMM 日志落 `/sdcard/immlog/` |
| `arm64-v8a/libWalleDev.so` | 322K | 设备层：`ProcessDataImu/HeadPos/ContrPos`、`getGlassVersion/parseGlassSwVersion`、`/dev/%s` |
| `arm64-v8a/libvrpose.so` | 264K | 位姿封装 |
| `arm64-v8a/libctrl3dof.so` | 326K | 老 3DoF 手柄 |
| `arm64-v8a/libhivrar_fd.so` | 15K | 向 hivrar HAL 取 fd（导出 `getFd()`） |
| `arm64-v8a/libGuardianArea.so` | 1.2M | 安全区/边界 |
| `arm64-v8a/libmindspore-lite.so` + `libhiai*` | ~9M | NPU 推理运行时 |
| `arm64-v8a/libxr_loader.so` | 1.5M | OpenXR loader |
| `SDmmm1_fp16_480_640.om` | 356K | MindSpore 离线模型（480×640 输入） |
| **`vrglass.xml`** | 16K | **SLAM 标定文件**：双目标定 `CameraNum=2`、相机型号 imx600、640×480@15fps、IMU 外参、左右手柄标定/LR SN、`AlgorithmVersion v4.0+20210331` |
| `VRThermalConfig.json` | 3.7K | 温控降频策略 |
| `whitelist.json` | 483B | 白名单：`com.nolovr.nolohome.huawei`（NOLO 第三方 6DoF）走 `VrInteractiveDeviceManager` |
| `sdklibs.json` | 913B | SDK 导出接口：`VrFramework/VrSystemClient/VrControllerManager/VrHelmetExt` |
| `*.png` | ~10M | 眼镜侧 UI 贴图（前/后/左/右/上/下、图标） |

来源：`decode/com.huawei.hvrsdkserverapp/assets/`（原包 `com.huawei.hvrsdkserverapp.apk` v3.5.0.82）

## 02-系统服务

| 文件 | 说明 |
|---|---|
| `bin/hivrarserver` | 11.5K，注册 `android::hardware::hivrar::HiVRARService`；由 `hal.hivrarddk.exist=yes` 拉起，**rc 里默认 disabled** |
| `etc/hivrarserver.rc` | 启动条件 |
| `etc/android.software.vr.xml` | `android.software.vr.mode` 特征是**被注释掉的**（所以系统不认作 VR 设备） |
| `lib64/libhivrar_service.so` | 528K，服务端实现 |
| `lib64/libmaplehwPartVr.so` / `libmaplehwPartVrService.so` | 77K / 53K，maple 侧桥接 |

来源：`系统/tree/system/system/{bin,etc,lib64,lib}`

## 03-框架JAR与VDEX

| 文件 | 说明 |
|---|---|
| `hwPartVr.jar` | 24.5K，`android.vrsystem.HwVrServiceManager(Impl)`、`VrTouchInterface`——**门禁判定就在这里** |
| `vr.jar` + `vr.vdex` + `oat-*/vr.odex` | 200B 空壳 + vdex/odex，`/system/bin/vr` 靠它跑 `com.android.commands.vr.Vr` |
| `boot-hwPartVr.vdex` + `arm64/boot-hwPartVr.{art,oat,vdex}` | 引导类预编译产物 |

## 04-HAL-hivrar-桩

`vendor.huawei.hardware.hivrar@1.0 / 2.0 / 2.1 / 2.2.so`（arm64 与 32 位各一套）。
这些只是**客户端桩**，接口：`IHwHiARBase`、`IHiARPPService(±Callback)`、`IHiARLiveDetect`。
实现在 `/vendor`（本包没有，见 09 的核验脚本）。

## 05-VR显示合成

`bin/rendercomposer`、`etc/rendercomposer.rc`、`android.frameworks.vr.composer@1.0.so`（VR 模式下的采集/合成调度）。

## 06-应用APK

| 目录 | 包 | 版本 |
|---|---|---|
| `华为VR全家桶/` | com.huawei.vrservice | 12.0.0.302（原标 11.0.0.322；**来自设备原包**，比固件里的新） |
| | com.huawei.hvrsdkserverapp | 3.5.0.82 |
| | com.huawei.vrhandle | 10.0.1.345 |
| | com.huawei.vrlauncherx | 11.1.0.337 |
| | com.huawei.vrvirtualscreen | 11.1.0.325 |
| | com.huawei.appmarket.vr | 12.2.1.301 |
| | com.huawei.himovie.vr | 8.2.0.300 |
| `AR与XR/` | XRKit（`com.huawei.featurelayer.sharedfeature.xrkit`） | 11.0.0.305 |
| | HuaweiAREngine（`com.huawei.arengine.service`） | 60MB，含 `libhiar_aladdin.so` |
| `HiAI视觉插件/` | `visionplugin-headpose-kirin980`、`visionplugin-tracking-common` | 头姿/追踪模型 |

固件里那个**更新**的 `com.huawei.vrservice`（11.1.0.320，来自 `VRServiceX.apk`）留在
`系统/extracted/vr/VRServiceX.apk`，因为它是随 HarmonyOS 2.0 一起来的。

## 07-反编译 / 08-文档 / 09-上机核验

- `07-反编译/hwPartVr/`：框架层 smali；其余包索引和重跑方法见 `说明.md`
- `08-文档/`：`6DoF-软件栈.md`（五层链路）、`固件分析.md`、`手柄协议-controller-protocol.md`（vrremote）、`vrremote-architecture.md`
- `09-上机核验/probe-vr.sh`：`./probe-vr.sh` 一把梭查 /vendor 里的 hivrar 实现、内核模块、USB 12D1:3A09、相机数量、6DoF 日志

---

## 一句话导航

- 想让手柄动 → 看 `08-文档/手柄协议-controller-protocol.md` + 我们自己的 `shell/java/com/hvr/shell/ControllerLink.java`
- 想知道 6DoF 怎么算 → `01-6DoF算法与模型/`
- 想知道为什么华为那套起不来 → `08-文档/6DoF-软件栈.md` 第五节 + `09-上机核验/`
- 想接管 VR 门禁 → `03-框架JAR与VDEX/hwPartVr.jar` + `06-应用APK/华为VR全家桶/com.huawei.vrservice.apk`
