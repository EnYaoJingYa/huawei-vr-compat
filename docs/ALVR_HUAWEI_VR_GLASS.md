# Huawei VR Glass 无线串流：ALVR 路线选型与落地

本文回答一个问题：**如果最终目标是“手机当 ALVR 客户端，串流到华为 VR Glass”，应该用哪套代码？**

结论先说：**用 [`LHT02/HuaweiVRGlass-ALVR`](https://github.com/LHT02/HuaweiVRGlass-ALVR)，不要继续把 `sample-app/` 改成 ALVR 客户端。** 前者已经完成 ALVR 协议、OpenXR 接入、HiSilicon 硬解、双目输出和 6DoF 手柄适配；后者只是姿态/投屏原理演示，两者不是同一层的东西。

> 附件 `HuaweiVRGlass-ALVR-main (1).zip` 是**源码**，不是可直接安装的成品。它包含 3DoF 模式、桌面投屏和变体打包脚本，但**不包含** `HuaweiVRGlass-ALVR-Android-v0.5.0.apk`、`libalvr_client_openxr.so`、华为私有 SDK/Loader/Bridge 文件。没有这些，源码本身不能直接出 APK。

---

## 1. 为什么不是 `sample-app/`

`sample-app/` 实现的是：

```text
Android 传感器 / TYPE_POSE_6DOF
        ↓
自绘 OpenGL ES 双目场景
        ↓
Presentation 到副屏
```

它**没有**实现：

- ALVR 控制通道（TCP 9943）与视频流通道；
- H.264/H.265 解码与时间戳/重投影队列；
- ALVR 的 tracking / input / haptic 数据包；
- OpenXR / Huawei VR Runtime 会话；
- SteamVR 驱动侧协议；
- 音频回传、手柄按键/扳机/摇杆。

把这些补进 `sample-app/` 等于重写一个 ALVR 客户端。正确做法是直接用已经开源的客户端，把 `sample-app/` 保留为“通用 Android 姿态/投屏演示”即可。

---

## 2. 上游项目是什么

`LHT02/HuaweiVRGlass-ALVR` 是基于 **ALVR v20.14.1** 的非官方华为专版，MIT 许可。它让华为手机运行 ALVR Android 客户端，把 PC 上的 SteamVR 画面、头部姿态、双手柄输入和音频通过局域网送到 Huawei VR Glass。

它已经处理了这些华为特有问题：

| 问题 | 处理 |
| --- | --- |
| 华为旧版 OpenXR Runtime / SDK Service | 接入 `com.huawei.hvrsdkserverapp`、旧 Loader、`LibUpdateClient.runUpdate()` |
| VR Activity / Launcher 生命周期 | 手机 2D 入口 + `com.huawei.android.vr.action.MAIN` VR Activity |
| 眼镜显示方向 | 保留 Runtime 所需的每眼 90° 物理方向，单独修 Y 轴镜像 |
| FOV 偏广 | 保留 Runtime 原始 95°×95°，不用通用倾斜视锥扩张 |
| HiSilicon 解码 | 优先 `OMX.hisi.video.decoder.avc`，软件回退 |
| 解码时间戳错位 | 从 Surface 时间戳反推 ALVR PTS，修复重投影方向/裁剪/抖动 |
| 6DoF 手柄 | 左右手独立 Pose Action，按键/扳机/握把/振动 |
| 摇杆范围 | 华为 0～1、中心 0.5 → -1～1，Y 修正 + 0.12 圆形死区 |
| 返回 Glass Home | 停止串流并退出进程 |

### 已验证环境

| 项目 | 值 |
| --- | --- |
| 手机 | HUAWEI LYA-AL00 |
| 系统 | HarmonyOS 4.2（Android 10 / API 29 基础） |
| 眼镜 | HUAWEI GLASS CV10 |
| 手柄 | Huawei 6DoF Gaming Kit |
| 显示 | 3200×1600 总分辨率，70 Hz |
| Runtime 视图 | 1552×1552/眼，95°×95° FOV，63 mm IPD |
| Android | ARMv7，minSdk 26，targetSdk 28（Huawei 兼容） |
| PC | Windows 10/11 x64 + SteamVR |
| 网络 | 同一局域网，5 GHz Wi-Fi；TCP 已验证 |

> 这是“已验证环境”，不是“所有华为机型都保证”。其他手机、Runtime 版本或 6DoF 套装需要自行验证。

---

## 3. 发布包与安装

当前稳定版：**Huawei VR Glass ALVR v0.5.0**。

| 平台 | 文件 | 大小 | SHA-256 |
| --- | --- | ---: | --- |
| Android / HarmonyOS | `HuaweiVRGlass-ALVR-Android-v0.5.0.apk` | 19,551,729 B | `EA8EA7DFE02D34B25AADACC13E456844E25BAD4528806FC8CBFF0853F22574DA` |
| Windows PC | `HuaweiVRGlass-ALVR-Windows-v0.5.0.zip` | 40,684,854 B | `E56CC847B00B9BF5E81C9EC47586A5A3F49C74BFF7252203B759A7EE8D4E5540` |

下载页：<https://github.com/LHT02/HuaweiVRGlass-ALVR/releases/tag/huawei-vr-glass-v0.5.0>

### 3.1 PC 端

1. 完整解压 Windows ZIP，不要直接在压缩包里运行。
2. 启动 `ALVR Dashboard.exe`。
3. 在“安装”页注册 SteamVR 驱动；如果之前装过旧 ALVR 驱动，先移除再注册。
4. 启动 SteamVR。首次启动后可能需要重新打开 Dashboard。
5. 修改分辨率/刷新率/编码器后，重启 SteamVR 才会完全生效。

### 3.2 手机端

1. **先拔下 VR Glass**，在手机屏幕上安装 APK 并授予存储权限。
2. 手机和 PC 连同一局域网；推荐 PC 网线、手机 5 GHz Wi-Fi。
3. 打开 App，点击“连接眼镜并进入 VR”，再插入 VR Glass。
4. 按 Huawei VR Launcher 提示完成空间确认，从 Glass Home 手动进入本应用。
5. 在 Dashboard 的“设备”页信任手机；连接成功后 SteamVR 应出现头显和两只手柄。

> 不要用 ADB 强制启动 VR Activity：可能把手机 2D 界面投到眼镜。安装/授权也建议在拔下眼镜时完成。

### 3.3 推荐初始配置

| 设置 | 值 |
| --- | --- |
| 编解码单眼分辨率 | Runtime 推荐 `1.0×`（当前设备对齐后 1536×1536） |
| SteamVR 模拟头显单眼分辨率 | 同上 |
| 首选刷新率 | 72 Hz（Runtime 实际 70 Hz，自动取最近值） |
| 编解码器 | H.264，优先 HiSilicon 硬解 |
| 码率 | 14 Mbps 起步 |
| 网络协议 | TCP |
| 客户端缓冲 | 1 帧 |
| PC 待发送队列 | 1 帧 |
| 固定注视点编码 | 关闭 |

性能不足时，可把“编解码单眼分辨率”改为 896×896/眼，同时让“模拟头显分辨率”保持 `1.0×`，以保留正确 FOV 和几何关系。

---

## 4. 3DOF / 6DOF 的真实边界

这是最容易走错的一节。

### 4.1 上游 v0.5.0：默认是 6DoF 会话

上游 APK 的 Manifest 固定为：

```xml
<meta-data android:name="com.huawei.vr.application.freeDegree" android:value="6dof" />
```

所以：

- 有 Huawei 6DoF Gaming Kit 时：按上游说明使用，双手柄 6DoF、按键/扳机/摇杆可用。
- **没有 6DoF 套件时：上游 v0.5.0 可能无法进入应用**，这是已知问题，不是安装错误：
  - <https://github.com/LHT02/HuaweiVRGlass-ALVR/issues/1>
  - 维护者回复“可能会晚些更新”。

不要在 `sample-app/` 里找开关：`sample-app/` 的 `TYPE_POSE_6DOF` 和 ALVR 的 Huawei Runtime 会话是两条完全不同的路径。

### 4.2 社区 3DOF / Steam Deck 分支

有人做了实验分支：

- <https://github.com/niceqwer55555/HuaweiVRGlass-ALVR>
- 对应 issue：<https://github.com/LHT02/HuaweiVRGlass-ALVR/issues/2>

该分支增加了：

- 服务端 `ThreeDofMode::Auto/On/Off`：检测不到真实 6DoF 手柄位置时，把头部锁在固定眼高；
- 3DoF 手柄位姿锚定到头前，避免 SteamVR 菜单/手柄掉到脚下；
- 按 APK 声明的 `freeDegree` 只绑定单一 Huawei interaction profile；
- 3DoF/6DoF 两个 APK 变体打包脚本；
- 35 Hz / 1600×1600 等 Steam Deck 软编参数。

但要注意：

- 附件源码是实验分支，**没有发布现成 APK**，只有源码；
- 构建仍依赖 Huawei 私有 SDK/Runtime 文件、Rust、NDK、JDK 17；
- 分支作者记录过“重编 `libalvr_client_openxr.so` 与官方 .so 不等价”的坑，直接拿重编库可能黑屏/卡帧；
- 最稳妥的已知组合仍是“官方 .so + 6dof Manifest + 新版服务端 Auto 3DoF”，而不是简单把 Manifest 改成 3dof。

因此：

| 你的设备 | 建议 |
| --- | --- |
| 有 Huawei 6DoF Gaming Kit | 直接用上游 v0.5.0 |
| 只有 3DoF 眼镜/遥控器，无套件 | 先评估 `niceqwer55555` 分支；不要期待上游 v0.5.0 直接可用 |
| 只想在普通 Android 上验证姿态/投屏 | 用本仓库 `sample-app/` |
| 想从零写 ALVR 客户端 | 不建议；直接基于上游 fork |

### 4.2.1 附件源码里的 3DoF 与桌面投屏

附件里的 `docs/Huawei-3DoF串流与投屏.md` 写的是同一套思路，但更具体：

**附件源码的完整 3DoF 方案是双端处理**：

1. **客户端**：APK 的 `com.huawei.vr.application.freeDegree` 决定 Runtime 给不给位置。`3dof` 只给旋转；`6dof` 给 6DoF 套件会话。
2. **服务端**：Dashboard 打开「头显 → 3DoF mode」。客户端把头部位置压成 `(0, eye_height, 0)`、线速度清零，保留角速度；服务端在 recenter 后再对 `HEAD_ID` 做一次同样处理。手柄/身体跟踪点不动，保持 6DoF。
3. **参数**：`Eye height` 默认 1.6 m；坐姿可调 1.2 m；`Prefer runtime height` 默认开（Runtime 报的高度 > 0.2 m 时优先用它）。
4. **验证**：`session_log.txt` 里头 `pose.position` 恒为 `(0, height, 0)`，转头正常、走动不跟随。

> 官方 v0.5.0 的 Windows 包**没有**「3DoF mode」开关；这个开关属于附件源码的 Windows 构建。只有官方 PC 包时，只能打 `3dof` Manifest，靠 Runtime 本身只给旋转；要服务端强制锁头，必须用附件源码重编 Windows 包。

**关键坑（务必先看）**：

- 原版 `libalvr_client_openxr.so` 只认 `/interaction_profiles/huawei/6dof_controller`。把 Manifest 改成 `3dof` 后，Runtime 对应的是 `/huawei/controller`，原版 .so 没有这个 profile，**手柄按键/扳机会全部失效**。
- 所以：
  - **只需要头部 3DoF、不要手柄**：可以打 `3dof` Manifest 变体。
  - **要手柄按键/扳机**：保留 `6dof` Manifest，只开 Dashboard 的 3DoF mode（服务端 Auto 3DoF）。这也是附件作者验证过的最稳组合。
  - **不要同时建议两个 profile**：会在 `libvrsdk.so!hxrFindProfileForDevice` 崩溃。
- 变体打包脚本在附件里：
  - `scripts/huawei/package-huawei-activity.ps1 -FreeDegree 3dof`（从 native 库重新打包）
  - `scripts/huawei/package-huawei-variants.ps1`（同一 .so 生成 3dof/6dof 两个变体）
  - `scripts/huawei/patch_apk_3dof.py`（只改已有 APK 的 Manifest，最快但会丢手柄）
- 本仓库另提供 [`tools/alvr/patch-alvr-apk.ps1`](../tools/alvr/patch-alvr-apk.ps1)，可对已有 APK 做 Manifest 替换、zipalign 和重签，适合你手头已经有 v0.5.0 APK 的情况。

**桌面投屏**（附件新增，和 3DoF 独立）：

- Dashboard：「头显 → Desktop cast mode」；可设显示器序号、屏幕大小、左右眼水平偏移、采集帧率。
- 走服务端 DXGI Output Duplication，不需要运行 VR 游戏；修改后要重启 SteamVR。
- DXGI 同一时刻只允许一个捕获客户端，开投屏前关掉 OBS/远程桌面等占用者。

### 4.3 为什么不能把 `TYPE_POSE_6DOF` 塞进 ALVR

ALVR 的头部/手柄姿态来自 **Huawei VR Runtime 的 OpenXR action/pose**，不是 Android `SensorManager`。把 `TYPE_POSE_6DOF` 直接喂给 ALVR 会绕过 Runtime 的坐标系、预测、手柄 action 和 SteamVR 驱动，最后得到的是“另一个姿态源”，不是 ALVR 会话的一部分。除非重写客户端 tracking 层，否则不要混用。

---

## 5. 从源码构建（仅在你需要改客户端时）

上游脚本：

```powershell
pwsh -NoProfile -File .\scripts\huawei\build-android.ps1 -Configuration Release -SkipToolInstall
pwsh -NoProfile -File .\scripts\huawei\build-windows.ps1 -Configuration Release
```

构建前置：

- Windows PowerShell 7（`pwsh`）；
- Android SDK + **NDK 26.1.10909125**；
- JDK 17；
- Rust + `armv7-linux-androideabi` target + `cargo-apk`；
- Huawei OpenXR SDK 3.5.0.79 的 `libxr_loader.so`、`hvrbridge.jar`；
- Huawei VR SDK 3.5 的 `hvrprompt.aar`；
- 仓库外的 `sdk/` 目录布局（脚本会校验 SHA-256）。

华为官方 SDK 原始包、签名文件、构建产物、设备日志和本机 `session.json` 不应提交到 Git。公开或商业再分发前要单独核对华为 SDK/Runtime 许可。

> 本机当前没有 Rust/NDK/华为私有 SDK，所以没有在本仓库内重编这个 APK；直接使用 v0.5.0 发布包即可。

### 5.1 已有官方 APK：打 3DoF 变体（不需要 Rust/NDK）

如果你已经从 Release 下载了 `HuaweiVRGlass-ALVR-Android-v0.5.0.apk`，只想改会话自由度，可以用本仓库的脚本：

```powershell
# 仅头部 3DoF、不要求手柄按键；会改 Manifest 并重签
powershell -ExecutionPolicy Bypass -File .\tools\alvr\patch-alvr-apk.ps1 `
  -BaseApk .\build\HuaweiVRGlass-ALVR-Android-v0.5.0.apk `
  -ManifestValue 3dof `
  -ExpectedSha256 EA8EA7DFE02D34B25AADACC13E456844E25BAD4528806FC8CBFF0853F22574DA
```

输出默认在 `build/HuaweiVRGlass-ALVR-Android-v0.5.0-3dof.apk`，并自动做 `zipalign -p 4`、APK v1/v2/v3 签名和 `apksigner verify`。

**要保留手柄按键**时不要用 `-ManifestValue 3dof`：

```powershell
# 只重签，不改 Manifest；然后在 Dashboard 开「头显 → 3DoF mode」
powershell -ExecutionPolicy Bypass -File .\tools\alvr\patch-alvr-apk.ps1 `
  -BaseApk .\build\HuaweiVRGlass-ALVR-Android-v0.5.0.apk `
  -ManifestValue none
```

注意：

- 重签用的是本仓库 `signing/hvr-compat-debug.jks`（alias `hvrcompat`，口令 `android`），**和官方 APK 签名不同**。如果手机已装官方包，先卸载再装；否则会报签名冲突。
- 3DoF Manifest 变体下，原版 .so 找不到 `/huawei/controller` profile，手柄按键/扳机会失效；这是 Runtime/profile 限制，不是签名问题。
- 想同时保留手柄按键和 3DoF 头部，正确组合是 **6dof Manifest + Dashboard 3DoF mode**（服务端 Auto 3DoF），不是改 Manifest；该 Dashboard 开关需要附件源码的 Windows 构建。
- 需要可更新覆盖官方包的版本时，必须用官方签名密钥重签；本仓库不持有该密钥。

---

## 6. 常见问题

| 现象 | 处理 |
| --- | --- |
| Dashboard 发现不了手机 | 同一局域网、Windows 防火墙、SteamVR 已启动；设备页手动添加手机 IP |
| 新旧版本提示不匹配 | 客户端和 PC 包尽量用同一发行版；专版只放宽版本字符串，不保证协议结构兼容 |
| 安装一直阻塞 | 拔下 VR Glass，在手机屏幕完成安装/授权，再插回 |
| 眼镜黑屏 | 确认 Huawei VR SDK Service、VR Launcher、线缆正常；从 Glass Home 手动启动，不要 ADB 强开 |
| 间歇蓝屏/花屏 | H.264、关闭 FFE、降低码率/分辨率；确认使用 v0.4.0+ 的时间戳修复 |
| 画面固定、头转不跟 | 用包含 HiSilicon 时间戳重同步修复的版本；不要混用旧 APK |
| 画面偏广角/变形 | 确认客户端上报原始 95° FOV；SteamVR 里清掉旧驱动配置 |
| 只有一只手柄有位置 | 用专版 Huawei OpenXR Pose Action；重新连接双手柄并做空间确认 |
| 摇杆静置有输入 | 新版已做 0.5 中心化 + 0.12 死区；仍漂移就检查手柄/固件 |
| 返回 Home 后进程还在 | v0.4.0 已修；仍复现就记录 APK 版本 + `adb logcat` |
| ADB 被眼镜占用 | 先 USB `adb tcpip 5555`，再切 USB-C 给眼镜 |

---

## 7. 和本仓库其它文档的关系

- 本仓库 `docs/AI_VR_DRIVER_AND_CASTING.md`：解释华为原厂姿态/投屏链路、`Posture` 约定、3DOF/6DOF 证据和通用 Android 复刻边界。
- 本仓库 `sample-app/`：演示“通用 Android 上能复刻的那部分”，不是 ALVR 客户端。
- 本仓库 `tools/alvr/`：对已有 ALVR APK 做 3DoF/6DoF Manifest 变体、zipalign 和重签；不包含 native 库或 Huawei SDK。
- 附件 `HuaweiVRGlass-ALVR-main (1).zip`：3DoF/桌面投屏源码；打包与验证细节见其中的 `docs/Huawei-3DoF串流与投屏.md`。
- 本文：说明实际无线串流应使用哪个开源客户端，以及 3DOF/6DOF 的选型边界。

一句话：**ALVR 串流走 LHT02 项目；3DoF 变体用 `tools/alvr/` 或附件源码打包；`sample-app/` 只做原理验证和通用 Android 备用演示。**
