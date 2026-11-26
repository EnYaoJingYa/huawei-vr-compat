# SBS 面板选择修复：dual 档按面积选大屏（2026-11-26）

> 状态：**代码已修复 + 离线编译/逻辑验证 + 换芯端到端验证通过；待真机复验**。
> 这修的是 SBS 显示链路里「面板被压成空壳」这一环，不是 `vr_display` 前缓冲直出
> （后者仍是未完成项，见 `PATCH_AUDIT.md` §5.7）。
>
> **怎么装到设备上**：见 [`docs/SBS-PANEL-FIX-BUILD.md`](SBS-PANEL-FIX-BUILD.md)。
> 兼容层已编译成 `build/compat-dex/compat-sbs-panel-fix.dex`，用
> `tools/apply-sbs-panel-fix.sh` 换进设备上已打补丁的 APK 即可生效，无需重编整包。

## 1. 问题

SBS 双目画面要送到眼镜那块大面板（3200×1600 / 1920×1080）。为了消除左眼叠影，
现场把 `overlay_display_devices` 从 `1920x1080/320` 压成 `100x100/320`：小探针屏满足
「有外接屏」的在位判据，但 SBS 面板自己成了 50×28 的空壳（`fix/2026-11-08-眼镜黑屏排查分析.md` §13.6）。

想用 `dual` 档（`100x100/320;1920x1080/320`）让「小屏满足在位、大屏当面板」分页职责，
但面板选择逻辑取的是**第一块**合格副屏，两只判据都会命中小屏：

| 调用点 | 用途 | 旧行为 |
|---|---|---|
| `VrPlatformCompat.externalDisplay()` | `HvrVrPanelPresenter` 决定 Presentation 挂哪 | 第一个非默认、非 OFF 的 display → 小屏 |
| `HvrPanelFinder.find()` | `HvrMirrorService` 投屏面板 | presentation 类别 / FLAG_PRESENTATION 各取第一个 → 可能小屏 |

## 2. 修复内容

全部收敛到 `shared/java/`，由 `build/build-module.ps1` 编译进兼容层 dex。

### `VrPlatformCompat.java`
- 新增 `largestDisplay(Display[])` / `largestDisplay(Display[], boolean requireOn)`：
  在所有候选里按**可视面积（realPixels 宽×高）最大**选择；面积相同按 displayId
  小者，结果稳定可复现。
- 新增 `isCandidatePanel(display, requireOn)` / `displayArea(display)`：候选判定与
  面积计算；`displayArea` 对拿不到尺寸的屏返回 0 而非抛异常。
- `externalDisplay()` 改为调用 `largestDisplay(getDisplays())`。
  **`hasExternalDisplay()` 的「是否存在」语义不变**（有任意合格副屏即 true），
  只改变「选哪块当面板」。

### `HvrPanelFinder.java`
- 第 2 级 `DISPLAY_CATEGORY_PRESENTATION`、第 3 级 `FLAG_PRESENTATION` 从「返回第一个」
  改为「本级候选中按面积取最大」，复用 `largestDisplay()`。
- 这两级传 `requireOn=false`，保留原逻辑「眼镜屏短暂 OFF 也能认出来」；
  第 4 级兜底走 `externalDisplay()`（`requireOn=true`，排除 OFF）。
- 第 1 级名字匹配（HUAWEI / VR / AV03 / GLASS）不变——真眼镜屏名字唯一，应优先于
  任何 overlay。

## 3. 验证（已做）

- **离线编译**：`javac -source 8 -target 8 -cp android.jar` 编译三个相关源文件，无错误，
  产出 `VrPlatformCompat.class` / `HvrPanelFinder.class` / `ContextEx.class`。
- **逻辑单测**（复刻 `largestDisplay` 算法）四个场景全过：

| 场景 | 期望 | 结果 |
|---|---|---|
| dual：#0 默认 + #1 100×100 + #2 1920×1080 | 选 #2 大屏 | ✅ |
| 面积相同（#3、#5 均 1280×720） | 取 id 小的 #3 | ✅ |
| 含 OFF 的 3200×1600 眼镜屏，`requireOn=false` | 认出 #9 | ✅ |
| 同上 `requireOn=true` | 排除 OFF | ✅ |

## 4. 落地步骤（需真机）

1. 用修复后的 `shared/java` 重新构建受影响 APK（至少 `vrservice` 那条含
   `HvrVrPanelPresenter` 的链，以及 `vrvirtualscreen`）：
   ```powershell
   .\build\build-module.ps1 -Package com.huawei.vrservice -Revision <new>
   ```
2. 装机 + 授权后，切到 dual 档：
   ```bash
   sh fix/tools/vr-overlay-mode.sh <serial> dual
   # 重启 VR 桌面让 panel-bootstrap 重建 Presentation
   ```
3. 看日志确认面板挂在大屏（关键字 `panel presentation shown on display N`，
   N 应为 1920×1080 那块的 id）；`dumpsys display` 看 HUAWEI VR Display 尺寸不再是 50×28。

## 5. 边界与未解决

- **不是全部 SBS 问题**：`vr_display` 前缓冲直出仍未实现，官方渲染结果送 DP 面板那条路
  （`IVrServiceManager.startFrontBufferDisplay`）仍返回不可用；本修复只保证「一旦有画面，
  Presentation 挂对面板」。
- **需重编 APK**：改的是 Java 源码，旧 APK 内 dex 不含此逻辑，直接切 dual 无效。
- **叠影取舍**：dual 让大屏当面板可能重新引入左眼叠影；`small` 档仍可用于只验主线。
- **真机未验**：以上为代码 + 离线验证，需在眼镜真机上按第 4 节确认视觉结果。
