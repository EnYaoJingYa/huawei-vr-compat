# 华为 VR Glass 6DoF 软件栈（ELE-AL00 / HarmonyOS 2.0.0.171）

> 依据：`系统/tree/` 解出的 system + hw_product 全树、`decode/` 里反编译的华为 VR 全家桶、以及设备实测（USB 枚举）。
> 结论先说：**6DoF 没有"一个驱动文件"**，它是一条五层链；其中内核/厂商驱动在 `vendor` 分区，这次解包的增量包 **不含 vendor**（super 内是空区）。

---

## 一、先分清两个 6DoF

| | 头显 6DoF（HMD 位姿） | 手柄 6DoF（CF20 位姿） |
|---|---|---|
| 数据来源 | **6DoF 摄像头套件**（插在眼镜上的双摄模块）+ 眼镜 IMU | 手机摄像头看手柄上的光点 + 手柄自身 IMU/按键 |
| 传输 | USB（摄像头走 UVC/Camera，IMU 走厂商通道） | **BLE GATT**（私有服务 `622f5b2a-…` / 特征 `ffb4a651-…`） |
| 算法位置 | 手机端 native（`libarvr_slam.so` VIO） | 手机端 native（`libVR6Dof.so` 的 `BlobDetection`） |
| 系统驱动 | 有（vendor 里的 hivrar HAL + USB/内核驱动） | **没有驱动**，纯用户态 GATT |

> `com.huawei.vrhandle` 的文案印证了硬件形态：
> `Your controllers are paired automatically when the 6DoF camera add-on is inserted`
> —— 手柄是随"6DoF 摄像头配件"插入后自动配对的。

---

## 二、五层链路（自下而上）

```
① 硬件   眼镜 CV10 + 6DoF 摄像头套件(双摄) + IMU，USB-C 复合设备
             │  实测：USB 侧出现 "HUAWEI GLASS HID"（/dev/input/event7，usb-xhci…/input4）
             │        只声明音量键/媒体键；CF20 不在系统输入设备里
② 驱动   【vendor 分区】hivrar HAL 实现 + 内核 USB/UVC/厂商驱动   ← 本包未含
③ 服务   /system/bin/hivrarserver（HiVRARService → defaultServiceManager）
          /system/lib64/libhivrar_service.so
          /system/lib64/libmaplehwPartVr.so、libmaplehwPartVrService.so
          触发条件：property hal.hivrarddk.exist=yes（默认 disabled）
④ 算法   com.huawei.hvrsdkserverapp/assets/arm64-v8a/*.so（约 38MB）
          libarvr_slam.so 12.0M  VIO SLAM
          libVR6Dof.so     6.5M  6DoF 总控 + 手柄光点检测 + pose 平滑
          libvrpose.so / libWalleAlg.so   IMU 姿态(VrPoseState)、磁/倾斜校准
          libWalleDev.so   设备层：ProcessDataImu / ProcessDataHeadPos / ProcessDataContrPos
          libctrl3dof.so   控制器 3DoF   libGuardianArea.so 安全区
          libmindspore-lite / libhiai*  NPU 推理   libhivrar_fd.so: getFd() 拿 HAL 的 fd
⑤ 框架    /system/framework/hwPartVr.jar → android.vrsystem.HwVrServiceManager(Impl)、VrTouchInterface
          com.huawei.vrservice（VRServiceX.apk）→ binder "vr_system"（门禁 isClientServiceAlive 看它）
          /system/framework/vr.jar(+vr.vdex) → /system/bin/vr 命令
          rendercomposer + android.frameworks.vr.composer@1.0（VR 显示合成）
          com.huawei.arengine.service（HuaweiAREngine.apk，libhiar_aladdin.so = AR 算法）
          XRKit.apk（libxr_loader.so = OpenXR loader、libhuawei_arengine_ndk/jni）
```

### ③④ 之间是两套接口，别混

- **system 侧 HIDL**（`/system/lib64/vendor.huawei.hardware.hivrar@2.x.so` 里的桩）：
  `IHwHiARBase`、`IHiARPPService(±Callback)`、`IHiARLiveDetect`
- **app 侧 AIDL**（在 `com.huawei.hvrsdkserverapp` smali 里出现 1041 次 `hivrar`）：
  ```
  android.hardware.hivrar.IHivrarService
  android.hardware.hivrar.IHiARManager
  android.hardware.hivrar.camera.IHiARCamera            ← 摄像头帧
  android.hardware.hivrar.extractor.IHiARFeatureExtractor(±Callback)   ← 特征提取（SLAM 前端）
  android.hardware.hivrar.enhancement.IHiARImageEnhancement(±Callback)
  ```

---

## 三、手柄那条（我们已经在跑）

CF20 的"驱动"就是**我们自己写的** `shell/java/com/hvr/shell/ControllerLink.java`：

- 订阅厂商服务 `622f5b2a-60da-4484-929a-69e3a9140258` 下 `ffb4a651-…` 一路 NOTIFY，约 100 包/秒
- 不要订 HID 0x1812 的 Report（CCCD 写会挂死 ATT 队列）、不要写 0x2A4E、不要 createBond
- 参考实现：`F:\PY\VrGlass\Andriod\vrremote`（`docs/controller-protocol.md`、`BleControllerTransport.kt`、`ControllerFrameParser.kt`）

系统侧对应物只有 `libctrl3dof.so`（老 3DoF 手柄）和 `libVR6Dof.so` 里的 `ARVR_CONTROLLER::Controller::PushControllerIMU`——**都是给华为自己那套 SLAM 融合用的，不对外开放**。

---

## 四、能直接用的工具 / 接口

| 工具 | 位置 | 用法 |
|---|---|---|
| `vr` 命令 | `/system/bin/vr` | shell 脚本，`app_process` 跑 `com.android.commands.vr.Vr`（CLASSPATH=vr.jar） |
| `hivrarserver` | `/system/bin/hivrarserver` | HAL 服务端；`setprop hal.hivrarddk.exist yes` 才会起（rc 里默认 disabled） |
| VR binder 客户端 | `hwPartVr.jar` → `android.vrsystem.HwVrServiceManager` | 反编译在 `decode/hwPartVr/smali/android/vrsystem/` |
| VR 显示合成 | `/system/bin/rendercomposer`、`android.frameworks.vr.composer@1.0.so` | VR 模式下的帧调度/合成 |
| IMU 原始日志 | `/sdcard/immlog/imudata%d-…txt`、`oridata%d-…txt` | `libWalleAlg.so` 里 `OpenImuLogFile/OpenOrientationLogFile` 写出的 **6DoF 原始数据**，抓姿态必看 |
| 日志 tag | `fmt:pose@org:vr6dof`、`VrPoseState`、`WalleCommon` | `logcat \| grep -E "vr6dof\|Walle"` 可看到 pose/VIO 过程 |
| AR 引擎 | `com.huawei.arengine.service` | `libarengine_core.so` + `libhiar_aladdin.so`(6.6M) + `libhsdk.so`(13.7M) |
| HiAI 视觉插件 | `hw_product/…/HwHiAiEngine/visionplugin-headpose-kirin980-*.apk`、`visionplugin-tracking-common-*.apk` | 头部姿态/追踪模型（NPU） |

---

## 五、缺什么 / 下一步怎么补

1. **vendor 分区没解出来**。这套包是增量包，super 里 `cust/vendor/odm` 全是 `DONTCARE` 空区。
   真正的 `vendor.huawei.hardware.hivrar@2.2-impl.so`（HAL 实现）与内核驱动都在 `/vendor`，需要从设备上直接拉。
2. 设备在位时用下面几条就能定位到"驱动到底叫什么"：
   ```bash
   adb shell ls -l /vendor/lib64/hw | grep -i hivrar
   adb shell ls -l /vendor/etc/init | grep -i hivrar
   adb shell getprop | grep -iE "hivrar|vr"
   adb shell ls -l /dev | grep -iE "vr|cam|hid"
   adb shell lsmod            # 看有没有眼镜相关模块
   adb shell dumpsys media.camera | grep -iE "glass|vr"
   ```
3. 想自己算 6DoF 而不依赖华为 `vr_system`，可行路线是拿 `IHiARCamera` 的帧（或直接 Camera2 打开眼镜双摄）+ 自建 VIO；
   但 `hivrar` AIDL 需要 `com.huawei.android.permission.VR`，非系统签名拿不到——这就是当前门禁之外的第二个坑。

---

## 六、一句话总结

- **6DoF 算法** = `com.huawei.hvrsdkserverapp` 里的 `libarvr_slam.so` + `libVR6Dof.so` + `libvrpose/libWalleAlg`（都在 `decode/com.huawei.hvrsdkserverapp/assets/arm64-v8a/`）。
- **6DoF 驱动** = `vendor` 分区的 `hivrar` HAL + 内核 USB/UVC 驱动，服务端是 `/system/bin/hivrarserver`；**这套包里没有 vendor，所以要上机去拉**。
- **手柄 6DoF 没有驱动**，BLE GATT 私有服务，我们已经实现（`ControllerLink.java`）。
