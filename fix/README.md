# fix/ —— 华为 VR 全栈一键安装包（RK3566 盒子专用）

> 生成于 2026-11-02。目标机：`H96_Max_RK3566`，Android 11（SDK 30），Magisk 26.3，
> 必须**支持 armeabi-v7a**（7 个包里 6 个是 32 位）。
>
> **给后续 AI / 人的最短路径：**
>
> ```sh
> adb connect 192.168.43.133:5555        # 盒子 IP 以实际为准（无线 adb）
> sh install.sh 192.168.43.133:5555      # 完了。脚本幂等，可反复跑
> ```
>
> 只想重装模块/授权不动 APK：`sh install.sh <serial> --skip-install`
>
> **2026-11-07 一键安装工具已更新并实跑验收**：`install.sh` 现在会
> ① 部署 `wadb` 无线 ADB 开机自启模块（刷机后 `persist.adb.tcp.port`
> 必丢）并幂等写两个 adb tcp 端口属性；② 点亮后**等待设备端脚本内嵌的
> 25 秒 adbd 自恢复窗口**再做验收与启动；③ 点亮后**补拉 VR 服务**
> （`stop/start surfaceflinger` 会把第 4 步刚拉起的 vrservice /
> hvrsdkserverapp 冲掉，实测装完只剩应用市场、进程列表为空）。
> 整条链路一次跑完，装完 VR 栈是活的，不再出现「装到一半 ADB 断了、
> 后面全是空输出」。`light-on.sh` / `一键点亮.bat` 也改为
> 「执行 → 等 ADB 自恢复 → 回读设备端日志 + 内核时序」，
> 不再只打印一个断连错误。**PC 侧守护与拔电源都不再需要。**
>
> **眼镜没亮 / 刷机后单独点亮**：双击 `一键点亮.bat`，或 `sh light-on.sh`
> （自包含，不用先跑完整安装）。只体检：`sh light-on.sh <serial> check`
>
> ⚠️ **每次开机 / 断电后都要重跑点亮**（HWC 首次 Init 选不到 3200）：
> `sh fix/light-on.sh <serial>` —— **一条即可，守护可选**。
> 2026-11-07 08:17 `adb reboot` 实测：开机不自动亮（1080p60），
> 单跑这一条后 HWC 217→4371、`clk[412180]`，ADB 自恢复、5 次采样稳定。
>
> ⚠️ **无线 ADB 掉线已内嵌修复（2026-11-07 08:10 实测闭环）**：
> `stop/start surfaceflinger` 会冲掉 adbd 的 5555 监听。PC 侧
> `adb-keepalive.sh` 派生的守护是 `adb shell → su -c` 的后代，SF 停止时
> 会被会话一起清理（`nohup` / `setsid` 实测均无效，守护日志连
> 「5555 lost」都来不及写），表现为 `ping` 通但 5555 长时间拒绝，
> 只能拔电源靠 wadb 开机自检恢复 —— 而拔电源又把刚点亮的 3200 清零。
> 还有一层根因：重拉 adbd 时只写 `service.adb.tcp.port` 不够，必须同时
> 写 `persist.adb.tcp.port`，否则 adbd 重启后不开 TCP 监听。
> 现在 `magisk-module/runtime/light-on.sh`（设备端进程，实测能活过
> SF 重启）自己幂等写这两个属性，并在 25 秒后由子 shell 做 init 级
> `stop/start adbd`，**PC 侧无需断电即可连回复验**。08:10 实测
> `uptime` 连续、`clk[412180]` 4 次采样稳定、`LISTEN=2`。
> 守护仍可开（纯运行时、不改开机逻辑、`off` 可停），但已非必需。
>
> ✅ **2026-11-07 07:00 竞态根因钉死 + 修复，点亮已确定性化**：
> `stop surfaceflinger` 后 HWC 要**约 4 秒**才跟着退出（客户端死亡），
> init 随即重启 HWC、全新 Init 按 属性+白名单+内核模式表 选到 3200。
> 旧版脚本 `sleep 2` 太短，`start` 把还没退出的旧 HWC 又接回去 →
> HWC 不重新 Init → 永远 1080p。**历史「时灵时不灵」全是这个竞态**
> （成功案例 HWC PID 都换过，失败案例 PID 不变）。修复版
> `magisk-module/runtime/light-on.sh`（竞态修复版 `5cc4a2d4…`；
> 08:10 加入无线 ADB 自恢复后 `abd6022a…`）改为
> **盯住 `init.svc_debug_pid.vendor.hwcomposer-2-1` 变化再启动 SF**，
> 2026-11-07 实测一次成功且 60 秒稳定采样全绿（`clk[412180]`）。
> 已部署到设备 `/data/adb/hvrglass/light-on.sh`。
> **固定用法（每次开机/断电后）**：`sh fix/light-on.sh <serial>`
> 守护 `sh fix/adb-keepalive.sh <serial> on` 可选，非必需。
>
> **点亮的正解在整机备份里**（`backup/box-2026-11-05/`）：
> `hvrglass_runtime.tar.gz` / `data_adb.tar.gz` 保存着 11-05 22:33
> 「已点亮 3200x1600p70 clk[412180] 且稳定」的完整运行时配置：
> `mode=auto`（真实 `22f6` EDID 直通、不注入）、白名单 `528d4e07…`
> （2 条 3200，内核真值 1663/1664）、`light-on.sh` `e3253876…`
> （11-05 18:17 成功版）、两个 `persist.vendor.resolution=3200x1600@70`
> （`framebuffer.*` 保持 1920x1080@60）。方法 = 白名单 bind mount →
> 属性 → 一次 `stop; sleep 2; start surfaceflinger`，让 HWC **重新初始化**
> 重选模。11-06 18:52 用同法复现点亮，代价是约 1 分钟后整机重启；
> 11-05 18:10 能稳定到 22:33 是因为系统已连续运行数小时。
> **设备已按此配方还原，本地白名单母本同步为 `528d4e07…`。**
>
> **2026-11-07 根因复核（修正 11-06 的定论，别再绕白名单）**：
> `dmesg` 实测内核 HDMI 在 **0.215s** 就 probe/bind 完成，5s 之后
> 没有任何 HPD/EDID 事件，开机后模式表一直有 2 条 3200 —— 所以
> 「HWC 6.04s 时内核还没读到 EDID」**不成立**。真正没抢赢的是
> **Magisk 挂载 / persist 属性时序**：`edid_boot.log` 的 post-fs-data
> 晚于 HWC `ro.boottime=6.049s`；`/proc/<hwc>/root/...` 只证明运行时
> 视图，证明不了 `DrmDevice::Init()` 那一刻读到什么。HWC 库里有
> `can't find suitable Resolution Property, try to use Baseparameter.`
> —— 首次 Init 读不到 `persist.vendor.resolution.*` 就固化 1080p。
> 详见 `.workbuddy/memory/2026-11-07.md`。
>
> ⚠️ **开机早期属性补丁已实测失败，禁止再刷（2026-11-07 06:50）**：
> `tools/make_boot_earlyprop.py` 生成的 `build/boot-hvrglass-earlyprop.img`
> 在 ramdisk 新增 `init.rk30board.rc`（`on early-init` 提前设 resolution
> 属性 + HWC 日志开关），只改 376 字节、kernel/second/尾部逐字节一致、
> Magisk ramdisk 原有 17 个文件未动。**但 dd 写入 + reboot 后设备无法
> 启动**：ping 0/10、5555 CLOSED、无 USB adb，持续 6 分钟网络栈从未起。
> 可能原因（无串口日志，无法区分）：`on early-init` 阶段 property service
> 未就绪时 `setprop persist.*` 致 init 失败 / header `id`(SHA1) 未随
> ramdisk_size 更新被 bootloader 拒 / ramdisk 尾部补 0 或新增 cpio 条目
> 致 initramfs 解析异常。**不要再试第二版 boot 补丁。**
>
> **回退（只刷 boot 一个分区，48MB）**：原镜像
> `build/boot-ORIGINAL-restore.img`（= `backup/box-2026-11-05/partitions/boot.img`，
> md5 `415b5787076d680a72933d96dc677ef1`）。
> USB OTG 连盒子进 Loader/MaskROM → `F:\RKDevTool_Release_v2.86`
> 【高级功能】→「按地址写镜像」，地址填 `51200`（十进制 LBA，
> 见 `backup/box-2026-11-05/gpt_verified.tsv` 与 `flash_by_partition.bat`），
> 选原 boot.img 写入 → `rd`/断电重插。**绝对不要点「升级固件/执行」**。
> 本机没有 rkdeveloptool 命令行版；命令行等价为
> `rkdeveloptool wl 51200 <原boot.img>`。
> 实验工具：`fix/boot-whitelist.sh`（空白名单，可 `off` 回退）、
> `fix/adb-keepalive.sh`（无线 ADB 运行时守护，**可选**，主链路已内嵌自恢复）。
>
> **开机即亮稳定态**（单模式 EDID + systemless 白名单 + force-vr，二·9）
> 2026-11-06 两次受控重启实测**均未点亮**，因此 `install.sh` **默认不再部署**；
> 需要该实验时显式 `sh install.sh <serial> stable`（`--stable-check` 体检、
> `--stable-off` 回退）。要改开机阶段须用户明确授权。
> ⚠️ `boot-light-on.sh` 的「开机注入真实 22f6 赢过 HWC probe」已于
> 2026-11-06 证伪（注入 6.5s 晚于 HWC 6.03s；DDC 直通坐实 EDID 注入多余），
> 仅作取证工具，别再当点亮手段（手册 6.11 / 6.12）。

---

## 一、目录结构

| 路径 | 内容 | 装到设备哪里 |
|---|---|---|
| `install.sh` | **一键安装脚本**（装 APK → 部署模块 → 授权 → 一键点亮 → 验收） | — |
| `light-on.sh` / `一键点亮.bat` | **一键点亮眼镜**（本地入口，自动 push 设备端脚本） | — |
| `adb-keepalive.sh` / `adb-keepalive-daemon.sh` | 无线 adb 5555 运行时守护；`on/off/check`。**已非必需**（2026-11-07 起 ADB 自恢复内嵌在设备端点亮脚本里），保留作可选冗余 | nohup 后台进程（重启失效） |
| `ttyusb-compat.sh` | vcom (`/dev/ttyUSB*`) 运行时绑定 + 权限校正；`check/on/off/watch` | 运行时 sysfs（重启失效） |
| `tools/hwvr1-check.sh` | **两道闸一键体检**（hidraw 枚举 + `hwvr-probe` 应答 + `hwvr1` 指向 + `vr_system_state` 注册表 + 失败计数），只读 | — |
| `magisk-module/modules/hwvr-probe` | 控制接口协议探测二进制（`HIDIOCGFEATURE(4)`，源码 `ksu/hwvr_compat/hwvr-probe.c`） | `/data/adb/modules/hvrglass/hwvr-probe` |
| `ddc-passthrough.sh` | DDC / EDID 直通验证；`check/passthrough/restore/reboot/verify` | `/data/adb/hvrglass/mode` |
| `restart-hwc.sh` | HWC 选模取证；`check/restart/verify`（**勿当点亮手段**，restart 实测整机重启且无效） | — |
| `一键修复VR框架.sh` / `一键修复VR框架.bat` | **修 VR 桌面链路**（装四个最终补丁 → 开模拟辅助显示 → 启 `.MainActivity`；`check/off/rollback/launcher`） | 手册第 8 章 |
| `patches/vrdesktop/` | 四个最终补丁 APK（launcherx / vrservice / hvrsdkserverapp / **vrhandle-pose**）、回退基线、最小差分构建脚本 | 手册第 8 章 |
| `apks/` | 7 个华为 VR 包，已去 sharedUserId、统一 hvr-compat 签名 | `pm install` |
| `magisk-module/modules/` | hvrglass 模块本体（EDID 按需注入 + hidraw 权限轮询 + ttyUSB vcom 兼容开关） | `/data/adb/modules/hvrglass/` |
| `magisk-module/runtime/` | EDID 运行时切换脚本 + 1080p EDID + **light-on.sh 点亮脚本**（已内嵌竞态修复与 ADB 自恢复） | `/data/adb/hvrglass/` |
| `magisk-module/wadb/` | **无线 ADB 开机自启**（纯 late_start、无 post-fs-data、无 mount，不会卡 logo）；开机自检重拉 5555 | `/data/adb/modules/wadb/`（install.sh 自动部署） |
| `tools/` | 重签 / EDID 生成 / OTA 验证 / hwext 补丁 / 授权脚本 | PC 侧 |
| `signing/hvr-compat-debug.jks` | 签名密钥（PKCS#12，口令 `android`）——七个包必须同签名 | PC 侧 |
| `分析汇总.md` | 本轮全部分析的汇总（细节文档在仓库 `docs/`） | — |

## 二、install.sh 做了什么（按序）

1. **体检**：连接、ABI（要 armeabi-v7a）、root（`su` 必须可用）
2. **装 7 个 APK**（`install -r -d`；遇 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
   自动卸载重装——签名和旧包不一致时必走这条路，数据会丢）
3. **部署 hvrglass 模块**：`modules/` → `/data/adb/modules/hvrglass/`，
   `runtime/` → `/data/adb/hvrglass/`，权限 755/644；
   同时部署 `wadb` → `/data/adb/modules/wadb/` 并幂等写
   `persist./service.adb.tcp.port=5555`（刷机后开机也能自动有无线 ADB）
4. **`settings put system PRIVACY_ACCEPTED 1`**（绕过 launcherx 隐私页崩溃）
5. **补授权**（调 `tools/grant-vr-perms.sh`：appops、pm grant、deviceidle 白名单、日志级别）
6. **一键点亮眼镜**（调设备端 `light-on.sh`：白名单 bind mount → resolution 属性 →
   等 HWC PID 变化 → 一次 `stop/start surfaceflinger` → 验收 3200x1600p70；
   `--no-light-on` 可跳过。眼镜没激活时脚本自检拒绝，不会强扭）。
   点亮后安装脚本会等过设备端 25 秒 `adbd` 自恢复窗口，并补拉被 SF
   重启冲掉的 VR 服务，再继续 7/8 步，否则验收与启动会全是空输出
7. **验收**：包列表、进程列表、`vr_system` 状态
8. **启动应用市场**冒烟（`--no-launch` 可关）
9. **点亮配置按 11-05 备份态**（`mode=auto` / 白名单 `528d4e07…` / `light-on.sh` `e3253876…`）：见顶部说明
   （开机即亮稳定态已证伪、默认关闭，仅显式 `stable` 才部署，见「二·9」）

### 二·9 开机即亮稳定态（2026-11-06 从历史会话翻出并固化）

10-30 / 11-02 曾长期稳定「重启就亮 3200x1600p70」，靠三条同时满足，
少一条 HWC 就自造 `1920x1080p60 / clk[148500] type[40]`：

| # | 条件 | 现在的差异 |
|---|---|---|
| ① | EDID 母本是**单 DTD、只声明 3200x1600@70** 的 256B（md5 `138fb20e…`，CEA VSDB 声明 Max TMDS 600MHz）→ 内核 `modes` 只剩一条，HWC 没法回落 | 07:36 `boot-light-on.sh on` 换成真实 `22f6` 多模式 EDID（`eba6de4e…`），`modes` 变 10 条含 1080p60 |
| ② | 白名单 `resolution_white.xml` 走 **Magisk systemless overlay**（模块 `system/usr/share/`），开机挂载阶段就位 | 现在只靠 `post-fs-data.sh` 运行时 bind mount，实测 6.5s 晚于 HWC 6.03s 的 `init_white_modes()` |
| ③ | `mode=force-vr` 无条件注入 | 已是 force-vr |

```sh
sh install.sh <serial> --stable-check   # 只读：母本 md5 / overlay / mode / modes / 物理时序
sh install.sh <serial> stable           # 只部署三件套：不装 APK、不重启、先备份
#   → 手动重启一次（眼镜 HDMI + USB 保持插着）
sh install.sh <serial> --stable-off     # 回退母本 / overlay / mode，再重启
```

只写数据文件与开关，**不改开机脚本逻辑、不动 system 分区、不刷机**；
`--with-overlay` 那个会卡 logo 的 `public.libraries.txt` 整体替换是另一回事，
仍默认关闭。接普通显示器前务必 `--stable-off`，否则会被骗成只支持 3200。

**⚠️ 2026-11-06 22:45 真机证伪（两次受控重启，结论一致）**：三件套全部生效后
仍不亮。`modeinfo` 读到的内核唯一模式是
`3200x1600 clock=412180 h=3200/3260/3268/3308 v=1600/1613/1614/1780 flags=0x5`；
HWC 进程命名空间里白名单 md5 与 adb 侧一致、含 3 条 3200（含专为单模式 EDID
补的 `vsync 1613/1614` 变体）；`mode=force-vr`；但 `supportedModes` 仍只有
`[{1920x1080@60}]`，VOP 仍是 `1920x1080p60 / clk[148500] type[40]`（HWC 自造模式）。
六字段全等、全字段变体也都试过 → **不是字段匹配问题**。结合 07:36 时序证据
（HWC 由 `late-fs` 在开机 6.03s 启动并 `DrmDevice::Init()`，post-fs-data 的
EDID 注入/白名单在约 6.5s，晚 0.4s），根因是 **HWC 首次 Init 时既没读到
含 3200 的白名单、内核也还没给它 3200 模式，之后不再重读**；Magisk
systemless overlay 也没抢赢这一刻。

→ 纯数据层/运行时层到此为止，**剩下只能改开机阶段**（让 EDID + 白名单都早于
HWC 6.03s，或让 HWC 读到空白名单触发 `mode_verify` 全放行）。这触及
「不擅自改开机逻辑」硬约束，需用户明确授权后再动。`stable` / `--stable-off`
作为可逆部署能力保留，供授权后的方案直接复用。

模块的 EDID 逻辑（`post-fs-data.sh`，开机执行）：

| 开机时显示状态 | 行为 |
|---|---|
| 能读到屏幕真实 EDID（普通便携屏/显示器） | **不注入** |
| EDID 为空（VR Glass 眼镜的特征） | 注入 3200×1600@70（`common/edid_only.bin`） |
| 没接屏 | 不注入 |

模式覆盖：`echo auto|force-vr|force-off > /data/adb/hvrglass/mode`（默认 auto）。

## 三、装完怎么验证

```sh
# 0. 眼镜物理链路（disconnected / EDID 0 字节 = 没插好或没激活，点亮会被正确拒绝）
adb shell su -c 'cat /sys/class/drm/card0-HDMI-A-1/status; cat /sys/class/drm/card0-HDMI-A-1/modes'

# 1. 七个包都在
adb shell pm list packages | grep com.huawei

# 2. 应用市场能开（唯一 100% 可用的）
adb shell am start -W -n com.huawei.appmarket.vr/com.huawei.hwmarket.vr.MainActivity

# 3. 显示真实时序（不要信 dumpsys display，看内核）
adb shell su -c 'sh /data/adb/hvrglass/edid-mode.sh show'

# 4. HID 权限守护在跑（眼镜 IMU 用）
adb shell su -c 'tail /data/local/tmp/hidraw_perm.log'

# 5. 眼镜点亮链路体检（只读，不改任何东西）
sh light-on.sh 192.168.43.133:5555 check
# 6. 没亮 → 一键点亮（或双击 一键点亮.bat）
sh light-on.sh
```

点亮成功的硬指标：`Find best mode-id=4 : 3200x1600p70` +
`dri/0/summary` 里 `Display mode: 3200x1600p70 / clk[412180]`。
细节与踩坑见 `刷机后问题分析与恢复手册.md` 6.6。

预期状态：应用市场 2D 商城完全可用；launcherx / vrvirtualscreen 到「请连接华为 VR 眼镜」
门禁页；himovie 到协议页；vrhandle 手柄管理界面可用；vrservice / hvrsdkserverapp
进程常驻但空转。

## 四、已知问题与排障

### 1. 便携屏黑屏（最常见的翻车点）

不是线坏，是 EDID 被喂成 3200×1600@70 了。修：

```sh
adb shell su -c 'sh /data/adb/hvrglass/edid-mode.sh 1080p'
# 若仍未恢复：清掉强制分辨率属性再重启盒子（别用 ctl.restart surfaceflinger，
# 手册 4.2 实测它会让整机重启/卡死）
sh light-on.sh <serial> off
```

接回眼镜则直接一键点亮：`sh light-on.sh` 或双击 `一键点亮.bat`。
注意 `edid_override` 写入即常驻、写 0 清不掉。

**mode 的坑（实测）**：模块默认 `mode=auto` —— 只要能读到屏幕真实 EDID 就不注入，
这是**对的**。眼镜醒着时交出的就是 HWV 真实 EDID（厂商 `22f6`，自带
3200x1600@70/90 两条 DTD），别再注入覆盖它；眼镜没醒时读到的是转换器默认
EDID（`22d2`），这时按手册 4.3 先用 PC/手机点亮一次再插回盒子。

接眼镜的可靠做法（2026-11-05 实测固化，详见手册 6.6）：

```sh
sh light-on.sh          # 或双击 一键点亮.bat
```

⚠️ 别再用 `echo force-vr > /data/adb/hvrglass/mode && reboot`：开机阶段注入
EDID 会卡 logo（手册 4.1 两次实测），`force-vr` 绝不能固化。
白名单 + resolution 属性 + 一次 `stop/start surfaceflinger` 才是成功路径。

### 2. 眼镜里画面"超出范围"（图超大，每眼只有半幅）——不是时序问题

VOP 把 1920x1080 桌面**拉伸铺满 3200x1600 双目面板**，每眼只看到桌面一半。
切 @70/@90 无用（两模式总光栅完全相同 3308x1780）。渲染端必须出 SBS（左右格式）：
himovie.vr 播放模式立即可用；桌面级 SBS 要走 vrvirtualscreen / ALVR / 自写镜像，
均被 `vr_system` 缺失挡住（见问题 3）。

### 3. `vr_system` 未注册（**已在应用层绕过，见第 3.1 节**）

`service list | grep vr_system` 仍为空。根因：`vrservice` 原靠
`sharedUserId="android.uid.system"`（平台签名）由 system_server 注册服务，
改为普通应用后这条路断了。而 `vr_system` 是桌面进 VR 空间、虚拟屏投屏、SDK
运行时握手的总闸。

系统服务这条路并没有恢复，但 `一键修复VR框架` 已用**应用层注册表 + 动态代理**
把它绕过去：`com.huawei.vrlauncherx.registry` ContentProvider 托管 binder，
`VrSystemRegistryProvider` / `HvrStatePublisher` 分别发布 `vr_system` 与
`vr_system_state`；`HvrSdkBridge` 在 native `SetClass` 实际持有的 ClassLoader
上生成 `IVRSystemServiceManager` 代理，让 `HVRActivity.getSystemService("vr_system")`
能通过 `check-cast`，`isVRMode()` 从真实 `SystemServiceBinder` 读 `getVRModeState`。
所以这一项**不再是桌面进 VR 空间的阻塞**。

### 3.1 一键修复 VR 框架：四包与当前验收状态

```sh
sh fix/一键修复VR框架.sh                       # 或双击 一键修复VR框架.bat
sh fix/一键修复VR框架.sh <serial> check        # 只读验收
sh fix/一键修复VR框架.sh <serial> rollback     # 装回四个原版基线
```

四个最终包（统一 `hvr-compat` 签名；`vrhandle` 基线是华为原签，
脚本会自动检测签名冲突并「卸载→重装」，回退时同理）：

| 包 | 解决什么 |
|---|---|
| `com.huawei.vrlauncherx-full.apk` | compat dex + 补 ctx1 + 删 6 个空壳桩 + 恢复 `LibUpdateClient.runUpdate()` + `HvrSdkBridge`（统一 SetClass 类副本、`vr_system` 动态代理、真实 VRMode） |
| `com.huawei.vrservice-full.apk` | ctx0 归位 + 定义 signature 级 `com.huawei.android.permission.VR` |
| `com.huawei.hvrsdkserverapp-full.apk` | 5 组件归位 + 27 个 64 位库 + `HvrStatePublisher` 发布 `vr_system_state` |
| `com.huawei.vrhandle-pose.apk` | 4 个 ELF32 姿态库 + `extractNativeLibs=true` + `HvrPoseLibPath`，修 `helmetPoseStart()` 无 native 实现 |

2026-11-05 真机 45 秒冷启动验收：`load libMobileSensor/WalleAlg/WalleDev/vrpose success`
各 1、`helmetPoseStart` 执行、`getHelmetPose` 四元数回传 launcherx 的
`VrControllerManager`（`SetHelmetPoseOffset`）、`RenderModule Init VR end` /
`mRenderInited 1`；`UnsatisfiedLinkError` / `FATAL` / `ApplicationQuit` /
`App activity is null` / `VRPromptActivity` 全 0；栈顶保持
`com.huawei.vrlauncherx/.MainActivity`。

**2026-11-06 已清零的级联崩溃（详见手册 8.4 改写段）**：

| 层 | 根因 | 修法（工具） |
|---|---|---|
| 1 | `WindowManagerEx$LayoutParamsEx.setDisplaySideMode(I)V` 缺失 | `vrdesktop/add_set_display_side_mode.py`（vrservice + launcherx 的 `classes4.dex`） |
| 2 | `ServiceTermActivity` 的 `InflateException`：EMUI `androidhwext` `?0x0201xxxx` 私有属性在 AOSP 解析失败（且是 `TYPE_ATTRIBUTE=0x02`，不是 9 月脚本处理的 `0x08`） | `vrdesktop/inline_hwext_attrs.py`（9 个布局、103 处内联） |
| 3 | `ArvrRuntimeService.onDestroy()` 的 `j.deinit()` NPE、`unregisterReceiver(null)` → `Receiver not registered: null` | `vrdesktop/fix_runtime_ondestroy.py`（两处判空） |
| 4 | **真正的总根因**：compat 早先把 `onCreate()` 整个短路成 `VrSystemActor.start() + return-void`，原厂 `b()`（`startForeground`）永不执行 → `startForegroundService()` 超时 ANR → AMS 杀进程 → `VrSystemActor` / `vr_system_state` 消失 → `Force removing ... vrlauncherx/.MainActivity` → `VRService` 判定头盔掉线拉 `ServiceTermActivity` | 同一脚本在短路前补回 `invoke-direct b()V`，不改其余逻辑 |
| 5 | `VRService.installVrApp()` → `checkCurrentComponentsExist()` 遍历 6 个必需包，真机只缺 `com.youku.vr` → 弹安装向导 | `vrdesktop/make_youku_stub.py` 生成 8.5KB 只声明包名的占位包，`adb uninstall com.youku.vr` 即可回退 |
| 6 | 用户协议点「同意」不落盘：`VRUtils.isInstallAgreementAccepted()` 查 `SharedPreferenceProvider` 恒为 `agreement=false`，15 秒一轮 `Need to reapply for user agreement authorization` | `content insert --uri content://com.huawei.vrinstaller.provider.sharedpreferenceprovider/setBoolean/com.huawei.vrinstaller_preferences --bind agreement:b:true`（一键脚本已内置） |
| 7 | vrservice 的 `sendMessageToClient(I, Object)` 把 `Integer`(0x3ea) / `Boolean`(0x3ed) 直接塞进 `Message.obj`；`Message.writeToParcel` 只接受 Parcelable，跨进程抛 `Can't marshal non-Parcelable objects across processes` 杀掉 `VRWorkerThread`（共 13 个发送点） | **`vrdesktop/fix_messenger_payload.py`**（双包）：vrservice 把标量载荷编进 `Message.data` Bundle、`obj` 置 null；launcherx 在 `t0/c$b.handleMessage` 分发前还原 `obj`。`fix_prepare_msg.py` 已废弃 |
| 8 | 单包「置 null」补丁的回归：接收端 `t0/c.D` 非 2/4 分支仍 `check-cast Integer` → `Integer.intValue()` NPE；`handleEarphonePlugged` 继续发 `Boolean` → marshal 崩溃，每 ~30s 一轮 8 个 FATAL | 同一个 `fix_messenger_payload.py` 通用修复（覆盖全部发送点 + 接收端按类型还原） |

> **结论修正（重要）**：早先记录的「第 5 轮 100–130 秒窗口栈顶稳定
> `com.huawei.vrlauncherx/.MainActivity`、`UnityMain` 持续渲染、3D 桌面已驻留」
> 是 `fix_prepare_msg.py` 把 `obj` 置 null 后**误导 proximity 判断**造成的短时假象；
> 随后完整 logcat 复核出每 ~30s 一轮 8 个 FATAL。该结论作废，
> **不能作为「已进 VR 桌面」的依据**。

**真机复验（2026-11-06 07:36–07:53）**：装双包后清 logcat，180 秒窗口
`FATAL=0 / Can't marshal=0 / Integer.intValue NPE=0 / ANR=0 /
startVrInstaller=0 / ServiceTerm=0 / PrepareQuit=0 / NeedReapply=0 /
CheckVRModeFail=0 / ForceRemove=0`，`System prepare done, start vr.` 正常出现，
证明 0x3ea 载荷已送达并被处理；后续再观察 255 秒仍全 0。

**仍剩（未解，下一层）**：

1. **物理层 vcom 缺失**：`/dev/ttyUSB*` 不存在，日志 `5 times can not open
   vcom, stop try.`，`getProximityNativeJNI()` 恒为 -1；接收端 `t0/c.P(I)` 只有
   `p1==1` 才启动 3D 桌面，否则 `helmet away now, wait for proximity msg to
   start.` → 栈顶停 `VRPrepareActivity`、`UnityMain=0`。
   `fix_messenger_payload.py` 内含 `HvrProximityCompat`（读数 <=0 时按「已佩戴」
   置 1，读数 >0 时保留原值），**已装机但尚未验证**（见第 2 条）。
2. **冷启动缺 USB attach 事件**：`doHelmetPrepare()` 只由进程内
   `glass.connectdone` 之后调用，`UsbReceiver` 只认真实
   `android.hardware.usb.action.USB_DEVICE_ATTACHED`；软件强制重启服务后
   `heartbeat not init, wait.` 可持续数百次而不进入 prepare。需物理拔插眼镜
   USB / 电源，或授权触发一次 display 事件（会改 displayId，不是正式修法）。
3. 眼镜物理输出仍是 `1920x1080p60 / clk[148500]`，未点亮到
   `3200x1600p70 / clk[412180]`；点亮配方有效但 `stop/start SF` 后约 100 秒
   整机重启回落，属另一条线。
4. `VrSystemActor` 只在 `start()` / display 事件 `refresh()`，冷启动若 USB 判据
   未就绪不再重查；实测重插一次辅助屏可让 `0x3e9` 握手 → `0x1 / 0xf / 0xf / 0x3eb`
   整条跑通，但会改变 displayId（`VRUtils` 写死 displayId1），不能当正式修法。
5. `E VrHelmetExt: mVRDeviceExt is null` 经 PATCH_AUDIT 16.3 定性为 3DoF 分支噪声，不阻塞。

**回退**：`python fix/patches/vrdesktop/fix_messenger_payload.py --restore`
同时撤销 messenger 修复与 `HvrProximityCompat`，恢复到 `*.pre-messenger.apk`。

### 4. appops `SYSTEM_ALERT_WINDOW` 对 4 个包不生效

`vrhandle`/`vrservice`/`hvrsdkserverapp` 的 manifest 没声明该权限，
`appops set` 读回仍是 default。要修需给这 3 个包的 manifest 补
`<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>`
再用 `tools/apk-repack-sign.py` 重签重装（权限逐包表见仓库
`patches/patch_platform_permissions.py`）。

### 5. 装包报 `No signature found in package of version 2 or newer`

某个包 targetSdk≥30 又只有 v1 签名。本包内 APK 已全部处理好；
若以后自己重签，v1 手搓的用 `tools/apk-repack-sign.py --target-sdk 29`，
或用 JDK + apksigner（v1+v2）。

### 6. 启动闪退排查顺序

```sh
adb logcat -d | grep -E "FATAL|AndroidRuntime|NoClassDefFoundError|InflateException"
```

- `SystemPropertiesEx` 找不到 → 装的不是本包 `apks/` 里的版本（兼容层没打进去）
- `0x020100c8` / `androidhwext` → 同上，要用打过 hwext 补丁的重建版

### 7. 改了 EDID 但内核时序不变（CRTC 咬死旧模式）

实测：`edid_override` 写入 + 重启 SurfaceFlinger + 甚至重启 composer HAL
（`kill $(pidof android.hardware.graphics.composer@2.1-service)`，init 会自动拉起）
**都不改 VOP 输出**。composer 把 HDMI 当固定 1080p 内置屏，supportedModes 写死。
唯一可靠路径：**重启整机**，让模块 post-fs-data 在显示栈起来之前注入。
验证时序别信 `dumpsys display`，直接看内核：

```sh
adb shell su -c 'head -8 /sys/kernel/debug/dri/0/summary'   # 看 p60/p70/p90
adb shell su -c 'cat /sys/kernel/debug/dri/0/summary' | grep -A3 VOP   # 看 src/dst 几何
```

### 8. 想验证「不注入 EDID、内核自己读 DDC」是否可行（2026-11-06 已坐实）

转接器独立供电后 DDC 是通的：**override 为 0 字节**时，内核自己读到
256B、厂商 `22f6`、md5 `eba6de4e…` 的眼镜真实 EDID，模式表含
`3200x1600 ×2`；HPD 重读后仍是同一份。也就是说 EDID 注入是多余的。
**但这不等于点亮**：同一次开机白名单齐、resolution 属性已是
`3200x1600@70`，HWC 仍输出 `1920x1080p60`，卡点在 HWC 选模而非 EDID。
详见手册 6.12。

```sh
sh fix/ddc-passthrough.sh <serial> check         # 只读判据 + 自动判定
sh fix/ddc-passthrough.sh <serial> passthrough   # 备份 mode → force-off（不重启）
sh fix/ddc-passthrough.sh <serial> reboot        # 显式重启
sh fix/ddc-passthrough.sh <serial> verify        # 重启后完整判据
sh fix/ddc-passthrough.sh <serial> restore       # 恢复验证前的 mode
```

⚠️ 不要移走/改名 `edid_only.bin`：`post-fs-data.sh` 开头
`[ -f "$BIN" ] || exit 0`，文件没了会让 `HUAWEI` 伪装、`ro.vr.surport`
和白名单 bind mount 一起失效。用脚本原生的 `force-off` 分支才干净。

## 五、以后怎么改 APK 重出包

本机已有 JDK：`D:\Tools\AndroidSDK\jdk17tmp\jdk`（Temurin 17）。
PowerShell 里三个环境变量缺一不可：

```powershell
$env:HVR_ANDROID_SDK = 'D:\Tools\AndroidSDK'
$env:JAVA_HOME       = 'D:\Tools\AndroidSDK\jdk17tmp\jdk'
$env:PATH = 'C:\Users\555\.workbuddy\binaries\python\versions\3.13.12;' + $env:PATH
& .\build\build-module.ps1 -Package com.huawei.vrvirtualscreen -Revision r1
```

产物在 `build/out/`，覆盖回 `fix/apks/` 即可。无 JDK 时用
`python tools/apk-repack-sign.py 原包.apk 输出.apk [--target-sdk 29]`（密钥 `signing/`，口令 `android`）。

## 六、本轮分析文档索引（仓库 `docs/`）

| 文档 | 内容 |
|---|---|
| `分析汇总.md`（本包内）/ `docs/2026-11-02-全栈分析汇总.md` | **本轮全部分析的汇总** |
| `RK3566-部署记录.md` | 七包部署全过程、三处硬卡点 |
| `JDK解锁与七包重建-2026-11-02.md` | 构建链四坑、逐包处置 |
| `VR应用测试-2026-11-02.md` | 七包实机测试逐个结论 |
| `HDMI黑屏-EDID修复.md` | 黑屏根因与修复 |
| `线缆固件OTA-能不能骗.md` | OTA 协议逆向，结论：服务端已空 |
| `6DoF-为什么没起来.md` | 6DoF 软件栈分析 |

## 七、横屏方向补丁（VR 桌面不再显示成双目小窗）

`VrSystemActor.lockLandscape()` 是给**手机原生竖屏**写的，无条件写
`USER_ROTATION=ROTATION_90(1)`。RK3566 盒子原生 `1920x1080` 横屏，再转 90°
变成 `1080x1920` 竖屏，而 HWC 物理输出是 `3200x1600` 横屏 —— VR 桌面被
letterbox 压成中央小窗 + 上下大黑边。

纯 settings 改不回来：`lockLandscape()` 会持续写回 1，守护拉锯会让 Unity
黑屏。必须改 dex：

```sh
sh fix/patches/vrdesktop/apply_landscape_patch.sh [serial]
```

脚本会把设备当前 `com.huawei.hvrsdkserverapp` APK 拉下来，在 `classes4.dex`
的 `lockLandscape()` 里把 `const/4 v4, 0x1` 改成 `0x0`（字节码 `12 14` →
`12 04`，**只改 1 个字节** + 重算 DEX SHA1/Adler32），其余 404 个 APK 条目
逐字节不变，用同一 debug 密钥重签后 `pm install -r` 覆盖。

**实测结果（2026-11-07）**：`USER_ROT` 稳定为 0（框架自己写，无守护拉锯）、
日志 `VrSystemActor: display locked to landscape`、主屏 `real 1920 x 1080`
横屏、`clk[412180]` 不变、无 FATAL/ANR；眼镜里的左右眼画面由「竖屏中央
小窗」变成**横向铺满全屏**。

依赖 `python3`、`zipalign`、`apksigner.jar` 和一个 JRE（`apksigner` 需要 java；
本机可下载 Temurin JRE 17 解压到 `build/tmp/jre17/`，或用 `JAVA` 环境变量
指定）。路径可用 `ADB` / `JAVA` / `BUILD_TOOLS` 覆盖。原 APK 存在
`build/tmp/landscape/base.apk`，`adb install -r` 它即可回退。

> 注意：眼镜 USB 设备（`12d1:1092` / `12d1:107e`）掉线时
> `glass probe: usb=false`，VR 会话会判定眼镜不在位而退回桌面。这是物理层
> 问题，需要重新插拔眼镜 USB/电源，不是本补丁的回归。

## 八、眼镜面板激活与左右眼画面（2026-11-07 实测两处坑）

### 8.1 hidraw 编号漂移 → `/dev/hwvr1` 指错接口 → 眼镜面板不亮

`vrservice/WalleDev` 硬编码打开 `/dev/hwvr1`，激活命令
`HIDIOCSFEATURE(5)` 必须发到**控制接口**才能点亮眼镜面板。眼镜 USB
每次拔插都会重新枚举、hidraw 编号会变：

| 时刻 | hidraw0 | hidraw1 | 描述符特征 |
|---|---|---|---|
| 拔插前 | `12d1:1092` CV10 | `12d1:107e` 控制口 | 控制口 `06 ff 00`（Vendor，report 1 = 59B IMU） |
| 拔插后 | `12d1:107e` **控制口** | `12d1:107e` Consumer Control | 按键口 `05 0c` |

旧逻辑把 `/dev/hwvr1` 写死指向 `hidraw1`，拔插后指到按键口，于是
`DevHid: No Glass data` 723 次、`hidraw: passed too short report`、
`active device(2) OK` 出不来 —— **HDMI 有时序但眼镜面板不亮**。
现象就是「Android 主屏截图有 VR 画面，眼镜里却什么都没有」。

> **⚠️ 2026-11-08 修正：上面「前 3 字节 `06 ff 00` 即可识别」的表述不准确。**
> 真机枚举发现 **CV10 与控制口的前 3 字节完全相同**，只靠前缀会稳定选错
> （详见第十一章）。当前 `service.sh` 的判据已改为：

```sh
# 1) 候选仍限定 `06ff00`（排除 05 0c 按键口 / 05 01 Hub）
# 2) 用 hwvr-probe 真发 HIDIOCGFEATURE(4) 验协议应答：控制口 rc=0、CV10 rc=4
# 3) 没有 probe 二进制时退化为「描述符实际字节数最大者」（28B vs 68B）
```

`hwvr-probe` 源码在 `ksu/hwvr_compat/hwvr-probe.c`，编译产物随模块部署到
`/data/adb/modules/hvrglass/hwvr-probe`（install.sh 自动 chmod 755）。
旧注释里「`GET_FEATURE(4)` 在本机 hidraw0/1 都返回 0，区分不了」是误读：
**0 是进程退出码**（`ioctl` 返回 4 字节 = 成功），不是 ioctl 返回值。
另注意 sysfs 的 `stat -c %s report_descriptor` 恒为 4096，比长度必须用
`od -An -tx1 -v ... | wc -w` 读实际字节数。

一键体检：`sh fix/tools/hwvr1-check.sh [serial]`（只读，同时查两道闸）。

### 8.2 模拟辅助屏窗口叠影 → 左眼画面错乱

`VrPlatformCompat.externalDisplay()` 要求存在一块非 `DEFAULT_DISPLAY`
且 `STATE_ON` 的屏；盒子只有一块 HDMI（被安卓当内置屏），所以靠开发者
选项「模拟辅助显示设备」造辅助屏来满足在位判定。但该辅助屏是叠在主屏
合成里的系统窗口，内容是主屏的缩小镜像 → 递归叠影；**左眼正好落在
主屏左半**，就出现「左眼不对、右眼对」。反复改这个 setting 还会残留
多个旧窗口 layer，叠影越积越多。

一键安装现在幂等写：

```sh
settings put global overlay_display_devices 100x100/320
```

`100x100/320` 是实测能创建的最小尺寸：`externalDisplay=true` 仍成立、
VR 会话保持，窗口缩到几乎不可见，左右眼双目画面完整对称。
完全关掉（`settings delete ...`）会让 `externalDisplay=false` → VR 会话
判定眼镜不在位并退回桌面，**不要关**。

> 排障口诀：眼镜全黑 → 查 `/dev/hwvr1` 指向和 `active device(2) OK`；
> 左眼有叠影 → 查 `settings get global overlay_display_devices`；
> 主屏截图不等于眼镜面板输出，辅助屏那一路 `screencap -d <id>` 截不到。

## 九、手柄开机自动扫描补丁（2026-11-07）

### 9.1 原厂链路缺什么

`VRHandleService` 只处理 4 个 action（两个 `ACTION_RECONNECT_MSG`、
两个眼镜戴上/摘下），**没有任何扫描入口**。日志每 20 秒一次：

```
VrSystemActor: handle reconnect requested -> ...VRHandleService
VrSdkApi: enter getUsedDeviceList, mDeviceInfoList size = 0
ReconnectController: not connected to any device, skip
```

扫描逻辑全在配对页 `ScanningFragment`（UI）里。实测发
`ACTION_GLASS_AWAY_TO_NEAR` 也不会触发扫描（`Discovering: false`）。
盒子上 `shared_prefs` 空、`Bonded devices` 空 → 手柄从未入库，
「自动连接」无对象可连。项目里的自研 `shell/ControllerLink` 没编译、
设备上没装，所以只剩改 APK 这一条路。

### 9.2 补丁做了什么

新增 `AutoScanCompat`（smali），由 `VRHandleService.onCreate` /
`onStartCommand` 各调用一次 `kick()`：

- 用 vrhandle 自带的 BLE 扫描管理器 `t0/y0`（`R()` 自初始化单例），
  把 Service 已有的 `m` 字段（`VRHandleService$d` implements
  `BluetoothDeviceDiscoverCallback`）传给 `N(Lp0/c)` 启动扫描；
- 扫描回调里注入 `onDeviceFound`（见 9.5 第 3 层），纯后台完成
  连接 + 入库，不需要配对页 UI；
- **60 秒节流**：冷启动安排一次，之后 20 秒心跳每次检查，手柄晚开机 /
  休眠唤醒后下一轮自动被扫到；
- **延迟 3 秒**（`Handler.postDelayed`）：扫描必须晚于 `startForeground()`。
  直接扫的日志顺序是 `onScannerRegistered → Permission denial →
  show common foreground notification`，蓝牙栈把调用者判成后台；
- 全程 `try/catch`，任何异常都静默跳过，不影响 Service 原有流程。

只新增 1 个类 + 2 行调用，其余 863 个 APK 条目逐字节不变，
同密钥 v1/v2 重签，`pm install -r` 直接覆盖。

### 9.3 一键工具

```sh
sh fix/patches/vrdesktop/apply_autoscan_patch.sh 192.168.43.133:5555
```

自动完成：拉原包 → baksmali → 注入 → smali 回编译 → 替换 dex →
zipalign → apksigner v1/v2 → 证书一致性校验 → 安装 → 补授权 → 冷启动验收。
需要 JRE 17（可放 `build/tmp/jre17/`）、`tools/{baksmali,smali}-fat.jar`、
Android build-tools 34。设备上已是补丁版时，用
`BASE_APK=<未打补丁的原包> sh ...` 指定干净底本，回退镜像才可靠。

回退：`adb install -r build/tmp/autoscan/base.apk`。

### 9.4 开机链路

`magisk-module/modules/service.sh` 在 `boot_completed` 后拉起
`ArvrRuntimeService`，并在同一块里显式发一次 `ACTION_RECONNECT_MSG`
让开机立即扫（不用等首轮 20 秒心跳）；`install.sh` 的两处补拉也同步加了。
`grant-vr-perms.sh` 补三个定位/扫描 appops 与 `deviceidle` 白名单。

### 9.5 纯后台方案（2026-11-07 最终打通）

排障过程钉死了三层问题，逐层解决后**全自动、零 UI**：

1. **扫描时序**：扫描早于 `startForeground()` 会被蓝牙栈判后台，
   `Permission denial: Need ACCESS_FINE_LOCATION permission to get scan
   results`、`Total number of results: 0`。修法：`postDelayed(3s)`
   等前台通知起来再扫。
2. **「仅在使用期间允许」**：即使 pm granted=true，UID 级 appops
   `COARSE_LOCATION: foreground` 是系统按可见性动态给的，
   `appops set/reset/--uid` 都改不掉；可见 Activity 时拒绝消失，
   前台服务不够。**修法（纯后台关键）**：apktool 重编 Manifest，
   声明 `ACCESS_BACKGROUND_LOCATION`（原包没声明，`pm grant` 直接
   SecurityException），装好后 root `pm grant` 授「始终允许」，
   后台扫描立刻拿到结果。脚本 7/9 步自动完成，节点数 54→55，
   其余 863 条目逐字节保留。
3. **原厂入库链路断点**：扫到设备后 `N2 → v.w(DeviceInfo) →
   BluetoothManager.T0`，而 T0 要求的回调 `a$g` 只在配对页
   `ScanningFragment` 里经 `t0/i.q()` 注册 —— 纯后台恒为 null，
   设备被静默丢弃，`processDeviceDiscovered` 刷屏但永远不入库。
   **修法**：在扫描回调 `VRHandleService$d.a()` 里注入
   `AutoScanCompat.onDeviceFound(device)`：
   - `BluetoothManager.a1(DeviceInfo)` = 复刻「配对页点击连接」，
     经 vrservice 发起 GATT；
   - `VrSdkApi.h2(DeviceInfo)` = 入库 + 持久化到
     `shared_prefs/sp_device_storage`（注意 h2 的落盘 r2 只认
     `DeviceConnectState == 2`，须先 setDeviceConnectState(2)；
     真连接成功后原厂 `i2 → h2` 再入库，H0 去重幂等）；
   - 60 秒同址节流（扫描期间同一手柄每 ~500ms 广播一次）。

**实测结果（设备 Android 11 / vrhandle targetSdk=31）**：

```
AutoScanCompat: device found: HUAWEI CF20_45AB -> connect + persist
vrhandle_BluetoothManager: processDeviceConnectionStateChange, deviceState = 2
vrhandle_VrDeviceService: isWriteDescriptorSuccess = true
VrSdkApi: mDeviceInfoList size = 1
VrHandleReconnectController: device is already connected
bluetooth_manager: 00:39:34.399 CONNECTED f7:2d:dd:63:45:ab
shared_prefs/sp_device_storage.xml:
  F7:2D:DD:63:45:AB {mDeviceName:"HUAWEI CF20_45AB", mDeviceConnectState:2, ...}
```

入库持久化之后，**每次开机**由 20 秒 RECONNECT 心跳直接重连，
不需要扫描、不需要任何 UI；手柄没电/晚开机也只需下一次扫描窗口。

### 9.6 验收命令

```sh
# 补丁在跑 + 扫到设备
adb shell logcat -d | grep AutoScanCompat
#   kick: schedule BLE scan after foreground +3s
#   run: auto BLE scan (foreground ready)
#   device found: HUAWEI CF20_45AB -> connect + persist   ← 关键行

# 连接状态
adb shell logcat -d | grep -E 'deviceState = 2|mDeviceInfoList size|already connected'
adb shell dumpsys bluetooth_manager | grep -i 'CONNECTED\|f7:2d'   # MAC 各机不同

# 入库持久化
adb shell su -c 'cat /data/data/com.huawei.vrhandle/shared_prefs/sp_device_storage.xml'
```

手柄没广播时按一下电源键唤醒、别让它连着别的设备，下一轮 60 秒内会自动扫到。
回退：`adb install -r build/tmp/autoscan/base.apk`（回退后删掉
`shared_prefs/sp_device_storage.xml` 即完全恢复原厂行为）。

## 十、佩戴感应黑屏/亮屏 + 跳过 OOBE + 插眼镜自动进桌面（2026-11-08）

三个体验补丁，一次搞定：

### 10.1 佩戴感应（遮挡传感器 → 黑屏/亮屏）

**根因**：vrservice 的 `VRDeviceNodeMonitor`（读 `/dev/ttyUSB1` vcom 通道，
解析 PROXIMITY/HEADSET/BATTERY 缓冲帧）在 `onCreate` 里创建后**从不
start()**。原厂靠 `startHelmetMonitor()` 启动它，而那条链要求
`isVRHelmetConnectJNI()` 的 HID 初始化时序，本机永不触发 → 遮挡事件全断。

**修法**：`VRService.onCreate` 里 `iput-object mDeviceNodeMonitor` 之后补
`invoke-interface {v0}, Lcom/huawei/vrservice/monitor/VRMonitor;->start()V`
（start 有 mMonitorStarted 幂等保护，与 startHelmetMonitor 并存无害）。

- 一键工具：`patches/vrdesktop/apply_monitor_patch.sh`（拉包→baksmali→
  `inject_monitor_start.py` 注入→smali→replace_dex→zipalign→apksigner
  →安装→归档 `apks/com.huawei.vrservice.apk`）。
- 已知现象（不影响功能）：
  - `init proximity` 报 `get glass proximity fail!`：开机首读失败，
    传感器值变化时走 vcom 帧正常上报；
  - `BATTERY value: 0 → battery is below 5`：IoGetBatteryStatus 对本机
    走 Broken pipe，电量恒 0 触发的误告警，VR 不会被关。
- HWC 老毛病不变：**重启后眼镜面板不自动亮**，仍需手工
  `sh fix/light-on.sh`（不要把点亮写进开机脚本，手册第六章有血的教训）。

### 10.2 跳过手柄设置弹窗（OOBE），直达主页

OOBE 场景（`OOBESimpleScene`，3DoF 内嵌 Unity 场景）由 Unity PlayerPrefs
控制，免改 APK：

```
needShowOOBE / needShowPhoneOOBE / needShowNoloOOBE = 0
```

写在 `/data/data/com.huawei.vrlauncherx/shared_prefs/
com.huawei.vrlauncherx.v2.playerprefs.xml`。**必须先 force-stop 再改**，
Unity 退出时会用内存值覆盖 XML。install.sh 第 3 步已自动写入。
决策链（反编译 Assembly-CSharp.dll）：`WalleXSceneManager.NeedShowOobe()`
读 `needShowOOBE`（默认 1）→ TryToChangeScene 跳过 OOBESimpleScene 直达
HomeScene。想恢复引导改回 1 即可。

### 10.3 插入眼镜自动启动桌面

`magisk-module/modules/service.sh` 主循环里加状态机：控制接口（**协议探测
`hwvr-probe rc=0` + 描述符 `06 ff 00`**，见 8.1 修正）从不在位变在位 →
稳定 8 秒且 VRService 已在跑 → **先确认 `vr_system_state` 已发布**（缺失则
`force-stop` 并重启 `ArvrRuntimeService` 让它重发，最多 3 次）→ 再 `am start`
一次 `com.huawei.vrlauncherx/.MainActivity`；拔出复位，重插再拉。
开机时眼镜已插着也覆盖。日志在 `/data/local/tmp/hidraw_perm.log`
（"眼镜在位 → vr_system_state OK → 已拉起 VR 桌面"）。
加第二道闸的原因见第十一章：不查就直接拉桌面会 `CheckVrMode` SDK Quit。

### 10.4 验收

```sh
# monitor 在跑（读线程持有 ttyUSB1）
adb shell su -c 'ls -l /proc/$(pidof -s com.huawei.vrservice)/fd | grep ttyUSB1'
# 遮挡事件（戴上/摘下眼镜时）
adb shell logcat -d | grep -E 'buffer type: PROXIMITY|Helmet Up|Helmet down'
# 桌面自动拉起记录
adb shell su -c 'grep 拉起 /data/local/tmp/hidraw_perm.log'
```

**⚠️ light-on 之后眼镜黑屏、无画面（2026-11-08）**：`light-on.sh` 会
`stop/start surfaceflinger`，SF 重启会把**已运行** launcher 的 Unity
SurfaceView 缓冲队列打废（logcat 每帧 `requestBuffer failed BAD_VALUE`），
眼镜面板 ACTIVE 但全黑。修法：点亮后 `am force-stop com.huawei.vrlauncherx`
再 `am start`，Unity 重建 surface 即恢复（实测闭环）。所以正确顺序是
**先点亮、再（重）启桌面**——守护脚本的自动拉起已天然满足（开机顺序）。

---

## 十一、两道软件闸：桌面起不来 / 眼镜黑屏（2026-11-08 真机复核）

> 完整取证链见 `fix/2026-11-08-眼镜黑屏排查分析.md` 第七、八章，日志
> `build/tmp/analysis-1108-*.log`。**本章结论推翻第四章「MCU 卡死、需拔插
> USB」的旧判断**。

### 11.1 「拔了又插眼镜还是黑屏」的答案

拔插**不解决问题**，因为根因在软件：`service.sh` 每 3 秒重跑一次错误的
选点判据，每次拔插都把 `/dev/hwvr1` 重新指回 CV10。现场
`/data/local/tmp/hidraw_perm.log` 记录了拔插当刻：

```
03:08:15  hwvr1 清除（控制接口不在位）
03:08:18  hwvr1 -> /dev/hidraw0 (control iface)   ← 拔插后立刻又指错
```

### 11.2 闸 1：`/dev/hwvr1` 指向 CV10 而非控制口

| 节点 | HID_ID | 描述符前 3B | 实际长度 | report 1 | `hwvr-probe` |
|---|---|---|---|---|---|
| `hidraw0` | `12d1:1092` CV10 | `06 ff 00` | 28 B | **1 B** | `rc=4` 失败 |
| `hidraw1` | `12d1:107e` input3（控制口） | `06 ff 00` | 68 B | **59 B IMU**，另有 feature id4 = 127 B | `rc=0` 成功 |

`docs/HELMET_HID_PROTOCOL.md` 定死 `ioGetVendorInfo()` = `HIDIOCGFEATURE(4)`、
`buf[0]=1`，发到只有 1 字节 report 1 的 CV10 必然失败。旧判据
「前缀 `06ff00` + `break` 取第一个」永远选中 hidraw0。后果：

```
E DevHid: ioGetVendorInfo failed, ret(-1)
E DMManager: dev WalleDev open error → loadDevLibs WalleAlg error
I Unity_HVRRenderMgrCore: OnApplicationQuit()
```

且 `active device(2) OK` 一次都不出现 —— 激活命令发不出去，**面板不亮**。
`vendorId=0` 是失败结果（`WalleCommon::mVendor` 进程内缓存），不是原因，
也不是 MCU 卡死。停掉 vrhandle 的实验已排除「hidraw 进程竞争」。

### 11.3 闸 2：`vr_system_state` binder 未发布

修好闸 1 后 Unity 仍退出：

```
W HvrSdkBridge: vr_system_state binder not published yet
I UnityPlugin: CheckVrMode, is not VRMode, exit
E Unity_HVRRenderMgrCore: CheckVRMode FAIL, SDK Quit
```

注册表 `VrSystemRegistryProvider` 是 **launcherx 进程内的 static Map**，
`force-stop` 桌面 / 拔插引起的进程重建会清空它；`HvrStatePublisher` 只在
`ArvrRuntimeService` 启动握手时发布一次，不会补发。实测查询：

```sh
adb shell content call --uri content://com.huawei.vrlauncherx.registry \
  --method getService --arg vr_system_state
# Result: null                     ← 未发布（闸 2 未通过）
# Result: Bundle[{binder=...}]     ← 已发布
```

实验 D（先重启 `ArvrRuntimeService` → 再启动桌面）20 秒窗口内
`OnApplicationQuit=0`、栈顶稳定 `.MainActivity`，反向印证两道闸。

### 11.4 已固化到工具链的改动

| 文件 | 改动 |
|---|---|
| `magisk-module/modules/service.sh` | 选点改为「`06ff00` 候选 + 描述符实际长度、取最大者」，去掉 `break`；拉桌面之前查 `vr_system_state`，缺失则重启 Runtime 重发（最多 3 次）；**11.8 二次修正：守护主循环不再发任何 USB 请求** |
| `magisk-module/modules/hwvr-probe` | 新增（从 `ksu/hwvr_compat/` 复制随模块部署） |
| `install.sh` | step 2 增加 `chmod 755 hwvr-probe` |
| `patches/vrdesktop/fix_battery_noop.py` | 补写（此前只在分析文档里被引用、未落盘）；幂等 no-op 化 `processBattery` 的 below-5 / below-20 两分支，已在两种 smali 变体上验证 |
| `patches/vrdesktop/apply_monitor_patch.sh` | 6 步 → 7 步，把 battery no-op 并入一键重打包 |
| `tools/hwvr1-check.sh` | 新增只读体检脚本，一次查完两道闸 |

### 11.5 验收

```sh
# 只读体检（两道闸都应 [OK]）
sh fix/tools/hwvr1-check.sh 192.168.43.133:5555

# 守护改链接记录应出现判据标记（新版本 descLen，旧版本 probe+rank）
adb shell su -c 'grep -E "descLen|probe\+rank" /data/local/tmp/hidraw_perm.log | tail -3'

# 桌面启动链：无 ioGetVendorInfo failed、无 OnApplicationQuit
adb shell logcat -c
adb shell am start -n com.huawei.vrlauncherx/.MainActivity
adb shell logcat -d | grep -E 'ioGetVendorInfo|dev_open|OnApplicationQuit|CheckVrMode|active device'
```

**不再需要**：物理拔插眼镜 USB、MCU 断电复位、USB `unbind`/`bind` 自动重枚举。

### 11.6 「VR 桌面里打开应用就退出」/「长按主页键回不去」

实测时间线（`build/tmp/analysis-1108-openapp.log`，设备 03:27:17–03:27:46）：

```
03:27:17  am start 桌面             → Displayed +4s794ms
03:27:27  START com.sparkfox.sportsdeviceserver/.ActivityToStartService（包已不存在）
03:27:29  HwVrLauncherX_MainActivity: onPause
          → Unity OnApplicationQuit → HVR_ShutdownRenderThread
          → HvrFramework::Deinit → VrFramework: finish all activity
          → ForceProcessExit → "Process com.huawei.vrlauncherx has died: fg TOP"
03:27:31  am start 投屏 Vr2dStartUpActivity → HvrMirrorActivity
          → com.android.systemui/.media.MediaProjectionPermissionActivity（2D 授权框）
03:27:32  VrSystemActor.refresh(displayAdded) → HvrStatePublisher: published vr_system_state: true
03:27:33  VRService 重拉 VRPrepareActivity → 03:27:40 重新 Displayed MainActivity
03:27:46  CheckVRMode PASS（这次才真正进 VR 模式）
```

四条结论：

1. **桌面不是退到后台，是被 SDK 主动杀进程**。`onPause` → `finish all activity` →
   `ForceProcessExit` 是 HVR 原厂「单 VR 应用独占」设计；任何抢焦点操作
   （启动别的 Activity、系统权限框、Home 键）都会触发。桌面自杀甚至发生在
   **启动投屏之前**，所以「打开应用才退出」是表象。
2. **投屏最容易触发**：免 root 实现 `HvrMirrorActivity` 首次会弹
   `MediaProjectionPermissionActivity`（2D 系统界面），必然把桌面挤到 onPause。
3. 桌面进程一死，`VrSystemRegistryProvider`（进程内 static Map）随之清空，
   `vr_system_state` 回到 `Result: null`；`HvrStatePublisher` 只在 Runtime
   handshake 时发一次，不会补发 → 重新 `am start` 也会 `CheckVrMode` SDK Quit。
   **守护已补 15 秒周期巡检 + 60 秒限频重发**（见 11.4），只修 binder、
   不强行把桌面拉回前台，避免打断正在用的投屏。
4. **长按 Home 本来就不是回桌面**：原厂语义是「单击 <1s → 进 VRLauncher，
   长按 ≥1s → 视点重置」（`docs/reference/vr-engine/00-索引与对移植的意义.md` 1.3）。
   且桌面进程已被杀，按键事件落在当前 2D 焦点窗口，根本没有可返回的 VR 桌面。

回桌面（短按 Home <1s，或命令行）：

```sh
adb shell content call --uri content://com.huawei.vrlauncherx.registry \
  --method getService --arg vr_system_state   # 应为 Bundle[{binder=...}]，null 就等守护巡检
adb shell am start -n com.huawei.vrlauncherx/.MainActivity
```

要根治二选一：① 按 `docs/CAST_NOROOT.md` 第 5 步**预先完成 MediaProjection
授权**，让投屏不再弹 2D 授权框；② 改 launcherx 的 Unity 退出策略，让
`onPause` 走后台而不是 `ForceProcessExit`（需改 SDK/Assembly-CSharp，风险高，
未做）。

### 11.7 USB 重枚举瞬态不是故障

眼镜会自行掉线重枚举（`USB disconnect` → `Added device`，实测 03:23:51 /
03:24:01 / 03:25:13 各一次），期间 hidraw 节点重建、编号可能整体漂移，
`report_descriptor` 会短暂读成空 —— 此刻 `hwvr1-check.sh` 会误报 FAIL，
**等 3~10 秒重跑即可**。守护的判据不依赖编号：重枚举后真控制口从
`hidraw1` 变成 `hidraw0`，日志仍记录 `probe+rank=10068` 并正确跟随。
USB 重枚举会连带清空注册表，11.4 的周期巡检同时覆盖这一场景。
旧日志标记 `probe+rank=10068` 是第一版守护（每轮发 GET_FEATURE，已废弃，
见 11.8），新版本日志标记为 `descLen=68`。

### 11.8 「一进 VR 桌面就闪退」（2026-11-08 第三轮，已修）

现象：桌面一进去就退回系统 Launcher，进程 pid 每 4~5 秒换一次。
取证见 `build/tmp/analysis-1108-crash-onenter.log` / `crash-fixed.log`。

```
内核  usb usb1-port1: disabled by hub (EMI?), re-enabling...
      usb 1-1 / 1-1.1 / 1-1.2 / 1-1.5: USB disconnect   ← 整条 hub 掉线
      generic ttyUSB0..2: converter now disconnected
框架  UsbHostManager: Removed device ... HUAWEI GLASS CV10 / HID
      VrPlatformCompat: glass probe: usb=false externalDisplay=true
      HvrVrSystem: isVRmode failed
      VrMonitor: checkVRMode fail, isVRGlassDevExist:false  isVRMode:false
      VRService_Client_VRPrepareActivity: PrepareActivity Quit!
系统  ActivityManager: Process com.huawei.vrlauncherx (pid N) has died: fg TOP
```

`VrPlatformCompat.hasGlassUsbIdentity()` 遍历 `UsbManager.getDeviceList()`
找 `12d1:1092` / `12d1:107e`；EMI 重枚举窗口里设备全消失 → 判 false →
`VrMonitor.checkVRMode()` 凑够 2 个失败项 → SDK 自杀。随后系统/VR 服务又
把 MainActivity 拉起（本次日志 `START u0 ... from uid 10074` 共 57 次），
形成「一进就闪退」循环。**不是 FATAL/ANR（本次 0 次），也不是闸 2 缺失**。

**加剧因素是上一版修复的回归**：11.4 第一版让守护每 3 秒对所有 `06ff00`
候选各发一次 `hwvr-probe`（`HIDIOCGFEATURE(4)` control transfer），等于
持续刺激 USB 总线。A/B 各 60 秒：

| 组 | DEVNUM 变化 | hidraw=0 | 栈顶 |
|---|---|---|---|
| `kill -STOP` 冻结守护 | 1 次（007→011） | 0 | 稳定 |
| 恢复旧守护 | 3 次（019→023→027） | 每次都出现 | 每次掉回 `com.droidlogic.mboxlauncher` |

修复（已推设备、已验收）：

1. 守护选点改**纯 sysfs**：只读 `report_descriptor` 前 3B + 实际字节数，
   取 68B 的控制口（CV10 只有 28B）。零 USB 请求，且编号漂移也能跟随
   —— 实测重枚举后正确选到 `hidraw0 (descLen=68)`。`hwvr-probe` 保留在
   模块里，仅供 `hwvr1-check.sh` 手动一次性验证。
2. hidraw 全消失时给 3 轮（约 9s）宽限才认定「眼镜拔出」，避免守护跟着
   EMI 抖动摘链、反复重置拉桌面状态机。

验收（03:50:04–03:52:11，每 6 秒采样共 16 次）：DEVNUM 恒 `043`（0 次
重枚举）、hidraw 恒 3、`vr_system_state` 恒 `binder=`、`checkVRMode
fail=0`、`PrepareActivity Quit=0`、`OnApplicationQuit=0`、16/16 次栈顶
`.MainActivity`。内核最近一次 EMI 在 uptime 8605，采样窗口内无新增。

> 硬件侧提示：`disabled by hub (EMI?)` 是 hub 端口因信号质量/供电波动被
> 禁用重连，属线缆、Type-C 转接、hub 供电或环境干扰范畴。软件修复消除了
> 「每次抖动都闪退」，但如果 EMI 事件本身仍频繁，画面仍可能短暂黑一下；
> 要彻底消除需检查线缆与供电。

### 11.9 闪退复发：框架层 USB 瞬态宽限（2026-11-08 第四轮，已修）

11.8 去掉守护的 `GET_FEATURE` 后，04:19 与 04:41–04:42 仍出现
`disabled by hub (EMI?)` 抖动，桌面又走了一遍：

```
usb 1-1 / 1-1.1 / 1-1.2 / 1-1.5: USB disconnect
VrPlatformCompat: glass probe: usb=false externalDisplay=true
VrMonitor: checkVRMode fail, isVRGlassDevExist:false  isVRMode:false
VRService_Client_VRPrepareActivity: PrepareActivity Quit!
Process com.huawei.vrlauncherx (pid N) has died: fg TOP
```

**关键点**：设备上的 launcherx 跑的是我们 patch 过的
`VrMonitor.isVRGlassDevExist() → VrPlatformCompat.isVrGlassPresent()`，
判据是 `UsbManager.getDeviceList()` 里有没有 `12d1:1092` / `12d1:107e`
，**不是** `/dev/hwvr1` 文件。EMI 窗口里 USB 设备全消失，列表必然为空，
所以 11.8 的纯守护侧改动挡不住这一下。

修复必须两层同时部署：

| 层 | 文件 | 改动 |
|---|---|---|
| 框架 | `patches/vrdesktop/fix_glass_grace.py` + `apply_glass_grace.sh` | patch launcherx 的 `classes4.dex` 里 `VrPlatformCompat.hasGlassUsbIdentity()`：UsbManager 枚举不到时回退华为**原版**判据 `new File("/dev/hwvr1").exists()` |
| 守护 | `magisk-module/modules/service.sh` | hidraw 全消失的 3 轮宽限内，用**占位普通文件**顶住 `/dev/hwvr1`（断链 symlink 的 `File.exists()` 是 false）；真拔出时清除 |

一键重出包（拉底本 → baksmali → patch → smali → 替换 dex → zipalign →
重签 → `pm install -r`）：

```sh
sh fix/patches/vrdesktop/apply_glass_grace.sh 192.168.43.133:5555
```

产物归档 `fix/apks/com.huawei.vrlauncherx.glass-grace.apk`（与现包同
`hvr-compat-debug.jks` 签名），原包备份在
`build/tmp/glass_grace/base.orig.apk`。安装会 force-stop 桌面并清空注册表，
守护的 15 秒巡检会自动重发 `vr_system_state`。

**验收**（04:38–04:42，3 分钟 / 90 次采样，期间 `disabled by hub` 8 次、
`USB disconnect` 43 次）：`checkVRMode fail=0`、`PrepareActivity Quit=0`、
`OnApplicationQuit=0`；守护日志出现 `[EMI 宽限] /dev/hwvr1 占位`，节点
回来后自动换回 `hwvr1 -> /dev/hidraw2 (descLen=68)`（编号漂移照常跟随）。

**剩余现象不是闪退循环**：EMI 抖动时系统会连带杀 `com.huawei.vrservice`
与 `com.huawei.vrlauncherx`（`Scheduling restart of crashed service ...
VrParamsProviderService`、`Killing ... ArvrRuntimeService`），栈顶短暂回到
`com.droidlogic.mboxlauncher`，3~8 秒后 VRService 自动重拉桌面。这属于
USB 链路层的进程级联，软件只能缩短恢复、消不掉抖动本身。

> **EMI 根因线索（未修）**：`/sys/class/udc` 为空、`sys.usb.controller`
> 为空、`g1/UDC` 为空，但 `sys.usb.config=adb` —— ROM 的 USB gadget 配置
> 残缺。adbd 每秒 `FUNCTIONFS_BIND` 超时重建连接，init 每秒写
> `/config/usb_gadget/g1/UDC`（60 秒日志内分别 63 次 / 254 次），怀疑持续
> 扰动 USB 控制器。修它要动系统属性，**有中断无线 adb 的风险，未做**，
> 需现场确认后再试。硬件侧仍需检查线缆、Type-C 转接与 hub 供电。

### 11.10 6DoF 与 3DoF 是两条独立链路（2026-11-08 用户纠正）

> 用户指出 **HUAWEI CF20 是 3DoF 手柄**，要求回 `系统/` 核对原厂怎么识别 6DoF。
> 核对后确认：此前把 `Huawei 6Dof ... is false` 当作「手柄掉线」是错的，
> 两者毫无关系。依据 `docs/6DoF-为什么没起来.md` 第五章与
> `build/tmp/ctxa/dexdump/hvrfw/com/huawei/vrframework/VrParamsRequester.smali`。

**6DoF（设备 = `12d1:3a09` 6DoF Gaming Kit Par-CG012 / Omnivision 双目 UVC）**
识别不在内核、不按 VID/PID、也不走蓝牙，而在上层 Java：

```
VrParamsRequester.isHW6DoFAvailable(int index)  // smali 第 162 行
  ① mRuntimeInterface (ArvrRuntimeInternalInterface) != null   // null 直接 return false
  ② getCurrentDevices() 返回的 List<DeviceInfo>.size() == 3     // 头 + 左 + 右
  ③ list.get(index).getDeviceState() == 1
  index: 0 = Header(Huawei 6Dof Header) / 1 = left / 2 = right
  左右都 true 才整体 true（smali 第 608-619 行）
```
数据链：USB UVC `class 0e/02`(VideoStreaming) → `/dev/video14/15`
→ HiVRAR HAL（`系统/tree/system/system/lib64/libhivrar_service.so`、
`vendor.huawei.hardware.hivrar@2.x.so`）→ VIO 位姿 → `ArvrRuntimeService`
的 `getCurrentDevices()`。`系统/` 里这些 HAL/so **没有任何 `6DoF`/`CF20`
字面量**，判定全在上层；`hvrsdkserverapp` 里也没有 `BluetoothGatt`。
绑定动作是 `VrParamsRequester.bindRuntimeService()` 用 action
`com.huawei.hvrsdkserverapp.service.ACTION_GET_INTERNAL_INTERFACE` 去
`bindService`，`ArvrRuntimeService.onBind()` 校验
`com.huawei.android.permission.VR` 后返回 binder。
（旧记录写的是 `RUNTIME_ALLOW` 权限，11.14 已实证更正：两个权限在设备
上都是 `granted=true`，且 `onBind` 的 `isVrMode` 判断早已 patch 成常量
true；断点不在这里。）

**3DoF（设备 = HUAWEI CF20 / BLE）**：`com.huawei.vrhandle` 按广播名
`contains("CF20_3DOF")` 过滤，私有 GATT `622f5b2a` / `ffb4a651`，入库
`shared_prefs/sp_device_storage.xml`。与 6DoF 完全独立，见第九章。

**真机实测（2026-11-08 05:24–05:26）**

| 项 | 结果 |
|---|---|
| 6DoF 模组 USB | `1-1.3:1.0` = `0e 01`(VC)、`1-1.3:1.1` = **`0e 02`(VS，齐了)**、`1-1.3:1.2` = `03 00`(HID) |
| 6DoF 视频节点 | `/dev/video14`、`video15` = `6DoF Gaming Kit Par-CG012: 6DoF`，权限 666（守护改的） |
| 6DoF 仍判 false | **`mRuntimeInterface == null` 783 次** —— `isHW6DoFAvailable()` 第一行就 return false，与摄像头是否通无关 |
| CF20 手柄 | `05:24:35 CONNECTED f7:2d:dd:63:45:ab`、`device is already connected`、`Controller Disconnected=0` → **已连接** |
| 复核瞬态 | 稍后再查整条 USB 下游消失（只剩 4 个 root hub，`hidraw=0`、`video=0`），属 11.7 的间歇重枚举 |

所以 `Huawei 6Dof ... false` 是本机**既有状态**（手册 8.3 已定性为 3DoF
眼镜的分支噪声），不能拿来解释「应用打不开」。真正的第三个缺口是
`ACTION_GET_INTERNAL_INTERFACE` binder 没绑定成功（手册 8.4 提到的
`onBind()` 死代码另一半），尚未修。

**「ALVR / 其他应用打不开」复核**：`am start` 下 ALVR、应用市场、华为视频、
投屏 **4 个全部 `Status: ok` 并驻留**，`FATAL=0`、`ForceProcessExit=0`；
桌面 UI 正常渲染、图标齐全。但 `input tap` / `keyevent` 均 `START u0=0`,
`launchApp=0`，同时 `HVRInputModule.UpdateAnchorPos` 持续空引用、
`WalleDev: No Glass data` 刷屏 → 射线指针命中判定异常。adb 触摸/按键不映射
手柄射线，**需用户用手柄实点一次图标、同步抓 logcat** 才能区分
「输入没收到」与「启动被拦」。应急启动见 11.11 的工具。

### 11.11 两个只读/应急工具

```sh
sh fix/tools/vr-input-check.sh 192.168.43.133:5555          # 分 A(6DoF) / B(CF20) / C(Unity 射线) 三段体检，只读
sh fix/tools/open-vr-app.sh   192.168.43.133:5555 list       # 列出所有 VR 包与真实入口
sh fix/tools/open-vr-app.sh   192.168.43.133:5555 alvr       # 不依赖手柄，直接开 ALVR
```
各包入口不是 `MainActivity`（写死会报 `Activity class does not exist`），
脚本用 `cmd package resolve-activity --brief` 动态解析。别名：
`desktop / alvr / market / cast / himovie / youku`。
USB 重枚举瞬态会让 6DoF 探测读数为空，脚本自动隔 3 秒复采一次。

### 11.12 「VR 桌面里打开应用，怎么没在桌面里显示」——显示承载链（2026-11-08 傍晚）

**和 11.10 的输入链、前几章的启动/闪退链都不同**：这里应用进程、Activity
全部正常（`am start` 下 ALVR / 应用市场 / 华为视频 / 投屏都 `Status: ok`
并驻留），只是**画面没有出现在眼镜里的 VR 桌面 3D 空间**。

VR 桌面是 Unity 3D 场景，2D 应用不会因为「进程起来了」就自动显示。移植版
复刻的是 EMUI 原厂三段式显示链（设计见 `docs/PROJECT_STATUS.md` 第 8/9 条、
`docs/PATCH_AUDIT.md` 65.3，代码在 `shared/java/com/huawei/vrframework/compat/`）：

| 环 | 实现 | 作用 |
|---|---|---|
| ① | `HvrVrPanelPresenter.start()` | 在 `VrPlatformCompat.externalDisplay()` 找到的副屏上起 `Presentation` + 全屏 `SurfaceView` |
| ② | `HvrVrVirtualDisplay.ensure()` | `surfaceCreated` 时建 **3200×1600** 的 `HUAWEI VR Display` 虚拟屏，输出到 ① 的 Surface |
| ③ | `HvrDisplayRouter.applyVrDisplay()` | 启动应用时 `ActivityOptions.setLaunchDisplayId(vrDisplayId)`，把 Activity 路由到 ②；画面合成进 Presentation → 出现在眼镜里 |

**现场三处断点（2026-11-08 18:35 实测）**：

- ② 缺失：`dumpsys display` 只有 0 内置屏 1920×1080、1 `Overlay #1` 100×100、
  2/3 `HW-VR-Cast-0/1` 各 **50×28**；**`HUAWEI VR Display` 计数 = 0**。
  历史日志每次打开应用都伴随
  `HvrDisplayRouter: HUAWEI VR Display not up yet, keeping the original launch options`
  （`analysis-1108-openapp.log` 03:27:33、`-crash-onenter.log` 03:36:50、
  `-recheck-1719.log` 04:19:38），即 ③ 每次都放弃路由。
  `HvrVrPanel` 日志全库 0 条 → ① 的 Presentation 从未成功挂上。
- 应用窗口全在 `displayId=0`（`dumpsys window displays`：`Display: mDisplayId=0 stacks=3`，
  2/3 都是 `stacks=0`；SurfaceFlinger layer 的 `Root#0` 含 mboxlauncher / ALVR /
  appmarket）。没有可路由的目标，也没有任何窗口被放进 VR 面板。
- ③ 的平台权限前置也没做：`docs/PROJECT_STATUS.md` 第 9 条已记录，普通应用建的
  虚拟屏 `isTrusted()=false`，跨应用 `setLaunchDisplayId` 会被
  `isCallerAllowedToLaunchOnDisplay` 拒，必须靠 LSPosed 模块
  `com.hvr.displayrouting` hook 放行；阶段 2 状态是「已构建安装、**待启用**」。
  实测设备 `/data/adb/lspd` 空、`pm list packages` 无 LSPosed、
  `/data/adb/modules/` 只有 `hvrglass` 与 `wadb` —— **模块至今没装、没启用**。
  （这条只对「Runtime 建屏、桌面启动」的跨进程路径成立；11.13 的
  panel-bootstrap 让启动方自己建屏，桌面自己拉起的应用不需要该模块。）

**`overlay_display_devices` 的取舍**：反编译 `vrvirtualscreen` 的
`HvrMirrorService.showMirror()` 确认，双目镜像屏尺寸按
`scale = min((副屏宽/2)/1920, 副屏高/1080)`、`eye = round(主屏尺寸 × scale)`
从副屏推导。当前 `100x100/320` → 每眼 **50×28**，与实测完全吻合，历史日志
`mirror overlay shown on display 1 (Overlay #1) 100x100, eye 50x28` 也是这个值。
手册 7.4 的成功态是 `1920x1080/320` + 608×1080 双目虚拟屏。
100×100 是第九章为了消除左眼叠影特地压小的（辅助屏是主屏缩小镜像、会递归叠影），
**副作用就是把 SBS 投屏面板一起压成空壳**。两个目标冲突，需二选一或分离职责
（小屏只做在位判据、另建独立大屏做面板）。

**修复顺序**（本轮只做诊断，未动设备设置 / 未装框架级组件）：

1. 让 ① 跑起来：确认 `ContextEx.currentApplication()` 非 null、
   `externalDisplay()` 能找到副屏；给 `HvrVrPanelPresenter.start()` 一个
   可靠的启动时机（当前只在 `applyVrDisplay()` 里被动触发）。
2. 把 `overlay_display_devices` 调大或分离出独立面板副屏，让 ② 有可用尺寸。
3. 安装并启用 `lsposed/out/com.hvr.displayrouting-r2.apk`，作用域勾
   「系统框架(android)」+ 七个包，重启；用
   `lsposed/verify-display-routing.ps1` 验收。判据见 `docs/PROJECT_STATUS.md` 第 8 节：
   `dumpsys display` 有 `HUAWEI VR Display 3200x1600`、
   `dumpsys window` 里眼镜 display 上有 `ty=PRESENTATION` 窗口、
   日志出现 `vr activity routed to display N`。
4. 眼镜 USB 必须在位（本轮取证时整条下游掉线：`hidraw=0`、
   `vr_system_state=null`，只剩 4 个 root hub）。

只读体检：

```sh
sh fix/tools/vr-display-check.sh 192.168.43.133:5555
```

分 A(Display 全景) / B(窗口归属) / C(overlay 与每眼推算) / D(路由日志) /
E(LSPosed 模块) / F(USB 在位) 六段（11.13 后增加 G 段启动时机），直接给出缺哪一环。
应急打开应用仍用 `fix/tools/open-vr-app.sh`（11.11）。

> 别混淆：`ACTION_GET_INTERNAL_INTERFACE` 那个 binder 缺口（11.10）是 **6DoF 位姿**，
> 和这里的显示承载链是两条独立的线。

### 11.13 接通 ①/②：进程启动预建「HUAWEI VR Display」（2026-11-08 第五轮）

11.12 把 ② 缺失归因为「① 未被触发」，本轮定位到**具体原因并修好**，且证实
**桌面自己拉起的应用不需要 LSPosed**。

**两个硬伤**（都在 `HvrDisplayRouter.applyVrDisplay()` →
`HvrVrPanelPresenter.start()` 这条唯一调用链上）：

1. `applyVrDisplay()` 先取 `ContextEx.currentApplication()`，取不到就走
   `if (context != null && start(context))` 短路。现场
   `HvrServiceManagerEx: no application context` 证明该值确实可能为 null；
   这正好解释 11.12 里「`HvrVrPanel` 日志全库 0 条」—— `start()` **一次都没被调用**
   （它是唯一完全不打日志的返回路径）。
2. 就算 `start()` 跑起来，`window.show()` 之后 `SurfaceView.surfaceCreated` 是
   **异步**回调，同一次调用里 `HvrVrVirtualDisplay.displayId()` 必然还是 -1，
   于是当次打印 `not up yet`、应用落到 `displayId=0`。而 `applyVrDisplay()`
   只在桌面内部 `z0/c.B(Context, Class)` 打开页面时被调用（adb `am start`
   根本不走这条路，与 11.11 的 `launchApp=0` 一致）——用户每点一次图标都在
   「第一次」，永远等不到第二次。

**修法**：把建屏时机前移到进程启动。
`fix/patches/vrdesktop/fix_panel_bootstrap.py` 只改 launcherx 的
`classes4.dex` 里 `HvrContextProvider.onCreate()`，在平台保证非 null 的
`getContext()` 上，对 **com.huawei.vrlauncherx 进程**补一次
`HvrVrPanelPresenter.start(context)`：

```text
provider onCreate → Presentation.show() → surfaceCreated (异步)
  → HvrVrVirtualDisplay.ensure() → HUAWEI VR Display 3200x1600
  → 之后任意一次 applyVrDisplay() 读 displayId() 都 >= 0 → setLaunchDisplayId 生效
```

屏由**启动方自己**创建（owner uid 与 `setLaunchDisplayId` 调用方相同），
`isCallerAllowedToLaunchOnDisplay` 直接放行，因此绕开了 11.12 第 3 条
「必须装 LSPosed」的前提。LSPosed 模块只对「Runtime 建屏、别的进程启动」
的跨进程场景才是必需的。

**部署**（一键脚本从设备当前 APK 拉底本，保留 glass-grace 等既有补丁，
幂等、重签后 `pm install -r`；原包自动备份）：

```sh
sh fix/patches/vrdesktop/apply_panel_bootstrap.sh 192.168.43.133:5555
```

**真机验收**（补丁安装后进程稳定那一次，完整跑通 ①+②）：

```text
I HvrVrPanel : panel presentation shown on display 1 (Overlay #1)
I HvrPanelBoot: panel presenter bootstrapped at provider onCreate
I HvrVrPanel : panel surface created
I HvrVrDisplay: HUAWEI VR Display created: displayId=4 3200x1600

dumpsys display:
  DisplayDeviceInfo{"HUAWEI VR Display": 3200x1600, 320dpi,
    state ON, type VIRTUAL, owner com.huawei.vrlauncherx (uid 10074),
    FLAG_PRESENTATION, FLAG_OWN_CONTENT_ONLY}
dumpsys window displays: Display: mDisplayId=4 stacks=0
```

**边界（本轮无法做视觉验收）**：取证时眼镜物理离线（`hidraw=0`、
`/dev/hwvr1` 不存在、`vr_system_state=null`），`VrMonitor.checkVRMode` 每约
4.3 秒杀一次桌面（pid 24612→24709→…→25080）。此时每次 provider onCreate
都能成功 `show()`，但进程活不到 `surfaceCreated`，虚拟屏建不起来。
这是**既有闪退链**，不是本补丁缺陷：插回眼镜、桌面进程稳定后即自动恢复。
手动 `touch /dev/hwvr1` 做 A/B 也稳不住（`isVRGlassDevExist` 仍 false，
说明 `VrMonitor` 还有别的判据），实验后已删除该临时节点。

**副屏尺寸职责分离**（11.12 第 2 条）：新增只读/可回滚的档位脚本，
不默认改设备：

```sh
sh fix/tools/vr-overlay-mode.sh 192.168.43.133:5555 show     # 现状 + 每眼推算
sh fix/tools/vr-overlay-mode.sh 192.168.43.133:5555 panel    # 1920x1080/320 → 每眼 608x1080
sh fix/tools/vr-overlay-mode.sh 192.168.43.133:5555 dual     # 100x100 + 1920x1080 两块
sh fix/tools/vr-overlay-mode.sh 192.168.43.133:5555 restore  # 回滚（修改前自动备份）
```

`100x100/320` → 每眼 50×28，SBS 面板是空壳；调大可能重新引入第九章的左眼
叠影，所以两者是取舍。`dual` 目前只分离出两块屏，**尚未**让大屏被选中：
`VrPlatformCompat.externalDisplay()` 和 `HvrMirrorService` 的
`HvrPanelFinder` 都取第一块非默认 display，需要另 patch 按面积优先。
改 overlay 会触发 DisplayManager 重建副屏 → Presentation dismiss → 虚拟屏
释放，需重启 VR 桌面让 panel-bootstrap 重建。

`vr-display-check.sh` 同步增强：A 段改为精确统计 `DisplayDeviceInfo` 行
（旧写法把 1 块数成 5 块）并打印 owner；新增 G 段统计
`HvrPanelBoot` / `shown` / `surface created` / `created` / `checkVRMode fail`，
结论速查能区分「补丁没装」「补丁已装但眼镜离线」「补丁已装且眼镜在位却仍失败」。

**仍需现场配合的剩余项**：

1. 插回眼镜，用手柄在桌面里实点一个图标，抓
   `HvrDisplayRouter: vr activity routed to display N` 并确认应用
   `mDisplayId != 0`——这是 ③ 的最终视觉验收（adb `am start` 触发不了 `B()`）。
2. 若要让 `dual` 生效，patch `externalDisplay()` / `HvrPanelFinder` 按面积选大屏。
3. 跨进程（Runtime 建屏）路径仍需按 `docs/PROJECT_STATUS.md` 第 9 条启用
   LSPosed 模块；该操作涉及刷框架组件 + 重启，**未执行**，需用户确认。

### 11.14 眼镜不点亮 / 6DoF 激活指令 / 面具插件能做什么（2026-11-08 第六轮）

用户追问「眼镜没点亮」「6DoF 手柄是不是需要激活指令」「改用面具插件不行吗」。
本轮把三条线合到一起，结论是**它们指向同一个循环依赖**。

#### 眼镜点亮的激活链（现场实证）

```text
/dev/hwvr1 -> hidraw1 (descLen=68, 12d1:107e 控制口)   ← 守护选点正确
  -> libWalleDev.so ioGetVendorInfo(): HIDIOCGFEATURE(4) / report 1
  -> 激活命令 HIDIOCSFEATURE(5)
  -> 日志 "active device(2) OK" → 眼镜面板点亮
```

11.8 已修过「节点指错 hidraw0(CV10, 28B)」导致 `ioGetVendorInfo` 恒失败的坑。
本轮重启后的现场：hidraw0~4 全部枚举（含 `hidraw3 = 6DoF Gaming Kit
Par-CG012` 的 `06ffa0` 接口）、`/dev/hwvr1 -> /dev/hidraw1 (descLen=68)`、
`video14/15` 与 `ttyUSB0-2` 权限全 666、HDMI `connected` 且首选
`3200x1600` —— **面具模块侧每一环都是对的**。但 14 秒观测窗口里
`active device` / `ioGetVendorInfo` / `HIDIOCSFEATURE` 计数**全为 0**：
激活指令根本没发出去。所以黑屏不是 EDID / 分辨率 / 节点权限问题。

> 现场应急仍按手册 4.3：眼镜有粘性激活态，失活后先用 PC/手机点亮一次再插回
> 盒子。这能绕过本机发不出激活指令的局面。

#### 6DoF 需不需要激活指令：需要，且与眼镜共用上游

- 6DoF 三设备头/左/右的上报走 `VrInteractiveDeviceManager`（`mVRDeviceExt`）
  → `getCurrentDevices()` → `ArvrRuntimeInternalInterface`；
- `ArvrRuntimeModuleManager.updateHandleLight(I)` →
  `updateHandleLightNative(I)` 是点亮/激活手柄的 native 指令，但它在
  `service/f`（就是一直报 null 的那个 manager）里；
- **循环依赖（本轮定位）**：
  `VrHelmetExt.isEnable()` 里 `mVRDeviceExt == null` 时，只有
  `VrFramework.isHW6DoFHeaderAvailable()` 为 true 才会创建它；而后者
  → `VrParamsRequester.isHW6DoFAvailable(0)` → 第一行
  `mRuntimeInterface == null` 就 return false。于是设备管理器永远建不起来，
  激活指令不发、眼镜不亮、6DoF 设备不上报，`mRuntimeInterface` 继续 null。
  现场每帧刷 `VrHelmetExt: mVRDeviceExt is null` 就是这个死锁。

#### 修正 11.10 的旧结论（权限/binder 不是断点）

之前把 6DoF 归到「`ACTION_GET_INTERNAL_INTERFACE` binder 缺口 /
`RUNTIME_ALLOW` 权限」。本轮逐条证伪：

| 项 | 实测 |
|---|---|
| `com.huawei.android.permission.VR` | `granted=true`（`checkCallingOrSelfPermission` 是「调用方或自己」，服务端自己也持有） |
| `RUNTIME_ALLOW` | `granted=true` |
| `ArvrRuntimeService` 三处 `isVrMode` 判断 | `onCreate` / `onBind` / `onStartCommand` **均已 patch 成常量 true** |
| `vr_system` 注册表 | `binder=android.os.BinderProxy@...`，已发布 |
| `isVRMode` | `HvrSdkBridge: getVRModeState -> 1 isVRMode=true` |
| 绑定 | `dumpsys activity services` 有 `ACTION_GET_INTERNAL_INTERFACE` 的 `ConnectionRecord`（binding 来自 vrlauncherx），`bind RuntimeService suc.` / `onBind` 均出现 |
| `VrFrameworkBootstrap` | `framework=true helmet=false`，`VrFramework.init` 已执行 |
| 仍失败 | `mRuntimeInterface == null`、`runtimeBinder is null`、`Huawei 6Dof Header/left/right is false` |

所以软件侧「注册/权限/绑定」都已就位，剩下的不是再装什么框架，而是
`VrHelmetExt` 那个循环依赖（SDK 内部 Java/native 逻辑），需要单独 patch
`hvrframework.dex` 打破。

#### 面具插件（Magisk）能做什么 / 不能做什么

| 能力 | 归属 | 现状 |
|---|---|---|
| EDID 注入、HWC 分辨率白名单 bind mount、平台伪装 | Magisk `post-fs-data.sh` | 生效（HDMI 首选 3200x1600） |
| hidraw / 6DoF video / ttyUSB 权限、hwvr1 选点、state 发布、开机拉服务 | Magisk `service.sh` | 生效（见上） |
| 显示路由的跨进程放行 | Java hook（Zygisk/LSPosed） | **已不需要**：13 章的 panel-bootstrap 让启动方自己建屏，同 uid 放行 |
| 6DoF / 眼镜激活的 `VrHelmetExt` 循环依赖 | SDK 内部 Java/native | **Magisk 做不了，LSPosed 也不是对症解**，需 patch `hvrframework.dex` |

一句话：**面具插件该做的都做了且生效，不用改装 LSPosed；剩下的断点在 SDK
Java 层，既不是 Magisk 也不是 LSPosed 的能力范围。**

本轮给 `service.sh` 补了「无线 adb 5555 自愈」：`wadb` 模块只在开机做有限
10 次重拉就退出，运行时 adbd 的 TCP 监听一旦丢失就永久失联（只剩拔电源）。
hvrglass 是唯一常驻循环，现每 60 秒检查一次、端口没了才用
`ctl.stop/ctl.start adbd` 重拉；`touch /data/adb/hvrglass/wadb_guard_off`
可关闭。已 root 部署到设备模块目录，**下次重启生效**。

> ⚠️ **禁止在模块里改 `sys.usb.config`**：本轮做过一次自动回滚的 A/B，
> `setprop sys.usb.config none` 立刻打断唯一无线 adb 通道（ping 0% 丢包、
> 5555 拒绝连接，wadb 与守护都没能自愈，最后靠用户拔插电源恢复）。
> `/sys/class/udc` 空 + `sys.usb.controller` 空造成的 gadget 配置残缺目前
> 没有软件侧安全修法，只能现场查线缆 / Type-C 转接 / hub 供电。

`fix/tools/vr-input-check.sh` 的 A 段同步增强：修正旧的「RUNTIME_ALLOW
权限」说明，新增绑定链判据（hidraw 数、`vr_system` 注册表、
`bind RuntimeService` / `onBind` / `not Internal permitted` /
`mManager == null` / `checkVRMode fail`），能区分「眼镜离线导致绑定从未发起」
与「眼镜在位但 SDK 未触发绑定」。

---

### 11.15 点亮兜底 + 6DoF 绑定触发（2026-11-08 第六轮，已真机部署）

**A. 眼镜"黑屏"的真实形态不是不激活，而是激活后来不及保持。**

第 14 章写成「激活指令从未发出」，本轮用 tag 过滤实时抓（VRRender 每帧刷屏会
冲掉 `logcat -d` 缓冲，普通计数会误判为 0）纠正：

```
06:50:26.209 DevHid: closeDevice -> openDevice success
06:50:26.309 ... 每 100ms 一次，无限循环
06:51:33.909 DevHid: ioActiveDev: active device(2) OK   （偶发才走到）
```

`WalleDev.cpp ThreadLoop` 在 read error 后把 glass 置 `STATUS_FAULT`，随后
反复 close/open，眼镜停在未激活态。手册 4.3 记载激活态是**粘性**的，所以
外部补发一次 `HIDIOCSFEATURE(5)` 就能打破循环——**这一步由面具模块做，
不需要动 SDK Java/native，也不需要 LSPosed**。

协议（`docs/HELMET_HID_PROTOCOL.md` 1.2）：`ioActiveDev(DEVICE_TYPE)` =
`buf[0]=5, buf[1]=DEVICE_TYPE & 0x7E, ioctl(0xC0054806)`。真机实测：

```
su -c "/data/adb/modules/hvrglass/hwvr-activate /dev/hwvr1 2"
  -> active device(2) sent, ret=5, payload=0502000000
补发后两个 8s 窗口：closeDevice=0 / openDevice=0 / STATUS_FAULT=0，
                    receive imu data 稳定 8~9 次
```

`ksu/hwvr_compat/hwvr-activate.c` 用 NDK r26 编成 arm64 静态 ELF，产物在
`fix/magisk-module/modules/hwvr-activate`。`service.sh` 只在「刚重插」或
「检出 `STATUS_FAULT`」时补发，**冷却 30 秒**，避免重蹈高频 `GET_FEATURE`
自激 EMI 的覆辙（见 11.9）。已 root 部署到模块目录，重启后自动生效。
`install.sh` 同步补了执行位。

> 一个瞬态坑：拔插眼镜的瞬间 `/dev/hwvr1` 会被守护换成占位普通文件，此时
> 发激活必然 `ENOTTY`。模块用 `[ -L /dev/hwvr1 ]` 挡住了；手动执行前先
> `readlink /dev/hwvr1` 确认指向 68B 控制口（`hwvr-probe` 返回 0）。

**B. 6DoF 的真正断点：`registerReceivers()` 是死代码。**

`VrParamsRequester.bindRuntimeService()` 是 6DoF 唯一入口——不绑定，
`mRuntimeInterface` 恒 null，`isHW6DoFAvailable()` 第一行就 return false，
`Huawei 6Dof Header/left/right` 全 false。而全 SDK 里
`VrFramework$System.registerReceivers()` **没有任何调用点**，它内部的
`TemperatureReceiver.register()` 才是 `bindRuntimeService` 的唯一调用者。
这就是现场 `bind RuntimeService : 0` 的由来。

`fix/patches/vrdesktop/fix_runtime_bind.py` + `apply_runtime_bind.sh` 在
`HvrSdkBridge.offer()` 的 FRAMEWORK 分支补一步：用 **native SetClass 那份
Class 的 ClassLoader** 加载 `VrParamsRequester`，反射调
`getInstance().bindRuntimeService(activity)`。必须是这个 loader——
`VrFrameworkBootstrap` 另建的 L3 副本与 `LibUpdate` 的 L4 是两份类，
静态单例互不相通（见 `HvrSdkBridge.java` 头注释）。真机实证：

```
I HvrSdkBridge: offer[0] com.huawei.vrframework.VrFramework ... hvrframework.dex
I HvrSdkBridge: VrFramework.init(Activity) OK on SetClass copy
I VrParamsRequester: bind RuntimeService          ← 从 0 变成实际发生
I HvrSdkBridge: bindRuntimeService OK on SetClass copy
VerifyError = 0
```

**注入点的两次踩坑（已写进 py 头注释）**：放在 `applyFramework()` 的
`Log.i` 之后会让 dex verifier 在 try/catchall 合并点报
`[0x30] register v2 has type Method but expected String`，整个
`HvrSdkBridge` 类加载失败（`getSystemService` 崩，已回滚）；放在
`setActivity()` 里则因 `CLASSES` 还是空的而静默 return（`setActivity`
早于 `offer[0]`）。只有 `offer()` 的 FRAMEWORK 分支时序正确且是直线代码。

**C. 尚未闭合的最后一环（本轮明确记录，未修）**

绑定已发生、`onBind` 也调用了，但客户端 `mRuntimeInterface` 仍为 null、
`Huawei 6Dof Header is true` 从未出现；服务端每次 `onStartCommand` 都报
`ArvrRuntimeService: mManager == null!`。6 个 native 库（`libVR6Dof.so`
/`libarvr_slam.so`/`libctrl3dof.so`/`libhivrar_fd.so`/
`libruntime_service_module.so`/`libc++.so`）在设备 `lib/arm64` 里齐全，
`NO VR permission` / `Not in Vr Mode` / `UnsatisfiedLinkError` 计数全 0，
所以不是权限或库缺失；断点收敛到 **`onCreate` 的 `h`(onBind 返回的
binder) / `j`(manager) 初始化未生效，或 `service/f.getInstance()` 返回 null**。
下一步应直接替换设备上 `app_SdkLibs/hvrframework.dex`（无需重签
161MB SDK APK）打点确认，或 patch `ArvrRuntimeService.onCreate()` 无条件
初始化 `h`/`j`。**6DoF 目前仍不可用，3DoF CF20 不受影响。**

`fix/tools/vr-input-check.sh` A 段已同步加入 `bindRuntimeService OK`、
`STATUS_FAULT`、`closeDevice`、`active device(2) OK/sent` 计数。
