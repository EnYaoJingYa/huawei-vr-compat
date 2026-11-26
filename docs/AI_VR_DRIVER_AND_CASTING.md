# 华为 VR 姿态驱动与投屏链路：AI 实现手册

本文把仓库里已经反汇编确认的事实，整理成**可以直接照着实现**的规格。目标读者是 AI 代理或工程师：
它需要知道「哪一层负责什么、数据长什么样、坐标怎么摆、哪些是猜的」。

**证据等级标记**（全文统一）：

| 标记 | 含义 |
| --- | --- |
| `[实测]` | 反汇编/字符串/Java 字节码里直接读到，可在本仓库复现 |
| `[推断]` | 由多个 `[实测]` 拼出来的高置信结论，但没有逐指令验证 |
| `[未知]` | 没有证据。实现时必须自己定值，或运行时探测 |

> 本文只描述**公开可得的包内代码**与**标准 Android API**。没有把华为私有服务说成通用能力，
> 也没有把「能用 MediaProjection 做的事」说成「能复刻原版 VR 合成器」。

---

## 0. 30 秒摘要

| 能力 | 原厂实现 | 关键产物 | 通用 Android 能否复刻 |
| --- | --- | --- | --- |
| 头盔 3DOF | 眼镜 IMU → `/dev/hwvr1` → `libWalleDev` 解析 → `libWalleAlg` 融合 → `Posture.quat` | 四元数 `(w,x,y,z)` | **能**：手机 IMU 或自建 HID 读取 |
| 手柄 3DOF | `libctrl3dof.so`，`DOEaG` + `FF_RLS` + 磁异常判定 | `VrCtrl3Dof_*` C 接口 | **能**（算法要自己写） |
| 6DOF | 双目鱼眼 + IMU 的 VIO/SLAM（`libVR6Dof.so` + `libarvr_slam.so`） | `GetVR6DofInterface()` | **不能凭空复刻**：需要相机标定与 SLAM；可用公开 `TYPE_POSE_6DOF`（设备支持时）或 ARCore |
| 原版投屏 | `createVrDisplay` 建虚拟屏 → `SurfaceTexture` 采集 → OpenXR 立体提交 | `libxr_renderer.so` | **只能等价替代**：副屏 + MediaProjection |
| 免 root 投屏 | 副屏 + `MediaProjection` + 单路 `SurfaceTexture` 双目采样 | `MirrorGlView` | **能**；`HvrMirrorService` 仍是两路 SurfaceView，Android 13+ 需按此改造 |

一句话：**姿态的 3DOF 部分是可移植的算法 + 协议；原厂 6DOF 是相机 SLAM，不是 IMU 技巧，通用设备只能用公开 `TYPE_POSE_6DOF`（有则用）或 ARCore/自建 VIO 替代；投屏原版是系统级合成，通用替代是平面镜像或自建双目渲染。**

---

## 1. 证据基线

### 1.1 本文用到的文件

| 路径 | 作用 |
| --- | --- |
| `decode/com.huawei.hvrsdkserverapp/smali/com/huawei/vrframework/VrHelmetExt.smali` | 对外姿态入口 `getData(long)` |
| `.../com/huawei/hwvrexternaldevice/Posture.smali` | 姿态数据结构 |
| `.../com/huawei/hwvrexternaldevice/interactive/VrInteractiveDeviceManager.smali` | `getHeadPose` 与设备索引 |
| `.../com/huawei/hvrsdkserverapp/module/ArvrRuntimeModuleManager.smali` | JNI 姿态入口、`updateInfoNative` |
| `.../com/huawei/hvrsdkserverapp/service/ArvrRuntimeService.smali` | 原生库加载顺序 |
| `decode/com.huawei.hvrsdkserverapp/assets/{arm64-v8a,armeabi-v7a}/libWalleDev.so` | HID 传输 + IMU 报文解析 |
| `.../libWalleAlg.so`、`libvrpose.so` | 3DOF 融合、磁校正、预测 |
| `.../libMobileSensor.so` | 手机 IMU 3DOF 回退 |
| `.../libctrl3dof.so` | 手柄 3DOF |
| `.../libVR6Dof.so`、`libarvr_slam.so` | 6DOF VIO/SLAM |
| `.../libruntime_service_module.so` | 把上面几个接口串起来的服务层 |
| `decode/com.huawei.vrvirtualscreen/smali/com/huawei/vrbase/NativeLib.smali` | `libxr_renderer.so` 的 JNI 声明 |
| `.../b/a/c/f/a0.smali`、`.../b/a/c/f/z.smali` | 屏幕采集、虚拟屏创建 |
| `decode/com.huawei.vrvirtualscreen/lib/armeabi-v7a/libxr_renderer.so` | OpenXR 应用侧渲染器 |
| `shared/java/com/huawei/vrvirtualscreen/mirror/` | 仓库已有的免 root 投屏实现 |

### 1.2 复现命令

仓库自带的脚本在 `分析/`（需要 `pyelftools` + `capstone`）：

```powershell
# 符号表
py 分析\elfdump.py decode\com.huawei.hvrsdkserverapp\assets\arm64-v8a\libWalleAlg.so

# 关键字字符串
py 分析\strings_kw.py decode\com.huawei.hvrsdkserverapp\assets\arm64-v8a 分析\out

# 反汇编指定函数（ARM64）
py 分析\disas.py decode\com.huawei.hvrsdkserverapp\assets\arm64-v8a\libWalleAlg.so "_ZN11VrPoseState12calculatPoseER7IMUData"

# 按地址反汇编（Thumb 库要换 llvm-objdump + thumb 解码）
py 分析\disas.py decode\com.huawei.vrvirtualscreen\lib\armeabi-v7a\libxr_renderer.so "^$" 0xa621 0xa6b9

# 读 .data 里的函数指针表
py 分析\readva.py decode\com.huawei.hvrsdkserverapp\assets\arm64-v8a\libVR6Dof.so 0x636050 0x636060
```

`libWalleDev.so` / `libxr_renderer.so` 的 32 位版本是 **Thumb**，用 `llvm-objdump -d -T` 时必须让工具按 Thumb 解码，否则结果不可读。

---

## 2. 分层架构

```
┌──────────────────────────────────────────────────────────────────┐
│ 应用 / SDK 层                                                     │
│   VrHelmetExt.getData(t)                → float[7]                │
│   VrInteractiveDeviceManager.getHeadPose(t) → Posture             │
└───────────────────────────┬──────────────────────────────────────┘
                            │ AIDL: ArvrRuntimeInternalInterface.getPosture(index,time)
┌───────────────────────────▼──────────────────────────────────────┐
│ Java 服务层  ArvrRuntimeModuleManager                             │
│   getPosture(i,t) → getHelmetPos / getLeftCtrlPos / getRightCtrlPos│
│   updateInfoNative(index, type, time)  ← JNI                      │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│ 原生服务层  libruntime_service_module.so                          │
│   GetVR6DofInterface() / GetSlamInterface()                       │
│   GetControllerThreeDoFInterface()                                │
└───────┬───────────────────┬───────────────────┬──────────────────┘
        │                   │                   │
┌───────▼────────┐ ┌────────▼────────┐ ┌────────▼───────────────┐
│ 3DOF 头盔      │ │ 3DOF 手柄       │ │ 6DOF SLAM              │
│ libWalleDev    │ │ libctrl3dof     │ │ libVR6Dof + libarvr_slam│
│ libWalleAlg    │ │ DOEaG/FF_RLS    │ │ 双目鱼眼 + IMU          │
│ （手机回退：   │ │                 │ │ OpenCV + Ceres          │
│  libMobileSensor）│ │               │ │                        │
└───────┬────────┘ └─────────────────┘ └────────────────────────┘
        │ HID feature/input report
┌───────▼──────────────────────────────────────────────────────────┐
│ 传输层  /dev/hwvrN  （EMUI 的 HID 透传驱动，标准 HIDIOC*）        │
└──────────────────────────────────────────────────────────────────┘
```

关键点：**原厂没有任何私有内核 ABI**。`/dev/hwvrN` 只是把 HID 设备暴露出来，
上层靠 feature report 的应答来识别设备（详见 `docs/HELMET_HID_PROTOCOL.md`）。

---

## 3. 姿态：Java 侧契约

### 3.1 调用链 `[实测]`

```
VrHelmetExt.getData(long timeMs)
  └─ VrInteractiveDeviceManager.getHeadPose(timeMs)
       ├─ 若 hw6DofHeaderAvailable:
       │    VrFramework.getRuntimeInterface()
       │      .getPosture(mAvailableHeadSenserIndex, timeMs)
       └─ 否则走旧的 IHWVRInteractiveDevice
            └─ ArvrRuntimeModuleManager.getPosture(index, timeMs)
                 ├─ index 0 → getHelmetPos(use6Dof, timeMs)
                 ├─ index 1 → getLeftCtrlPos(...)
                 └─ index 2 → getRightCtrlPos(...)
```

`ArvrRuntimeModuleManager` 里三个方法都会先调：

```java
updateInfoNative(deviceIndex, /*type=*/1, timeMs)   // [实测]
```

设备索引固定为 `0=头盔`、`1=左手柄`、`2=右手柄`（`[实测]`，见三处 `const/4 v0, 0x1/0x2`）。

### 3.2 `Posture` 结构 `[实测]`

```java
public class Posture implements Parcelable {
    public float[] quat;   // 长度 4，顺序 (w, x, y, z)
    public float[] move;   // 长度 3，单位米；3DOF 时为占位
    public float[] acc;    // 长度 3
    public float[] gyro;   // 长度 3
    public float[] mag;    // 长度 3
}
```

**四元数顺序是 `(w, x, y, z)`，不是 Android 习惯的 `(x, y, z, w)`。** 证据有两条：

1. `ArvrRuntimeModuleManager.getHelmetPos` 的日志按 `quat[0]=qw, quat[1]=qx, quat[2]=qy, quat[3]=qz` 打印；
2. 同一方法的 3DOF 兜底分支把 `quat[0]` 置 `1.0f`、其余置 `0`，即单位四元数。

> 对接 `SensorManager.getQuaternionFromVector()`（返回 `x,y,z,w`）时**必须换序**。

### 3.3 `getData` 的返回数组 `[实测]`

```java
float[] out = new float[7];              // 静态复用，返回前 clone()
System.arraycopy(posture.quat, 0, out, 0, 4);
if (is6DofApp()) {
    System.arraycopy(posture.move, 0, out, 4, 3);
}
// 3DOF 时 out[4..6] 保持上一帧的值（初始化时为 0）
```

调用方约定：

| 模式 | 读取方式 |
| --- | --- |
| 3DOF | 只读 `out[0..3]`（`w,x,y,z`） |
| 6DOF | 读 `out[0..3]` 姿态 + `out[4..6]` 位置 |

### 3.4 模式选择 `[实测]`

```java
enum HelmetMod { NOLO_MOD, HW6DOF_MOD, HW3DOF_MOD }
```

- `isHW6DoFHeaderAvailable()` 为真，等价于识别到 `HUAWEI USB HELMET` 这个 USB 接口描述；
- 6DOF 应用（`is6DofApp()==true`）走 `ArvrRuntimeInternalInterface` 的 SLAM 姿态；
- 否则走 3DOF 融合，`move` 只做 `move[1] += 1.5f`（平面高度）的占位。

### 3.5 时间语义 `[实测]`

| 位置 | 单位 |
| --- | --- |
| `getData(long)` / `getHeadPose(long)` / `updateInfoNative(..., long)` | 毫秒（`System.currentTimeMillis()` 语义） |
| HID IMU 报文内时间戳 | float，**微秒**，使用时除以 `1e6` 得秒 |
| 6DOF 日志 `time_S/timeDisp/time_E` | 秒（double） |
| `VrPoseState::predictPose(double)` | 秒 |

**不要混用**。原厂在 Java 层用毫秒、在算法层用秒，桥接处做了换算。

---

## 4. 3DOF：从 HID 到四元数

### 4.1 头盔 HID 报文 `[实测]`

`libWalleDev.so` 的 `Walle::onGlassSensorEvent` 按首字节 tag 分派：

| tag | 含义 | 备注 |
| --- | --- | --- |
| 1 | 心跳 | |
| 2 | 异常 | |
| 3 | IMU | 本文重点 |
| 4 | 接近传感器 | |
| 5 | 手势 | |
| 7 | 充电 | |

IMU 报文：

```
偏移  长度  内容
0     1     tag = 3
1     12    acc[3]   float32 LE
13    12    gyro[3]  float32 LE
25    12    mag[3]   float32 LE
37    4     timestamp float32 LE，单位 µs
41    4     扩展/保留
总计  45 字节（payload 44 字节，`processImuEvent` 要求剩余长度 ≥ 0x2d）
```

解析要点 `[实测]`：

- `processImuEvent` 先做长度判定（阈值为 `0x2d` = 45 字节），再 `memcpy` 44 字节 payload；
- 三个向量各按 3 个 float 解析；
- 时间戳取 payload offset 36 的 float，除以 `1e6`；
- 结果写入 `DeviceData`：`+0x40 acc`、`+0x4c gyro`、`+0x58 mag`、`+0x68 time`、`+0x8c type=17`。

> `[未知]`：gyro 的单位（rad/s 还是 deg/s）、acc 是否已去重力、mag 的单位与轴向。
> 通用实现应当在启动时用「静止时 |acc| ≈ 9.81」和「绕轴转 90° 积分角度」来标定这两个量。

### 4.2 解析伪代码（可直接移植）

```java
// report[0] == 3
if (len >= 45) {
    float ax = leFloat(report, 1),  ay = leFloat(report, 5),  az = leFloat(report, 9);
    float gx = leFloat(report, 13), gy = leFloat(report, 17), gz = leFloat(report, 21);
    float mx = leFloat(report, 25), my = leFloat(report, 29), mz = leFloat(report, 33);
    double t = leFloat(report, 37) / 1e6;   // 秒
    fusion.onImu(ax, ay, az, gx, gy, gz, mx, my, mz, t);
}
```

### 4.3 `libWalleAlg.so` 的融合管线 `[实测方法名 + 推断顺序]`

`VrPoseState` 的公开方法（ARM64 地址为 `libWalleAlg.so` 内偏移）：

| 方法 | 地址 | 作用 |
| --- | --- | --- |
| `VrPoseState::calculatPose(IMUData&)` | `0x21b50` | 单帧融合入口 |
| `PoseWithTiltCalibration(ProcessedImuData&, const HistoryData&, VrQuaternion&, double)` | `0x22160` | 用重力修正 roll/pitch |
| `PoseWithMagCalibration(ProcessedImuData&, VrQuaternion&, double)` | `0x227bc` | 用磁北修正 yaw |
| `JudgeMagAccuracyLevel(ProcessedImuData&)` | `0x23428` | 磁力计可信度分级 |
| `VrMagStateJudge::MagAbnormalyDetect(...)` | `0x23e5c` | 磁异常检测（1060 字节） |
| `SetMagCorrectionWeakenRateFromMagState(...)` | `0x2326c` | 按磁状态调弱校正 |
| `calculateHorizonMagOrientation(VrVector3*, VrVector3*)` | `0x22e54` | 水平面磁方向 |
| `GetCorrectionScaleAndAngle(double&)` | `0x237e8` | 校正量 |
| `CalculateInitialPose(acc, mag)` | `0x22fb0` | 初始姿态 |
| `GetRotationQuaternion(VrVector3d, VrVector3d)` | `0x23048` | 由两向量求旋转 |
| `predictPose(double, VrQuaternion*)` | `0x22d44` | 外推 |
| `JudgeActivityLevel(acc, gyro)` | `0x22024` | 运动强度分级 |
| `SetPoseViaActivityLevel(double, VrQuaternion&, double)` | `0x23730` | 按运动强度调平滑 |
| `CheckBigDiffDuration()` | `0x23970` | 大偏差持续检测 |
| `VrQuaternion::nlerp` | `0x285b8`（float） | 归一化线性插值 |

可实现的等价管线：

```
onImu(acc, gyro, mag, dt):
    if not initialized:
        q = CalculateInitialPose(acc, mag)      # 重力定 tilt，磁北定 yaw
        initialized = true
        return

    gyro = GyroCalibrate(gyro)                  # 稳态检测 + 零偏更新
    q = q ⊗ exp(0.5 * gyro * dt)                # 机体角速度右乘
    q = TiltCorrect(q, acc, dt)                 # 低频把「测得的重力方向」拉回去

    level = JudgeMagAccuracyLevel(mag)
    if level is usable:
        q = MagCorrect(q, mag, dt * weakenRate(level))
    else:
        # 磁异常时只保留 yaw，不让异常磁场把姿态拽走
        q = KeepYawOnly(q)

    q = AdaptSmooth(q, JudgeActivityLevel(acc, gyro))
    q = normalize(q)
```

**为什么不是简单的互补滤波**：原厂把「磁异常检测」独立成了一个 1060 字节的函数，并在
`SetMagCorrectionWeakenRateFromMagState` 里按状态调弱。工程含义是：
磁力计在电机、金属桌面、地铁里会突然指错方向，必须**降权而不是直接信任**。

### 4.4 陀螺零偏与稳态 `[实测]`

`Gyro_Cali`（`libctrl3dof.so`，同一套思路）里的方法：

- `sf_steady_detection(float*, float*, float)` — 判断设备是否静止；
- `sf_update_gyro_offset(retGyroCali_t*, double)` — 静止时更新零偏；
- `sf_judge_activity_level(uint8_t, float)` — 活动等级。

`libWalleAlg` 侧对应 `JudgeActivityLevel` + `SetPoseViaActivityLevel`。实现建议：

```java
if (accelVariance < 0.01 && gyroMagnitude < 0.02) {
    gyroBias = lerp(gyroBias, gyro, 0.02f);   // 只在静止时学
}
```

### 4.5 磁力计处理 `[实测 + 推断]`

`VrMagStateJudge` 的方法名说明它判断三件事：

1. **模长**：`|mag|` 是否偏离当地地磁强度；
2. **方向**：与当前姿态预测的磁北夹角是否突变；
3. **ppvalue**：峰峰值（`MagPPvalueJudge`），即短时间内的抖动幅度。

`MagDistanceJudge` 与 `MagAbnormalyDetect` 组合出 `MAG_STATE`，再映射成校正权重。
`calculateHorizonMagOrientation` 只取水平分量，说明 **yaw 校正是在水平面做的**，
不会让磁力计影响 roll/pitch。

### 4.6 预测 `[实测签名 + 推断实现]`

```cpp
void VrPoseState::predictPose(double deltaSeconds, VrQuaternion* out);
void VrPoseState::predictPose(double deltaSeconds, VrPosture* out);
```

用途是**光子时间外推**（timewarp / late-latching）：拿到最新姿态后，按当前角速度
外推到「这一帧真正上屏的时刻」。

等价实现：

```java
// body 角速度 ω，外推 dt 秒
Quat dq = Quat.fromAxisAngle(ωx, ωy, ωz, |ω| * dt);  // 或小角度近似 exp(0.5ωdt)
out = normalize(q ⊗ dq);
```

原厂具体用的是常角速度还是带阻尼的模型 `[未知]`；示例 App 用常角速度 + 可配置的
`PREDICTION_MS`（默认 10ms）。

### 4.7 手机 IMU 回退：`libMobileSensor.so` `[实测]`

导入的全是 `ASensor*`：

```
ASensorManager_getInstanceForPackage
ASensorManager_getDefaultSensor
ASensorManager_createEventQueue
ASensorEventQueue_enableSensor / setEventRate / getEvents
```

说明它就是「用手机自己的 acc/gyro/mag 当作 3DOF 源」，通过 `vr_device` 插件接口
`mobile_sensor_start/stop/pause/resume/getData` 暴露给上层。日志里明确要求三颗传感器
同时存在：

```
mGyroSensor == nullptr || mAccSensor == nullptr || mMagSensor == nullptr
```

**通用实现**：`SensorManager` + `TYPE_GAME_ROTATION_VECTOR`（无磁，yaw 会漂但稳定）
优先；没有就 `TYPE_ROTATION_VECTOR`；再没有就用 `gyro + accel + mag` 自己融合。

### 4.8 手柄 3DOF：`libctrl3dof.so` `[实测]`

对外 C 接口（符号未剥离）：

```c
VrCtrl3Dof_Create(...);
VrCtrl3Dof_Init(...);
VrCtrl3Dof_Start(...);
VrCtrl3Dof_PushData(...);
VrCtrl3Dof_GetData(...);
VrCtrl3Dof_Deinit(...);
```

内部算法符号：

| 符号 | 作用 |
| --- | --- |
| `ctrl3Dof::PushSensorData(Ctrl3DofSensorEvent*)` | 传感器入队 |
| `ctrl3Dof::CalibrateImuData` | 标定 |
| `ctrl3Dof::Sensor_fusion` | 融合 |
| `Gyro_Cali::sf_gyro_calibration` | 陀螺零偏 |
| `Sensor_fusion::game_rotation_vector_AGE` | 加速度+陀螺（无磁） |
| `Sensor_fusion::geomagnetic_rotation_vector_AM` | 加速度+磁 |
| `Sf_magn::sf_magn_anomaly_judge` | 磁异常 |
| `DOEaG::FF_RLS` | 遗忘因子递推最小二乘（3352 字节） |
| `DOEaG::Quat2Mat` / `MatrixInv` / `ConvergeJudge` | 数学与收敛判定 |

`DOEaG` 很可能是「Directional / Optimal Estimation and Gravity」一类的姿态估计器，
用 RLS 在线拟合。**具体状态量与增益没有逐指令还原**，不要声称能 1:1 复刻。

### 4.9 最小可用 3DOF 实现（推荐给通用 App）

```java
// 1) 首选：系统融合
Sensor rv = sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR);
if (rv == null) rv = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
sm.registerListener(this, rv, 10_000);  // 100Hz

// 2) 回调
public void onSensorChanged(SensorEvent e) {
    float[] q = new float[4];
    SensorManager.getQuaternionFromVector(q, e.values);  // 返回 x,y,z,w
    pose.setQuat(q[3], q[0], q[1], q[2]);                // 转成 w,x,y,z
    pose.timestampNs = e.timestamp;
}

// 3) 渲染前外推
pose.predictTo(System.nanoTime() + 10_000_000L);
```

这条路的抖动比原厂算法大，但**行为正确、可移植、无私有依赖**。要更稳就加 §4.3 的
tilt/mag 校正与 §4.4 的零偏学习。

---

## 5. 6DOF

### 5.1 它是什么 `[实测]`

`libVR6Dof.so` 里同时出现：

- OpenCV 4.5.2（`calib3d/core/features2d/video/...`）；
- Ceres（优化）；
- `ImuPreProc`、`ImgPreProc`、`BlobDetection`、`PnpTrack`、`P3PSolver`、`PNPCalib`、
  `MTracker`、`PoseSmooth`、`Mapping`、`Reloc`、`VPS`；
- `HW_SLAM`、`ARVR_CONTROLLER` 两个命名空间。

所以它是**双目鱼眼相机 + IMU 的 VIO/SLAM**，并且带手柄的 PnP/P3P 跟踪、重定位、
视觉定位（VPS）和建图。不是「把加速度积分两次」。

### 5.2 导出接口 `[实测]`

```c
void* GetVR6DofInterface();   // libVR6Dof.so @0x14ba4c，返回 .data:0x636050
```

返回的是**静态结构体**，`+0x10` 起是函数指针表。逐一反汇编后确认的槽位：

| 槽位 | 地址 | 对应实现 |
| --- | --- | --- |
| 0 | `0x14ba58` | 输出数据类型转换（`outputDataType` 校验） |
| 1 | `0x14bad8` | 同上（未知类型报错） |
| 2 | `0x14bb94` | `HW_HANDLER_Create` |
| 3 | `0x14bd68` | `HW_HANDLER_Destroy` |
| 4 | `0x14be18` | `HW_HANDLER_Init` |
| 5 | `0x14bf8c` | `HW_HANDLER_Start` |
| 6 | `0x14c10c` | `HW_HANDLER_Pause` |
| 7 | `0x14c264` | `HW_HANDLER_Resume` |
| 8 | `0x14c3a4` | `HW_HANDLER_Stop` |
| 9 | `0x14c524` | `HW_HANDLER_Deinit` |
| 10 | `0x14c688` | `SetValue(key, value)` |
| 11 | `0x14c994` | `GetValue(key, value)` |
| 12 | `0x14cbc4` | 状态/指针检查（要求 RUNNING） |
| 13 | `0x14cc48` | `MemoryDeepAlloc` / 拷贝 |
| 14 | `0x14cccc` | `MemoryDeepFree` |
| 15 | `0x14cd20` | 收尾 |

**姿态不是通过一个 `GetPose()` 槽位拿的**，而是：

- `SetValue("SLAM_GET_POSE", ...)` / `GetValue(...)`（字符串表里有 `SLAM_GET_POSE`）；
- 或上层 `libruntime_service_module.so` 里的
  `SlamThread::GetPosture(SlamGetPoseInput_*)` /
  `SlamState::GetSlamPosture(HxrAlgorithmData*)`。

`[未知]`：`SetValue/GetValue` 的 key 全集与 value 的二进制布局没有逐字段确认。
实现时不要直接 `dlopen` 这个库来「白嫖」6DOF——它依赖相机标定、LED 布局、IMU 标定，
这些参数在 `InitPara` 里，缺一项就初始化失败。

### 5.3 初始化描述符 `[实测字符串]`

从日志格式串可以还原出 `HandlerInitParam` / `InitPara` 的字段：

```
InitPara.Camera.imageWidth
InitPara.Camera.imageheight
HandlerInitParam: camera num: %d
HandlerInitParam: camera[0] camera id / image height / width / stride / image type
HandlerInitParam: handler[0] imu param acc fps
HandlerInitParam: helmet imu num / type
HandlerInitParam: helmetCameraType
SetInitParam mHandlerNum %d mHelmetCamDeviceNum %d mHelmetImuNum %d
             mLedNum %d mBBoxNum %d mImgHeight %d mImgWidth %d
```

含义：初始化必须告诉算法**几路相机、每路的分辨率/stride/格式、几路 IMU 及其采样率、
头盔相机类型、LED 数、包围盒数**。这是典型的「标定文件 + 硬件描述」式接口。

### 5.4 输出 `[实测日志]`

```
GetPose succ, ctlId = %d, time_S = %f, timeDisp = %f, time_E = %f, POSE_VALID = %d,
  pose = %f %f %f,
  orientation = %f %f %f %f,
  velocity = %f %f %f,
  angularVelocity = %f %f %f,
  accelerated = %f %f %f,
  angularAccelerated = %f %f %f
```

即 6DOF 姿态至少包含：

| 字段 | 维度 | 单位 |
| --- | --- | --- |
| position | 3 | 米 |
| orientation | 4 | 四元数 |
| velocity | 3 | m/s |
| angularVelocity | 3 | rad/s |
| acceleration | 3 | m/s² |
| angularAcceleration | 3 | rad/s² |
| time / valid | 1+1 | 秒 / 布尔 |

`PoseSmooth::PredictDisplayPose` 说明**显示姿态是经过预测平滑的**，不是直接把 SLAM
输出丢给渲染。

### 5.5 通用 Android 上怎么办

| 方案 | 可行性 | 代价 |
| --- | --- | --- |
| `Sensor.TYPE_POSE_6DOF`（公开 API） | 高（看设备） | 设备厂商必须实现该 sensor HAL；无第三方依赖，坐标 frame 由厂商定义 |
| 直接复用 `libVR6Dof.so` | 低 | 需要华为相机 HAL、标定、LED 布局；ABI/依赖也重 |
| ARCore | 高 | 需要 Google Play for AR；室内平面/光照要求；华为设备通常没有 |
| 自建 VIO（ORB-SLAM3 / Kimera / OpenVINS） | 中 | 相机内参标定、IMU 时空对齐、工程量大 |
| 只有 IMU 的「伪 6DOF」 | 不可行 | 位置会指数漂移，不要宣传成 6DOF |

示例 App 的做法：`AutoPoseSource` 按
`TYPE_POSE_6DOF → /dev/hwvr1（眼镜 HID 3DOF）→ 手机 IMU（3DOF）` 自动选择，
不需要 UI 开关。`Pose6DofSensorSource` 是真正的 6DOF 适配器；没有
`TYPE_POSE_6DOF` 的设备会明确显示 `3DOF`，**不会**启用 `DemoSixDofProvider`
来假装位置跟踪。`DemoSixDofProvider` 仍保留，只作为渲染管线的教学/回放用例。

### 5.6 `TYPE_POSE_6DOF` 的事件与坐标 `[标准 API]`

```text
values[0..2]  四元数 x, y, z
values[3]     四元数 w
values[4..6]  平移 x, y, z，米，原点由厂商定义
values[7..10] 相对上一帧的增量四元数 x, y, z, w（可选）
values[11..13] 相对上一帧的增量平移（可选）
```

对接规则：

1. 四元数换序成 `(w,x,y,z)`；
2. 平移和旋转必须使用**同一个** world frame；`TYPE_POSE_6DOF` 的 frame 没有
   统一规定，可能是 ENU（Z-up），也可能是 ARCore 风格 Y-up；
3. 启动时用 `TYPE_GRAVITY` 求「传感器世界里的上方向」`q · g`，再用最短弧把它
   转到渲染 `+Y`。这一步同时兼容 Z-up 和 Y-up，代价是要求启动时设备基本静止；
4. recenter 同时清零 yaw 和位置；位置只用于相对走动，不依赖厂商原点的绝对值；
5. `TYPE_POSE_6DOF` 的标准事件没有速度字段，示例只预测旋转；位置不做外推，
   10ms 滞后在 1.5m/s 行走速度下约 1.5cm，可接受。

示例实现见 `sample-app/.../pose/Pose6DofSensorSource.java`，
自动选择见 `AutoPoseSource.java`。如果某台设备的旋转和平移不在同一 frame，
画面会出现「转头对、走动方向错」或整体倾斜；这不是融合器能修的，必须按
厂商文档改 `worldToRender`。

---

## 6. 投屏

### 6.1 原厂三层链路 `[实测]`

```
MainActivity（闸门：isVRMode() && 非默认屏）
  └─ AppDisplayManager.a(Context)
       └─ IVRSystemServiceManagerEx.createVrDisplay(
              "HW-VR-Virtual-Display-N-Src", int[3], context)
            int[3] = { 主屏宽, 主屏高, densityDpi }   // 由 getRealSize/getRealMetrics/getRotation 得到
  └─ CaptureDisplay (b/a/c/f/a0)
       SurfaceTexture + onFrameAvailable + updateTexImage
  └─ NativeLib (libxr_renderer.so)
       init(Context, Surface, w, h)
       prepareFrame()
       prepareSwapchain(Pose, view[16], proj[16], eye)   // eye: 0=左 1=右
       submitFrame()
```

注意：`createVrDisplay` 是**系统服务**能力，普通安装拿不到；`CaptureDisplay` 的
`AUTO_MIRROR` 也需要 `CAPTURE_VIDEO_OUTPUT`（signature|privileged）。这就是原版
必须有 root/系统签名的原因。

### 6.2 `createVrDisplay` 的参数 `[实测]`

```java
int[] params = new int[3];
Display.getRealSize(size);
params[0] = size.x;
params[1] = size.y;
DisplayMetrics dm = new DisplayMetrics();
Display.getRealMetrics(dm);
params[2] = dm.densityDpi;
// rotation 单独参与，见 b/a/c/f/z
IVRSystemServiceManagerEx.createVrDisplay("HW-VR-Virtual-Display-N-Src", params, ctx);
```

虚拟屏名字里的 `N` 是序号，`Src` 表示来源。`[未知]`：`createVrDisplay` 返回的
`IBinder`/`Display` 在系统侧的完整语义，以及是否支持多实例。

### 6.3 `libxr_renderer.so` 的内部结构 `[实测]`

这是一个**应用侧 OpenXR 渲染器**（约 97KB，`libxr_loader.so` 才是 Khronos loader）。
它导入的 OpenXR 函数覆盖了完整的一帧循环：

```
xrCreateInstance / xrGetSystem / xrCreateSession / xrBeginSession
xrEnumerateViewConfigurationViews / xrLocateViews
xrCreateSwapchain / xrEnumerateSwapchainImages
xrWaitFrame / xrBeginFrame / xrEndFrame
xrAcquireSwapchainImage / xrWaitSwapchainImage / xrReleaseSwapchainImage
xrCreateActionSet / xrCreateAction / xrSuggestInteractionProfileBindings
xrAttachSessionActionSets / xrSyncActions / xrLocateSpace
```

扩展：`XR_KHR_android_create_instance`、`XR_KHR_opengl_es_enable`、
`XR_HUAWEI_controller_interaction`。

类与职责：

| 类 | 关键方法 | 职责 |
| --- | --- | --- |
| `RenderManager` | `Init`、`InitOpenGl`、`InitOpenXr`、`PrepareFrame`、`PrepareSwapchain`、`SubmitFrame`、`ReleaseSwapchain`、`SetPoseData`、`GetHandlePose` | JNI 门面 |
| `EglManager` | `SetupEglEnv(ANativeWindow*)`、`EglChooseConfig`、`EglCreateContext` | EGL 初始化 |
| `XrManager` | `InitXrInstance`、`InitSystem`、`InitSession`、`InitLocalSpace`、`PollAndHandleEvents` | OpenXR 生命周期 |
| `XrRenderHelper` | `InitSwapchains`、`PrepareFrame`、`PrepareSwapchain`、`SubmitFrame` | 每眼视图与交换链 |
| `XrHandleHelper` | `InitActions`、`BindActionToProfile`、`CreateActionSpace`、`PollActions`、`GetHandlePose`、`IsHandleAlive` | 手柄动作与姿态 |

JNI 声明（`com.huawei.vrbase.NativeLib`）`[实测]`：

```java
static native int  init(Context ctx, Surface surface, int width, int height);
static native void prepareFrame();
static native void prepareSwapchain(Pose pose, float[] viewMatrix, float[] projMatrix, int eye);
static native void submitFrame();
static native void releaseSwapchain(int eye);
static native boolean supportMultiview();
static native void getHandlePose(Pose out);
static native boolean isHandleAlive();
static native void resetHandle(int hand);
static native void resetHelmet();
static native void requestExit(boolean flag);
static native int  processSdkEvents();
static native void pollHandleEvent(HandleEvent out);
static native void jumpVrLauncher();
static native boolean exitNativeEnv();

static final int RENDER_TYPE_VR_DEFAULT = 0;
static final int RENDER_TYPE_SINGLE_EYE  = 1;
static final int SIDE_LEFT  = 0;
static final int SIDE_RIGHT = 1;
```

`prepareSwapchain` 的语义（`b/a/c/k/c/c$c.a(I)`）`[实测]`：

```java
Pose pose = new Pose();
float[] view = new Matrix4().getArray();
float[] proj = new Matrix4().getArray();
NativeLib.prepareSwapchain(pose, view, proj, eye);   // native 填充三个输出
renderer.submit(poseMatrix, view, proj);             // 应用用这三个值画这一眼
NativeLib.releaseSwapchain(eye);
```

也就是说：**姿态、视图矩阵、投影矩阵都由 runtime 按 eye 给出**，应用不自己算 IPD/FOV。
投影矩阵由 `CreateProjectionMatrix(XrFov, near, far, ...)` 和
`UpdateMatrixByNearZAndFarZ` 生成，说明使用的是 OpenXR 的 `XrFovf`（非对称视锥）。

`[未知]`：`CreateProjectionMatrix` 内部的 depth range 约定（GL 的 `[-1,1]` 还是
Vulkan 的 `[0,1]`）与 `UpdateMatrixByNearZAndFarZ` 的具体修复项，没有逐指令确认。

### 6.4 免 root 投屏 `[实测 + Android 13 修正]`

下面是**修正后的目标管线**（示例 App 的 `MirrorGlView` 已按此实现）；
仓库里的 `HvrMirrorService` 目前仍是两路 `SurfaceView`，在 Android 13+ 上需要
按这一段改造：

```
Vr2dStartUpActivity
  → HvrMirrorEntry.start()
    → HvrMirrorActivity          系统录屏授权（透明主题）
      → HvrMirrorService         前台服务
        → MediaProjection.createVirtualDisplay(AUTO_MIRROR, SurfaceTexture)
        → 一个 GLSurfaceView 里左右眼各采样同一帧
```

**不要建两个 VirtualDisplay**：Android 13 起，同一个 `MediaProjection`
创建多个 `VirtualDisplay` 时只有最后创建的那块能出图；Android 14 进一步限制
token 复用。正确做法是**只建一个** VirtualDisplay 到 `SurfaceTexture`，
再把这一张外部纹理在左右两个 viewport 各画一次（示例见
`sample-app/.../cast/MirrorGlView.java`）。

| 能力 | 公开 API |
| --- | --- |
| 找副屏 | `DisplayManager.getDisplays()` / `DISPLAY_CATEGORY_PRESENTATION` |
| 录屏授权 | `MediaProjectionManager.createScreenCaptureIntent()` |
| 前台服务 | `startForeground(..., FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)` |
| 显示 | 副屏 `Context` 上的 `TYPE_APPLICATION_OVERLAY`，失败回退 `Presentation` |
| 镜像 | `MediaProjection.createVirtualDisplay(..., AUTO_MIRROR, surface, ...)` |

限制（必须写进任何对外说明）：

- 每次启动都要过一次系统录屏授权，免 root 无法绕过；
- 这是**平面镜像**：没有原版的立体渲染、畸变校正、timewarp、虚拟屏空间定位；
- 依赖眼镜以**独立副屏**出现。如果手机把眼镜当镜像屏（没有第二块 display），无解；
- 左右眼各一份画面是「同一张图放两遍」，不是真立体。

### 6.5 原版 vs 免 root 对照

| 维度 | 原版 `com.huawei.vrvirtualscreen` | 免 root `HvrMirrorService` |
| --- | --- | --- |
| 权限 | 系统签名 + `CAPTURE_VIDEO_OUTPUT` + VR 模式 | 录屏授权 + 悬浮窗 |
| 画面 | 立体、按 eye 提交、可畸变校正 | 平面镜像 ×2 |
| 延迟 | OpenXR 帧循环 + 预测 | MediaProjection 管线（更高） |
| 空间感 | 虚拟屏在 3D 空间里 | 贴在副屏上 |
| 可移植性 | 绑定华为系统 | 任何有副屏的 Android |

---

## 7. 复刻路线图（按可落地性排序）

### 阶段 A：3DOF + 外接屏立体渲染（1～2 天）

1. `SensorManager` 取 `TYPE_GAME_ROTATION_VECTOR`，转成 `(w,x,y,z)`；
2. 用 `Presentation` 把 `GLSurfaceView` 放到副屏；
3. 双目渲染：每眼 `view = T(-position) · Rᵀ · T(-eyeOffset)`（`eyeOffset = ±IPD/2`，在头坐标系），`proj = perspective(fovY, eyeAspect, near, far)`；
4. 加一个桶形畸变后处理 pass，`k1/k2` 可调；
5. 验收：转头时画面跟手，左右眼视差正确，无镜像/上下颠倒。

### 阶段 B：接华为眼镜 IMU（需要 root 或自建传输层）

1. 按 `docs/HELMET_HID_PROTOCOL.md` 打开 `/dev/hwvrN`，用 feature report 识别设备；
2. 按 §4.1 解析 tag=3 的 45 字节报文；
3. 把 acc/gyro/mag 喂给 §4.3 的融合器；
4. 先用「静止 |acc|≈9.81」标定 gyro 单位，再用 90° 旋转标定轴向；
5. 验收：与手机 IMU 对比，yaw 漂移更小、延迟更低。

### 阶段 C：6DOF（按设备能力）

1. 先接公开 `Sensor.TYPE_POSE_6DOF`：读 `values[0..3]` 四元数和
   `values[4..6]` 米制平移；用 `TYPE_GRAVITY` 自动对齐 Y-up；
2. 没有该 sensor 时接 ARCore：`Session.create` → `frame.getCamera().getPose()` →
   `frame.getTimestamp()` → 转成 `(w,x,y,z)` 与米制位置；
3. 注意 ARCore 是 **Y-up、右手、相机朝 -Z**，与本文的渲染坐标一致，但
   `Pose` 的平移是「相机在 world 中的位置」，视图矩阵要取逆；
4. 两者都没有时输出 3DOF；不要用 IMU 积分补位置；
5. 验收：走动时画面稳定，静止时不漂，重定位后不跳变。

### 阶段 D：投屏（独立于姿态）

1. 直接复用 `shared/java/.../mirror/` 的四个类；
2. 先跑通「副屏 + 平面镜像」，再决定要不要做立体化；
3. 验收：眼镜里出现手机画面，拔线/停止能正确释放 `VirtualDisplay`。

---

## 8. 示例 App 的映射

工程在 `sample-app/`，每个文件对应本文的一节：

| 文件 | 对应章节 | 说明 |
| --- | --- | --- |
| `pose/Quat.java` | §3.2、§4.6 | `(w,x,y,z)` 四元数、积分、外推、转矩阵 |
| `pose/Pose.java` | §3.2、§5.4 | 姿态 + 位置 + 角速度 + 时间戳 |
| `pose/PoseSource.java` | §4.7 | 姿态源接口 |
| `pose/PhoneSensorPoseSource.java` | §4.7 | 系统融合 / 原始传感器回退 |
| `pose/HeadPoseFusion.java` | §4.3、§4.4 | 陀螺积分 + 重力/磁校正 + 零偏学习 |
| `pose/WalleHidPoseSource.java` | §4.1、§4.2 | `/dev/hwvrN` 读取 + 45 字节解析（实验性） |
| `pose/Pose6DofSensorSource.java` | §5.6 | `TYPE_POSE_6DOF` + `TYPE_GRAVITY` auto-level（真 6DOF） |
| `pose/AutoPoseSource.java` | §5.5 | 自动选择 6DOF → HID → 手机，支持热切换 |
| `pose/SixDofProvider.java` | §5.5 | 6DOF 接入点 |
| `pose/DemoSixDofProvider.java` | §5.5 | 明确标注的演示实现（默认不参与自动选择） |
| `render/StereoRenderer.java` | §6.3、§7A | 双目 FBO + 畸变 + 预测 |
| `render/Scene.java` | §7A | 网格地面 + 柱体，用于判断朝向 |
| `render/LensProfile.java` | §6.3 | 畸变参数（华为真实参数未知） |
| `cast/MirrorService.java` | §6.4 | MediaProjection 镜像 + 前台服务 |
| `cast/MirrorGlView.java` | §6.4 | 单路 SurfaceTexture → 左右眼各画一次 |
| `cast/DisplayFinder.java` | §6.4 | 找副屏 |
| `MainActivity.java` | §7 | 自动上屏、投屏授权、生命周期 |

示例 App **不包含**华为私有库，也不声称能替代原版合成器。

---

## 9. 未确认清单（实现前必须知道）

| 项 | 已知 | 风险 | 建议验证方式 |
| --- | --- | --- | --- |
| IMU 报文 gyro 单位 | float32 ×3 | 差 57.3 倍会导致画面飞转 | 静止 + 匀速转 90°，比对积分角度 |
| IMU 报文 acc 是否含重力 | 3 个 float | tilt 校正方向反 | 平放时看 `|a|` 是否 ≈9.81 |
| IMU 报文轴向 | 未标注 | roll/pitch 互换 | 分别绕三轴转，观察对应分量 |
| `Posture.quat` 顺序 | `(w,x,y,z)` 已由单位四元数确认 | 换序错误 → 画面乱转 | 已确认，无需再验 |
| `VrPoseState` 具体增益/阈值 | 只有方法结构 | 无法 1:1 复刻手感 | 只能自己调参 |
| `predictPose` 模型 | 签名确认 | 预测过头会抖 | 用 0/5/10/15ms 扫参 |
| 48 字节光学信息 | 落点偏移 +184 | 拿不到真实畸变参数 | 逐字段对比不同固件 |
| 16 字节显示偏移 | 兼容层返回零 | 瞳距/光轴可能偏 | 真机对比 |
| `createVrDisplay` 系统语义 | 参数已确认 | 普通 App 不可用 | 只能系统签名验证 |
| `libxr_renderer` 深度范围 | 未逐指令确认 | 近远平面裁剪异常 | 看 `CreateProjectionMatrix` 反汇编 |
| 6DOF `SetValue/GetValue` key 布局 | 只有 `SLAM_GET_POSE` 等字符串 | 无法直接复用 | 需要完整标定与硬件 |
| `TYPE_POSE_6DOF` world frame | Android 标准只规定字段，不规定 frame | 旋转/平移轴不一致 → 画面倾斜或走动方向错 | 看 `TYPE_GRAVITY` 对齐结果；对比厂商文档 |
| `TYPE_POSE_6DOF` 设备可用性 | `getDefaultSensor` 可能返回 null | 直接降级 3DOF | 在目标机型上枚举 sensor 列表 |
| HID 报文扩展 4 字节 | 未使用 | 可能含状态位 | 记录原始报文比对 |

---

## 10. 坐标与单位速查

### 10.1 Android 传感器坐标 `[标准]`

```
设备坐标系（右手）：
  +X 屏幕右侧
  +Y 屏幕上方
  +Z 垂直屏幕向外（指向用户）

旋转矢量 / getRotationMatrixFromVector：
  R 把「设备坐标」转到「世界坐标」
  世界坐标 = East(X) / North(Y) / Up(Z)
  四元数 = (x, y, z, w)

TYPE_POSE_6DOF（API 24+）：
  values[0..3] = 四元数 x, y, z, w
  values[4..6] = 平移 x, y, z，米，原点由厂商定义
  world frame 可能是 Z-up，也可能是 Y-up；启动时用重力对齐到渲染 +Y
```

### 10.2 渲染坐标（本文与示例 App）

```
右手，Y-up：
  +X 右
  +Y 上
  -Z 前（相机看向 -Z，符合 OpenGL）
```

从传感器世界到渲染世界：

```
S = Rx(-90°)      // (x,y,z)_ENU → (x, z, -y)_render
q_render = S ⊗ q_sensor
view     = q_render⁻¹
```

设备在头显里的安装方向若不同（例如竖装、倒装），改 `S` 即可，不要改融合器。

### 10.3 单位

| 量 | 单位 |
| --- | --- |
| 四元数 | 无量纲，需归一化 |
| 角速度 | rad/s |
| 加速度 | m/s² |
| 位置 | m |
| 时间戳 | 秒（算法层）/ 毫秒（Java 层）/ 微秒（HID 报文字段） |
| 畸变系数 | 无量纲 |

### 10.4 常用常量

| 常量 | 建议值 | 说明 |
| --- | --- | --- |
| IPD | 0.063 m | 成人平均瞳距，可做成滑杆 |
| 近平面 | 0.05 m | 再小会有深度精度问题 |
| 远平面 | 100 m | |
| FOV（竖直） | 90° | 华为 CV10 的真实 FOV 未确认 |
| 预测时间 | 10 ms | 按设备延迟调 |
| 传感器速率 | 100 Hz | `SENSOR_DELAY_GAME` 约 50Hz，建议显式 `10_000` µs |

---

## 11. 给 AI 的最小上下文（复制用）

如果只需要「照着写一个能跑的 3DOF + 外接屏 Demo」：

1. 姿态：`TYPE_GAME_ROTATION_VECTOR` → `getQuaternionFromVector` → 换序成 `(w,x,y,z)`；
2. 视图：`view = T(-position) · Rᵀ · T(-eyeOffset)`，左右眼各一次；
3. 投影：`perspective(fovY=90°, aspect=(w/2)/h, near=0.05, far=100)`；
4. 显示：`DisplayManager` 找非默认屏 → `createDisplayContext` → `Presentation` + `GLSurfaceView`；
5. 畸变：全屏 pass，`scale = 1 + k1·r² + k2·r⁴`，采样左右半屏；
6. 预测：渲染前用角速度外推 10ms；
7. 投屏：`MediaProjection` → **一个** `VirtualDisplay` → `SurfaceTexture` → 左右眼各画一次（平面镜像，不是立体）。

如果还需要「华为眼镜的 IMU」：加 §4.1 的 45 字节解析 + §4.3 的融合器，
并接受 §9 里的未确认项。

如果还要「6DOF」：先查设备有没有 `Sensor.TYPE_POSE_6DOF`（公开 API，
`values[0..3]` 四元数 + `values[4..6]` 米制平移）；没有就接 ARCore 或自建 VIO，
不要从 IMU 硬凑。示例 App 的 `AutoPoseSource` 会自动做这个选择：
`TYPE_POSE_6DOF → 眼镜 HID 3DOF → 手机 IMU 3DOF`。
