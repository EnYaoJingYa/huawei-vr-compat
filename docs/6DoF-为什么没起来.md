# 6DoF 为什么没起来：现场诊断

> 采集时间：2026-11-01 21:30–21:40　设备：ELE-AL00 / EMUI 11.0.0.155
> 硬件：CV10 眼镜 + 6DoF Gaming Kit Par-CG012（Omnivision）+ CF20 手柄

## 一句话结论

**6DoF 摄像头模组只枚举出「UVC 控制接口」，没有「视频流接口」**。手机拿不到双目画面，算法自然出不了位姿，设备表凑不齐 3 个（头 + 左 + 右），于是头显和双手的 6DoF 一起被判 false。

## 一、现场硬证据

### 1. USB 设备树（`dumpsys usb`）

```
/dev/bus/usb/002/012   12D1:3A09  6DoF Gaming Kit Par-CG012   Omnivision
  class=239(0xEF) subclass=2 protocol=1        ← IAD 复合设备
  max_power=500mA   serial=OV0001   version=1.00
  interfaces = {
      id=0  class=14(0x0E) subclass=1 protocol=0   ← 只有 VideoControl
  }
```

对比正常 UVC 摄像头必须成对出现的两个接口：

| 接口 | 用途 | 本机 |
|---|---|---|
| class 0x0E / sub 0x01 | VideoControl（能力协商、曝光、格式枚举） | ✅ 有 |
| class 0x0E / sub 0x02 | **VideoStreaming（真正的图像流）** | ❌ **没有** |

同一根总线上另外两个设备是完整的：

```
/dev/bus/usb/002/011   12D1:107E  HUAWEI GLASS HID   5 个接口(255/19/18, 255/19/19, 255/19/6, 3/0/0, 3/0/1)
/dev/bus/usb/002/010   12D1:1092  HUAWEI GLASS CV10  音频接口 1/1/0、1/2/0(alt 0/1)…
```

### 2. 没有任何 6DoF 的 video 节点

```
/dev/video0..video4   共 5 个 —— 全部是手机自带的，开机即存在
6DoF 模组没有产生新的 /dev/video*
```

`vrglass.xml` 里算法要的是 `CameraNum="2"`（imx600，640×480@15Hz 双目标定），模型是 `SDmmm1_fp16_480_640.om`。**没有 VS 接口 = 没有 video 节点 = 算法没有输入**。

### 3. USB 在反复重新枚举

`dumpsys usb` 里同一批设备的地址从 `002/003`、`002/004`、`002/005` 一路涨到 `002/010`、`002/011`、`002/012`。设备地址单调递增说明主机侧不断重新枚举 —— 典型的**供电不足 / 带宽不够 / 模组自身重启**。

模组 `max_power=500mA`，是 USB2 的单口上限；眼镜和 HID 再各要一份，同时工作时余量很小。

### 4. 上层应用的报错

```
I/VrParamsRequester(20819): Huawei 6Dof Header is false
I/VrParamsRequester(20819): Huawei 6Dof left controller is false And right controller is false
E/VrHelmetExt(20819):        mVRDeviceExt is null          ← 每帧刷屏
```

- `VrParamsRequester.isHW6DoFAvailable()`（`com.huawei.hvrsdkserverapp`）：`getCurrentDevices()` 必须**正好返回 3 个**，且 `DeviceInfo.getDeviceState()==1`。设备表不齐 → 头显一起判 false。
- `mVRDeviceExt is null` 来自 `ThirdPartyController`。它靠 `VrInteractiveDeviceManager` 接第三方方案，而 `whitelist.json` 指定的正是 `com.nolovr.nolohome.huawei`（`HuaWeiService`，本机已装 1.5.066，`:core` 进程在跑）。这条侧路也没建立起来。

### 5. SELinux 还挡了一刀

```
avc: denied { write } for pid=20819 comm="wei.vrlauncherx"
  name="com.huawei.hvrsdkserverapp-...==" tclass=dir
```

`vrlauncherx` 想写 `hvrsdkserverapp` 的数据目录被拒。不是主因，但会让回退路径也断掉。

## 二、为什么模组只出控制接口

线缆（**C-V10-Cable-C2C01**，内含 VLI USB Hub 芯片）固件版本不达标。

反编译 `com.huawei.vrhandle` 的 `g1/r.smali`：

```
const-string v0, "Now you are using firmware above 47, but the cable is not support connecting two side"
```

含义：**老线缆的 Hub 固件不支持「同时连接两侧设备」**。眼镜 + 6DoF 模组一起挂上去时，Hub 只能保一路正常工作 —— 模组就停在"只报描述符、不启动视频流"的状态，并反复掉线重连。

版本号格式是 4 段十六进制，代码里的目标值：

```
const-string v5, "35.59.d.a0"      ← 期望版本
```

同一文件还调 `getVliFwVersion()` 读取线缆实际固件版本，比较不过就不走升级、直接 return（并打上面那条日志）。

所以华为的流程先弹 **`CableActivity`「数据线 · 检查和更新」**，要求"用 VR Glass 手机数据线、单独插进手机、**不接眼镜**、电量 >30%"——就是先把线缆固件刷上去，才谈得上双设备同时工作。

## 三、因果链

```
线缆 Hub 固件版本低（< 支持双面连接的版本）
        │
        ├─► 无法同时为「眼镜 + 6DoF 模组」提供通路/供电
        │         │
        │         └─► 模组反复重枚举（002/003 → 002/012）
        │             且只暴露 UVC VideoControl，无 VideoStreaming
        │                    │
        │                    └─► 无 /dev/video 节点
        │                          → HAL 拿不到双目图像
        │                          → getCurrentDevices() ≠ 3
        │                          → isHW6DoFAvailable = false
        │                          → Header / left / right 全 false
        │
        └─► vrhandle 检测到线缆版本不达标
                  └─► 自动拉起 CableActivity 要求先升级
```

## 四、验证与推进顺序

1. **先按提示升级线缆固件**
   - 只插数据线（不接眼镜），电量和网络就绪
   - 升级完成后重插全套，观察是否还有 CableActivity

2. **升级后复查以下几项**

```bash
adb shell dumpsys usb | grep -A4 "3A09\|6DoF Gaming"     # 看 interfaces 里是否出现 class=14 subclass=2
adb shell ls /dev/video*                                  # 是否多出 6DoF 的节点
adb shell logcat -s VrParamsRequester                     # 是否变成 Header is true
adb shell getprop sys.glass.state; getprop hw.vr.environment.status
```

3. **如果线缆无法升级**（版本已是最新、或刷不进）
   - 说明这条"双设备同挂"通路在本硬件上走不通，就不要在华为原厂链路上继续投入
   - 自研路线改用 **Camera2 直接打开模组的 UVC 双摄 + 自建 VIO**，绕开 VLI Hub 的带宽限制（但前提是模组能单独挂载并出 VS 接口 —— 单独插模组可以验证）

## 五、顺带澄清的两点

- **vrhandle 只管 3DoF 手柄**（代码里按 BLE 名 `contains("CF20_3DOF")` 过滤），CF20 走私有 GATT `622f5b2a` / `ffb4a651`。我们自己写的 `ControllerLink` 就是它的驱动。
- **6DoF 手柄不走蓝牙**：`hvrsdkserverapp` 整个包里没有任何 `BluetoothGatt` / `BluetoothLeScanner` 代码。手柄数据由 OV 模组经 USB 统一转上来，手机蓝牙开关与 6DoF 无关（只影响 CF20）。

---

# 附：那为什么「升级鸿蒙 2 就行了」？

这是一个必须回答的反问 —— 如果根因是线缆固件，凭什么换个系统就能解决？

## 实测：EMUI 11 与鸿蒙 2 的 VR 软件栈是同一套

把设备（EMUI 11.0.0.155）上的库和鸿蒙 2 包（2.0.0.171）里的同名文件做哈希比对：

| 文件 | 设备 EMUI 11 | 鸿蒙 2 包 | 结果 |
|---|---|---|---|
| `vendor.huawei.hardware.hivrar@2.0.so` | `0a4747b9…` | `0a4747b9…` | **完全相同** |
| `vendor.huawei.hardware.hivrar@2.1.so` | `96f1a74e…` | `96f1a74e…` | **完全相同** |
| `vendor.huawei.hardware.hivrar@2.2.so` | `c9a99a98…` | `c9a99a98…` | **完全相同** |
| `libhivrar_service.so` | `7aa719b5…` 528272 B | `69da6e7d…` 528280 B | 差 8 字节 |

`libhivrar_service.so` 再逐条比字符串：1681 vs 1682 条，**唯一差异**是
`_ZNK7android6Parcel26readOutVectorSizeWithCheckEmPi` —— 一个 Android 11 才有的 binder 符号，
属于编译工具链差异，与 VR 功能无关。`IHiARCamera`、`V2_2` 等关键符号两边都在。

**结论：EMUI 11.0.0.155 的设备上，VR 软件栈已经就是鸿蒙 2.0.0.171 那一套。
「升级系统 → 系统获得 6DoF 能力」在软件层不成立。**

## 那升级为什么真的能好？

因为升级解开的不是「软件能力」，而是**配件固件的升级通道**。

证据：

1. `com.huawei.vrhandle` 的 APK 里（863 个条目）**没有任何固件 bin** —— 线缆固件不是内置的。
2. 线缆版本走**服务端查询**：`CableServerVersionInfo` + 字符串 `check_new_version` / `version_info`，
   由服务器按机型、系统版本下发对应固件。
3. 现场卡点正是 `CableActivity`（线缆版本不达标），而 `g1/r.smali` 写明老 Hub 固件
   「不支持同时连接两侧设备」。

所以链路是：

```
EMUI 11（老 vrhandle / 服务器不下发）
        │  线缆固件刷不上去
        ▼
升级鸿蒙 2 → vrhandle 随 OTA 更新 → 向服务器查 version_info 拿到新固件
        │
        ▼
线缆 Hub 固件刷成功 → 支持「眼镜 + 6DoF 模组」双挂
        │
        ▼
模组正常出 VideoStreaming → /dev/video 出现节点 → 6DoF 才是 true
```

**升级系统是「手段」，线缆固件被刷上去才是「原因」。** 两者容易混为一谈。

## 升级后必须验证这一条

```bash
adb shell dumpsys usb | grep -A6 "6DoF Gaming"
```

看 interfaces 里**有没有多出 `class=14 subclass=2`（VideoStreaming）**：

- **多出来了** → 证明是视频流通路被打通，与系统 API 无关，这个解释成立
- **没多出来但 6DoF 变 true** → 那说明软件路径另有变化，需要重新分析（可能性较低，因为 VR 栈哈希一致）

另一种次要可能：鸿蒙 2 的 USB 供配电/带宽策略更宽松，让这个要 500mA 的模组能稳定工作，
不再反复重枚举。同属「系统间接影响」，但不是 VR 组件本身变了。

## 对自研路线的一句话

**别指望系统版本。看 `/dev/video` 有没有 6DoF 的节点，这是唯一硬指标。**
没有节点，上层任何软件都无从下手；自研的第一步永远是让模组单独挂载并真的吐出 VideoStreaming。

---

## 2026-11-01 订正：上面「线缆固件被刷上去」这条解释站不住了

实测三件事，把原来的假设推翻了一半：

1. **线缆固件早就是新的**
   logcat 实测 `getVersionNameHex final : c.9.52.6` → Firmware 字段 = `52`，
   `52 > 47`，已经越过 `g1/r` 里那个「above 47」的门槛。
   且日志里**没有**出现 `not support connecting two side`，说明 hub 能力位认为「支持双挂」。

2. **服务端没有更新的包**
   把 `CheckEx` 请求原样复刻后横扫版本：
   `Firmware=0/1/47/51/52/99` 全部返回 `{"status":"1"}`（= 已是最新），`components` 始终缺失。
   App 自己的 UI 也判 `PAGE_VERSION_NEWEST` / `DETAILED_LOCAL_LATEST`。
   → 不是「新系统解开了升级通道」，是**这条 OTA 早就没货了**。

3. **线缆当前以 Billboard 枚举，下游压根没出来**
   只插线缆时 `dumpsys usb` 只有 `2109:0105 class=17 USB 2.0 BILLBOARD`，`num_connects=139`。
   没有 `class=9`(hub)、没有 `class=14`(video)，`12d1:3a09` 也不在。

**所以「升级鸿蒙 2 就好」如果为真，更可能的原因在显示/供电侧**（DM 的 DP Alt Mode 通道与 USB 带宽分配策略），
而不是配件固件版本 —— 因为固件已经是 52，服务端也没有 53。

详见 [`线缆固件OTA-能不能骗.md`](./线缆固件OTA-能不能骗.md)，复验脚本 `tools/cable-ota-check.py`。
