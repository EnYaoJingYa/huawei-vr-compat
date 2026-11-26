# VR 姿态驱动示例 App

配合 [`docs/AI_VR_DRIVER_AND_CASTING.md`](../docs/AI_VR_DRIVER_AND_CASTING.md) 的
可运行示例：**自动选择 3DOF / 6DOF 姿态 → 双目立体渲染 → 外接 VR 眼镜**，
外加一条 **MediaProjection 平面投屏**的备用链路。

它演示的是「通用 Android 上能复刻的那部分」，不是华为原版 VR 合成器。
6DOF 优先使用 Android 公开的 `TYPE_POSE_6DOF` 传感器；设备没有就自动降级为
3DOF，**不会拿 IMU 积分伪造位置**。

> **本示例不是 ALVR 客户端。** 它没有 ALVR 网络协议、视频/音频解码、OpenXR 会话和
> 手柄输入。要做「手机当 ALVR 客户端 → 华为 VR Glass 无线串流」，请直接使用
> [`LHT02/HuaweiVRGlass-ALVR`](https://github.com/LHT02/HuaweiVRGlass-ALVR)；
> 选型、3DoF/6DoF 边界和打包步骤见
> [`docs/ALVR_HUAWEI_VR_GLASS.md`](../docs/ALVR_HUAWEI_VR_GLASS.md)。

---

## 1. 能做什么 / 不能做什么

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 3DOF 头部追踪 | ✅ | 系统旋转矢量（`TYPE_GAME_ROTATION_VECTOR` / `TYPE_ROTATION_VECTOR`），无则回退陀螺+加速度自融合 |
| 6DOF 头部追踪 | ✅（设备支持时） | 优先 `TYPE_POSE_6DOF`（公开 API，含米制位置）；没有该传感器就自动降级 3DOF，不伪造 |
| 自动选择姿态源 | ✅ | `6DOF → 眼镜 HID → 手机 IMU`，无 3DOF/6DOF 开关 |
| 双目立体渲染 | ✅ | 左右眼各一次 draw，FBO + 桶形畸变后处理 |
| 外接屏输出 | ✅ | `Presentation` 到非默认 display；检测到副屏自动开始，插拔自动跟随 |
| 姿态预测 | ✅ | 默认外推 10ms，对应原厂 `VrPoseState::predictPose` |
| 平面投屏 | ✅ | `MediaProjection` 单路 `SurfaceTexture` + GL 左右眼各采样一次 |
| 陀螺零偏学习 | ✅ | 静止检测后慢速更新 |
| 磁异常抑制 | ✅ | 模长超 20–80µT 时跳过 yaw 校正 |
| 华为眼镜 IMU | ⚠️ 实验性 | 需要能读 `/dev/hwvr1`（root / SELinux 放行）；否则自动回退手机 IMU |
| 华为私有系统服务 | ❌ | 不调用 `createVrDisplay`、不加载 `libxr_renderer.so` |

“自动”的边界：姿态源选择、3DOF/6DOF 降级、副屏上屏都可以自动；
**MediaProjection 投屏必须由用户点一次系统录屏授权**，普通 App 无法绕过。

---

## 2. 构建

需要：Android Studio（AGP 8.5.2 / Gradle 8.7 / JDK 17）、`compileSdk 34`、`minSdk 24`。

```powershell
# 方式一：Android Studio 直接打开 sample-app/
# 方式二：命令行（先生成 wrapper，仓库里没有提交 gradle-wrapper.jar）
cd sample-app
gradle wrapper --gradle-version 8.7
.\gradlew.bat assembleDebug
```

产物：`sample-app/app/build/outputs/apk/debug/app-debug.apk`。

> 本机没有 Gradle / Android Studio，**没有执行过 Gradle 的 `assembleDebug`**，
> 也没有在真机上跑过。但已经用 SDK 自带工具手工走通了整条链路：
> `aapt2 compile/link`（资源 + manifest）、`javac`（JDK 17 + `android-35/android.jar`）、
> `d8`、`zipalign`、`apksigner`（`apksigner verify` 通过）。所以语法、公开 API
> 引用、资源表、dex 和签名基本可信；剩下的风险主要是 Gradle 配置和真机行为。
>
> 仓库里有一份**已签名、可直接安装**的 debug APK：
> `sample-app/build/posedriver-debug.apk`（`versionCode 1`，SHA-256
> `C360590AA2653034B8B04D0BA6B1D55CEDB7E44C6DBBE58335FC5B5496EF3D41`）。
> 它不含 `lib/`、不含 `assets/`，只依赖 Android 公开 API。

### 已知注意点

- 没有依赖 AndroidX，主题直接用 `@android:style/Theme.Material.NoActionBar`；
- 通知图标用系统资源 `android.R.drawable.*`，不需要额外 drawable；
- `GLSurfaceView` 放在 `Presentation` 里，必须用 `createDisplayContext(display)` 创建；
- `MirrorService` 需要 `FOREGROUND_SERVICE_MEDIA_PROJECTION`（Android 14 起强制）；
- 投屏只建**一个** `VirtualDisplay`，左右眼在同一张 `SurfaceTexture` 上画两次。
  Android 13 起同一个 `MediaProjection` 的多个 VirtualDisplay 只有最后一个能出图；
- 悬浮窗路径需要用户在系统设置里授予「显示在其他应用上层」，没授权会自动回退到
  `Presentation`，不影响功能。

---

## 3. 使用

1. 把眼镜以**扩展屏 / 副屏**方式连上（不是镜像模式）。
   三星手机若自动进 DeX，改成「屏幕镜像」或关闭 DeX。
2. 安装并打开 App。状态栏会显示自动选中的姿态源和 `跟踪模式：6DOF / 3DOF`。
3. 如果副屏已经就绪，App 会**自动**创建 `Presentation` 并开始双目输出；
   没有自动开始就点 **开始立体输出**。手机屏继续显示控制台。
4. 戴上眼镜，点 **重定位**。6DOF 会把当前朝向和位置都记为零点，3DOF 只清零朝向。
5. 转头/走动验证：正前方的青色标记应在画面中央；左右各有 4 根彩色柱体。
   6DOF 设备上前后走动时，画面应有真实的相对位移；3DOF 设备上不会。
6. 点 **投屏到眼镜**：走系统录屏授权，把手机画面平面镜像到眼镜
   （同一帧在左右眼各画一份，不是立体）。

停止：点 **停止输出**。它会同时关掉自动上屏和投屏服务；下次点
**开始立体输出** 会重新启用自动上屏。退出 App 也会停止输出。

> 没有 `TYPE_POSE_6DOF` 的手机显示 `3DOF` 是正常的。这不是开关藏起来了，
> 而是设备/厂商没有暴露 6DOF sensor HAL；此时任何“6DOF”都只能是演示或 ARCore。
>
> 想确认机型有没有，可运行：
>
> ```powershell
> adb shell dumpsys sensorservice | Select-String -Pattern "pose|6dof" -CaseSensitive:$false
> ```

---

## 4. 可调参数

| 参数 | 位置 | 默认 | 怎么调 |
| --- | --- | --- | --- |
| IPD | `StereoRenderer.setIpdMeters` | 0.063 m | 眼距，画面重影就调它 |
| 竖直 FOV | `StereoRenderer.setVerticalFovDegrees` | 90° | 画面太挤/太远 |
| 预测时间 | `StereoRenderer.setPredictionMillis` | 10 ms | 转头拖影 → 调大；过冲 → 调小 |
| 畸变 k1/k2 | `LensProfile.GENERIC_BARREL` | 0.16 / 0.035 | 直线弯曲就调；`LensProfile.NONE` 关掉 |
| 色差 | `LensProfile.chroma` | 0.003 | 边缘彩边 |
| 传感器速率 | `PhoneSensorPoseSource.SAMPLE_PERIOD_US` | 10 ms | 掉帧就加大 |
| 磁校正增益 | `HeadPoseFusion.MAG_GAIN` | 0.8 /s | yaw 抖 → 调小 |
| 倾角增益 | `HeadPoseFusion.TILT_GAIN` | 1.6 /s | 走路时画面晃 → 调小 |
| gyro 单位 | `WalleHidPoseSource.GYRO_SCALE` | 1.0 | 转头速度差 57 倍时改成 `π/180` |
| 6DOF auto-level | `Pose6DofSensorSource.maybeCalibrate()` | 开 | 用 `TYPE_GRAVITY` 把厂商 world frame 对齐到 Y-up；画面整体倾斜时检查这里 |
| 6DOF 速率 | `Pose6DofSensorSource.SAMPLE_PERIOD_US` | 10 ms | 位置抖动大就加大 |
| 姿态源优先级 | `AutoPoseSource.choose()` | 6DOF → HID → 手机 | 想强制用眼镜 IMU 时改这里 |

`TYPE_POSE_6DOF` 的 world frame 由厂商定义，示例用重力自动求「上」方向。
如果某台设备的 6DOF 画面整体绕错轴，最可能是它的平移/旋转不在同一个
world frame；先看 logcat 的 `Pose6Dof: auto-level upWorld=...`，再改
`Pose6DofSensorSource` 的 `worldToRender` 初始化或 `maybeCalibrate()`。

华为 CV10 的真实光学参数没有还原（48 字节 feature report 的字段含义未知），
所以 `GENERIC_BARREL` 只是让管线可见，**不是原厂参数**。

---

## 5. 6DOF 是怎么接的

先分清三种“6DOF”，它们不是同一件事：

| 来源 | 本 App | 真实位置 | 依赖 |
| --- | --- | --- | --- |
| `Sensor.TYPE_POSE_6DOF` | ✅ 已实现，自动优先 | 是（厂商 fusion） | 设备必须暴露该 sensor，无第三方 SDK |
| ARCore | 未打包，可选接入 | 是（VIO） | Google Play Services for AR，华为设备通常没有 |
| 华为 `libVR6Dof.so` | ❌ 不复用 | 是（双目 VIO/SLAM） | 华为相机 HAL、标定、LED 布局，无法通用 |
| IMU 二次积分 | ❌ 不做 | 否，会指数漂移 | 无 |

### 5.1 `TYPE_POSE_6DOF`（本 App 默认）

`Pose6DofSensorSource` 直接读 Android 标准事件：

```text
values[0..3] = 四元数 (x, y, z, w)
values[4..6] = 平移 (x, y, z)，米，原点由厂商定义
```

内部仍然转成 `(w,x,y,z)`，并把平移按同一 world frame 旋转到渲染空间。
启动时用 `TYPE_GRAVITY` 自动把厂商的“上”对齐到渲染 `+Y`，再靠 `recenter`
清零 yaw 和位置。这样 Z-up 和 Y-up 两种厂商实现都能用。

`AutoPoseSource.choose()` 的顺序是：

```text
TYPE_POSE_6DOF > /dev/hwvr1（眼镜 HID 3DOF） > 手机 IMU（3DOF）
```

设备没有 `TYPE_POSE_6DOF` 时，`isPositionTracked()` 返回 false，状态栏显示
`3DOF`，渲染端不会收到位置。**这是硬件能力差异，不是 App 的演示开关。**

### 5.2 可选：加 ARCore

如果目标手机有 Google Play Services for AR，可以新增一个
`ArCoreSixDofProvider`，然后把它插到 `AutoPoseSource` 的 6DOF 分支：

```java
public final class ArCoreSixDofProvider implements SixDofProvider {
    private Session session;
    private final dev.vrdemo.posedriver.pose.Pose out =
            new dev.vrdemo.posedriver.pose.Pose();

    @Override public void getPose(dev.vrdemo.posedriver.pose.Pose dst) {
        Frame frame = session.update();
        com.google.ar.core.Pose camera = frame.getCamera().getPose();
        out.orientation.set(camera.qw(), camera.qx(), camera.qy(), camera.qz());
        out.position[0] = camera.tx();
        out.position[1] = camera.ty();
        out.position[2] = camera.tz();
        out.hasPosition = frame.getCamera().getTrackingState()
                == TrackingState.TRACKING;
        out.timestampNs = frame.getTimestamp();
        dst.set(out);
    }

    @Override public boolean isPositionTracked() { return true; }
    // start/stop/recenter/predict/name 按需实现
}
```

注意：

1. ARCore 是 Y-up、右手、相机朝 -Z，和本工程的渲染坐标一致，**不需要**再转一次；
2. `camera.tx/ty/tz` 是相机在 world 中的位置，渲染端已经按
   `view = T(-position) · Rᵀ` 处理；
3. 不要把 3DOF 的 `predict()` 叠加到 6DOF 上两次——ARCore 自己已经做了预测；
4. 这条路径需要额外依赖和 GMS，和“无依赖独立 APK”是互斥的，所以没打包进默认 APK。

`DemoSixDofProvider` 还留在源码里，但**默认不参与自动选择**；它只是渲染管线的
回放/教学用例，状态明确是“非真实跟踪”。

---

## 6. 文件地图

```
app/src/main/java/dev/vrdemo/posedriver/
├── MainActivity.java                 控制台 + 自动上屏 + Presentation 生命周期
├── cast/
│   ├── DisplayFinder.java            找副屏（名字 → presentation → 亮着的非默认屏）
│   ├── MirrorGlView.java             单路 SurfaceTexture → 左右眼各画一次
│   └── MirrorService.java            MediaProjection 平面镜像
├── pose/
│   ├── Quat.java                     (w,x,y,z) 四元数、积分、转矩阵
│   ├── Pose.java                     姿态 + 位置 + 角速度
│   ├── PoseSource.java               渲染端唯一依赖
│   ├── HeadPoseFusion.java           陀螺积分 + 重力/磁校正 + 零偏
│   ├── PhoneSensorPoseSource.java    手机 IMU
│   ├── Pose6DofSensorSource.java     TYPE_POSE_6DOF + 重力 auto-level（真 6DOF）
│   ├── AutoPoseSource.java           自动选择 6DOF → HID → 手机，热切换
│   ├── WalleHidPoseSource.java       /dev/hwvr1 45 字节报文（实验性）
│   ├── SixDofProvider.java           6DOF 契约
│   ├── DemoSixDofProvider.java       演示位移（默认不启用，明确非跟踪）
│   └── SwitchablePoseSource.java     保留的手动热切换工具
└── render/
    ├── StereoRenderer.java           双目 FBO + 畸变 + 预测
    ├── Scene.java                    网格地面 + 柱体 + 前方标记
    ├── LensProfile.java              畸变参数
    └── GlUtil.java                   着色器/纹理工具
```

---

## 7. 排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 状态显示 `3DOF` | 设备没有暴露 `TYPE_POSE_6DOF`，也没有可读的眼镜 HID | 正常降级；要真 6DOF 只能换设备或接 ARCore/自建 VIO |
| 6DOF 画面整体倾斜/绕错轴 | 厂商的 world frame 不是重力对齐的，或旋转/平移不同 frame | 看 logcat `Pose6Dof: auto-level upWorld=...`；改 `Pose6DofSensorSource` 的 `worldToRender`/`maybeCalibrate()` |
| 6DOF 静止时位置漂 | 厂商 fusion 的位置漂移 | 点「重定位」清零；这是 `TYPE_POSE_6DOF` 的硬件质量，不是渲染 bug |
| 一打开就上屏 | 检测到副屏后自动输出 | 设计如此；点「停止输出」会关闭自动上屏，直到再点「开始立体输出」 |
| 自动上屏没触发 | 眼镜是镜像模式，没有第二块 display | 改成扩展屏；看 logcat `DisplayFinder` 打印的屏幕列表 |
| 「未找到眼镜副屏」 | 同上 | 改成扩展屏；或点「开始立体输出」重试 |
| 眼镜黑屏 | `Presentation` 被系统拒绝 | 看 logcat `MainActivity`；确认副屏不是 protected display |
| 转头方向反了 / 画面倒 | 设备安装方向与假设不同 | 3DOF 改 `HeadPoseFusion` 的 `sensorToRender`；6DOF 先检查 auto-level |
| 画面左右眼互换 | 面板左右顺序 | 交换 `StereoRenderer.buildView` 里 `eyeOffsetX` 的符号 |
| 画面重影 | IPD 不对 | 调 `setIpdMeters` |
| yaw 慢慢漂 | 用的是 `GAME_ROTATION_VECTOR`（无磁） | 正常；点重定位，或改用 `ROTATION_VECTOR` |
| 投屏只有一半 | 眼镜面板不是 3200×1600 | `MirrorService` 按 `panelWidth/2` 分眼，检查实际分辨率 |
| 投屏只有一只眼有画面 | Android 13+ 不允许一个 projection 出多路 VirtualDisplay | 确认走的是 `MirrorGlView`（单路纹理画两次），不要改回两个 SurfaceView |
| `SecurityException` on `/dev/hwvr1` | SELinux 拒绝 | 用 root/ksu 方案，或不管它（自动回退手机 IMU） |
| 前台服务启动崩溃 | Android 14 缺类型/权限 | 确认 manifest 里的 `foregroundServiceType` 与权限 |

日志过滤：

```powershell
adb logcat -s MainActivity StereoRenderer DisplayFinder MirrorService WalleHidPoseSource
```

---

## 8. 与原厂的关系

| 原厂 | 本示例 | 差异 |
| --- | --- | --- |
| `VrPoseState` 全套融合 | `HeadPoseFusion` 最小版 | 少了 RLS、按活动等级调平滑、完整磁状态机 |
| `libMobileSensor` | `PhoneSensorPoseSource` | 用系统融合替代 `ASensor` 直读 |
| `libWalleDev` HID 解析 | `WalleHidPoseSource` | 报文格式一致；节点权限与 gyro 单位未验证 |
| `libVR6Dof` VIO/SLAM | `Pose6DofSensorSource`（`TYPE_POSE_6DOF`） | 不是同一套 VIO；设备支持时可用，不支持则 3DOF |
| `createVrDisplay` + OpenXR 立体提交 | `Presentation` + 自绘双目 | 没有系统虚拟屏、没有 timewarp、没有 runtime |
| `HvrMirrorService` | `MirrorService` | 同一套公开 API，整理成独立工程 |

需要「像原厂那样把手机画面放进 VR 空间」时，正确做法是自建 OpenXR runtime 或
在应用内做立体合成，而不是调用 `createVrDisplay`——后者是系统签名能力。
