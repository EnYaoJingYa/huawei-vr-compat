# 免 root 投屏（MediaProjection → 眼镜副屏）

## 为什么原来的投屏链路必须有 root

原版 `com.huawei.vrvirtualscreen` 的投屏页走的是 EMUI 系统能力：

- `main.view.MainActivity` 的闸门（`b/a/c/k/b/d.e`）要求
  `isVRMode() == true` 且**不能跑在默认屏**（否则
  `app start on default display error, finish!`）；
- `AppDisplayManager` 用 `IVRSystemServiceManagerEx.createVrDisplay(...)`
  建 `HW-VR-Virtual-Display-N-Src` 虚拟屏；
- 屏幕采集 `b/a/c/f/a0`（`CaptureDisplay`）用
  `DisplayManager.createVirtualDisplay(..., AUTO_MIRROR)`，平台要
  `CAPTURE_VIDEO_OUTPUT`（signature|privileged）。

普通安装拿不到签名权限，也不能把活动启动到非 trusted 的虚拟屏
（`isCallerAllowedToLaunchOnDisplay` 要 `INTERNAL_SYSTEM_WINDOW`）。
之前仓库里的做法（LSPosed 放行 + 签名权限）**必须 root**。

## 免 root 的做法

同一个 `com.huawei.vrvirtualscreen` 包里加一个独立入口，不碰原 VR 链路：

    Vr2dStartUpActivity.onCreate
      -> HvrMirrorEntry.start(Activity)
           -> HvrMirrorActivity        （系统录屏授权，透明主题）
                -> HvrMirrorService     （foregroundServiceType=mediaProjection）
                     -> MediaProjection.createVirtualDisplay(AUTO_MIRROR, 眼镜 Surface)
                     -> 眼镜 display 上左右各一个 SurfaceView

> **Android 13+ 注意**：同一个 `MediaProjection` 创建多个 `VirtualDisplay`
> 时，系统只让最后创建的那块出图（Android 14 还限制 token 复用）。这里的
> 两路 `SurfaceView` 写法在 13+ 上可能只有一只眼有画面。通用修复是
> **只建一个 VirtualDisplay → SurfaceTexture → GL 左右眼各画一次**，
> 可参考 `sample-app/.../cast/MirrorGlView.java`。

用的全是公开 API：

| 能力 | API |
|---|---|
| 找眼镜副屏 | `DisplayManager.getDisplays()`（`VrPlatformCompat.externalDisplay`） |
| 录屏授权 | `MediaProjectionManager.createScreenCaptureIntent()` |
| 前台服务 | `startForeground(..., FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)` |
| 显示到眼镜 | 眼镜 display context 上的 `TYPE_APPLICATION_OVERLAY`（失败时回退 `Presentation`） |
| 镜像 | `MediaProjection.createVirtualDisplay(..., VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, ...)` |

新增清单项（`patches/patch_mirror_entry.py`）：

- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_MEDIA_PROJECTION`
- `activity ...mirror.HvrMirrorActivity`（`exported=false`，透明主题）
- `service ...mirror.HvrMirrorService`（`foregroundServiceType="mediaProjection"`）

## 构建

```powershell
build\build-module.ps1 -Package com.huawei.vrvirtualscreen -Revision r4
```

产物：`build/out/com.huawei.vrvirtualscreen-r4.apk`
（SHA-256 `C606C1D0A756E49BFB74ECC944AA52BEB5650281D2B84B37712B71E07B8985EF`）

## 安装与使用

1. 如已装官方/不同签名的 `com.huawei.vrvirtualscreen`，先卸载；同签名的旧构建可直接覆盖。
2. `adb install -r com.huawei.vrvirtualscreen-r4.apk`
3. 授权悬浮窗（免 root，adb 不需要 root）：
   `adb shell appops set com.huawei.vrvirtualscreen SYSTEM_ALERT_WINDOW allow`
   或 设置 → 应用 → VR 手机投屏 → 显示在其他应用上层。
4. 插上眼镜，确认系统把它识别为**扩展副屏**（三星若自动进 DeX，改成屏幕镜像/关闭 DeX）。
5. 打开「VR 手机投屏」→ 系统「录制或投射屏幕」→ 选「整个屏幕」→ 允许。
6. 眼镜里出现手机画面（左右眼各一份，按手机比例居中）；通知栏常驻「VR 投屏」。
   停止：强行停止该应用，或拔掉眼镜。

## 限制

- 每次启动都要过一次系统录屏授权（免 root 无法绕过）。
- 这是**平面镜像**，不是原版 VR 空间里的 3D 投屏/虚拟屏/手柄；没有镜头畸变校正。
- 依赖眼镜作为独立副屏出现；如果手机把眼镜当镜像屏（没有第二块 display），
  入口会提示「请先连接 VR 眼镜」。
- 只在 `SM-F731U1 + Android 16 + HUAWEIAV03` 的仓库记录上验证过显示层；本构建
  没有真机可测，失败时看
  `adb logcat -s HvrMirrorActivity HvrMirrorService HvrMirrorEntry`。
