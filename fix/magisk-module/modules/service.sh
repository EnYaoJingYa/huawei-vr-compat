#!/system/bin/sh
#
# 让普通 app 能打开眼镜的 HID 通道（IMU 数据源）。
#
# 为什么需要：
#   眼镜在通用内核上暴露成标准 /dev/hidrawN（VID:PID = 12d1:1092 / 12d1:107e），
#   但 ueventd 给的权限是 system:audio 0660，普通 app（u0_aXX）打不开，
#   open() 直接 EACCES。ALVR 客户端因此拿不到 IMU，头追永远是单位四元数。
#
# 为什么用轮询而不是 chmod 一次：
#   眼镜会自己掉线重枚举（Type-C 重新协商、MCU 重启），每次重枚举都会
#   重新创建 hidraw 节点、权限被打回 0660。所以这里常驻守着。
#
LOG=/data/local/tmp/hidraw_perm.log
echo "$(date) service.sh 启动" >> "$LOG"

# --- 拉起华为 VR 服务链 ---
# 背景：VRService / ArvrRuntimeService 都只是普通 Service，没有开机广播；
#       华为原方案由系统服务 vr_system 拉起，本盒子缺这一环 —— 不手动起就是空的。
# 做法：后台等 boot_completed 再 start，不能阻塞下面的 hidraw 守护死循环。
(
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do
        i=$((i + 1))
        sleep 2
    done
    sleep 8
    export PATH=/system/bin:/system/xbin:$PATH
    am start-service -n com.huawei.vrservice/com.huawei.vrservice.VRService 2>/dev/null
    am start-service -n com.huawei.hvrsdkserverapp/com.huawei.hvrsdkserverapp.service.ArvrRuntimeService 2>/dev/null
    # 手柄自动扫描（2026-11-07）：VRHandleService 没有开机广播，平时靠
    # VrSystemActor 每 20 秒的 ACTION_RECONNECT_MSG 拉起。这里显式发一次，
    # 让开机立即触发 AutoScanCompat 的 BLE 扫描，不用等首轮心跳。
    # 注意它只是「加速」：即使被 Android 11 后台启动限制拦下，心跳也会拉起。
    am start-foreground-service -n com.huawei.vrhandle/.service.VRHandleService -a com.huawei.vrservice.ACTION_RECONNECT_MSG 2>/dev/null
    echo "$(date) 已请求拉起 VRService + ArvrRuntimeService + VRHandleService" >> "$LOG"
) &

# --- 无线 adb 已移交独立 wadb 模块 ---
# 历史教训（2026-11-04 晚）：这里曾有第二个 adb 兜底循环，与 wadb 模块
# 的循环互相 kill adbd 打架，双方都等不到 5555 监听。adb 自启职责
# 全部归 wadb 模块（/data/adb/modules/wadb/service.sh），此处不再插手。

# --- 眼镜点亮自愈：已移除（2026-11-05 回滚）---
# 2026-11-04 晚曾在这里加过开机 15 秒后自动 setprop 强制分辨率 + detect 重探
# + `stop/start vendor.hwcomposer-2-1` 的"自愈"。它是上午成功之后新增的变量，
# HWC/SF 重启会让 system_server 图形会话僵死（Surface$OutOfResourcesException），
# 更早的驱动 unbind/rebind 版本还两次实证内核 panic 崩循环。
# 手册第六章的成功流程是最小集：真实 HWV EDID 直通 + 白名单 bind mount
# + 一次 `stop; start surfaceflinger`（手工、按需），没有后台自动强扭。
# 点亮问题应回到眼镜侧：手册 4.3 —— 眼镜有粘性激活态，失活后先用 PC/手机
# 点亮一次再插回盒子；EDID 指纹 22d2=转换器默认（眼镜没醒）、22f6=HWV 真实。

# --- vcom 节点兼容开关（2026-11-06）---
# 只有 /data/adb/hvrglass/ttyusb_compat 文件存在时才启用；默认关闭，
# 不改变既有行为。详见 fix/ttyusb-compat.sh 头部说明。
TTYUSB_REGISTERED=0

# --- 眼镜插入自动拉起 VR 桌面（2026-11-08）---
# 状态机：眼镜从「不在位」变「在位」（CTRL 探测到控制接口）后，
# 稳定 8 秒且 VRService 已在跑，就 am start 一次 VR 桌面；拔出后复位，
# 下次插入再拉。开机时眼镜已插着的场景也由这里覆盖（服务起来后首轮探测）。
GLASS_WAS=0
GLASS_SEEN=0
GLASS_LAUNCH_DONE=0
# vr_system_state 重发尝试次数（拔出眼镜时复位）
STATE_RETRY=0
# 周期巡检时间戳（见主循环「vr_system_state 周期巡检」）
STATE_LAST_CHECK=0
STATE_REPAIR_LAST=0
# hidraw 全部消失的连续轮数（EMI 重枚举瞬态宽限，见主循环）
MISS=0
# 无线 adb 5555 自愈巡检时间戳（见主循环末尾，2026-11-08 第五轮）
ADB_GUARD_LAST=0
# 眼镜激活指令补发时间戳（见主循环「激活兜底」，2026-11-08 第六轮）
ACTIVATE_LAST=0
ACTIVATE_BIN=/data/adb/modules/hvrglass/hwvr-activate

while true; do
    for h in /dev/hidraw*; do
        [ -e "$h" ] || continue
        # 只在权限不对时才 chmod，避免每轮都写
        perm=$(stat -c '%a' "$h" 2>/dev/null)
        if [ "$perm" != "666" ]; then
            chmod 666 "$h" 2>/dev/null && \
                echo "$(date) $h $perm -> 666" >> "$LOG"
        fi
    done
    # --- 6DoF 双目摄像头节点权限（2026-11-05 新增）---
    # 12d1:3a09 6DoF Gaming Kit 枚举后会建 /dev/video14、/dev/video15
    # （名字含 "6DoF"），ueventd 给的是 media:camera 0660，VR 服务是 u0_aXX
    # 普通 app 打不开。这里按节点名识别，编号随重枚举变化也能覆盖，
    # 不误伤系统自带的其它 camera 节点。
    # 注意：这只是第一道墙。Android 11 对「后台启动的前台服务」还有
    # camera 访问限制（见手册 6.8），需要由前台组件触发服务才能拿到。
    for v in /dev/video*; do
        [ -e "$v" ] || continue
        n=$(basename "$v")
        nm=$(cat "/sys/class/video4linux/$n/name" 2>/dev/null)
        case "$nm" in
            *6DoF*)
                perm=$(stat -c '%a' "$v" 2>/dev/null)
                if [ "$perm" != "666" ]; then
                    chmod 666 "$v" 2>/dev/null && \
                        echo "$(date) $v (6DoF) $perm -> 666" >> "$LOG"
                fi
                ;;
        esac
    done
    # --- /dev/hwvr1 控制接口维护（2026-11-08 判据修正）---
    # vrservice/WalleDev 硬编码打开 /dev/hwvr1；ioGetVendorInfo() 要发
    # HIDIOCGFEATURE(4)/report 1，激活命令 HIDIOCSFEATURE(5) 也必须发到
    # 「能按协议应答的控制接口」才能点亮面板。
    #
    # ⚠️ 旧判据（2026-11-07）：取「描述符前 3 字节 == 06ff00」的**第一个**
    #    匹配就 break。2026-11-08 真机实测证伪：CV10(hidraw0, 12d1:1092)
    #    与真控制口(hidraw1, 12d1:107e input3) 前 3 字节完全相同，
    #    但 CV10 描述符只有 28B、report 1 仅 1 字节，应答不了 4 字节的
    #    GET_FEATURE。后果：ioGetVendorInfo 恒失败 → WalleAlg 加载失败 →
    #    Unity OnApplicationQuit → 桌面退回 VRPrepareActivity；激活命令
    #    也发不出去（active device(2) OK 从不出现）→ 眼镜面板黑屏。
    #    **拔插 USB 不解决**：守护每 3 秒重跑一次这个错误判据，每次拔插
    #    都把链接重新指回 hidraw0（hidraw_perm.log 03:08:18 实证）。
    #
    # 判据（2026-11-08 二次修正）：候选限定 `06ff00`（排除 `05 0c` 按键口
    #   和 `05 01` Hub），取**报告描述符实际字节数最大者**：CV10 是 28B、
    #   真控制口（12d1:107e input3）是 68B。sysfs 的 stat 恒为 4096，
    #   必须用 od 读实际长度。纯 sysfs 读取，不向 USB 总线发任何请求。
    #
    # ⚠️ 不要在守护主循环里跑 hwvr-probe / HIDIOCGFEATURE(4)（2026-11-08
    #    实测证伪的上一版）：每 3 秒对所有候选各发一次 GET_FEATURE，等于
    #    持续刺激 USB 总线，内核开始刷
    #      "usb usb1-port1: disabled by hub (EMI?), re-enabling..."
    #    hub 端口每 ~20s 禁用重连一次，重连窗口里 hidraw 全消失 →
    #    VrPlatformCompat 的 glass probe usb=false → VrMonitor.checkVRMode
    #    fail → 桌面 SDK Quit（用户看到「一进 VR 桌面就闪退」）。
    #    A/B（各 60s）：冻结守护 → 只重枚举 1 次、hidraw 全程 4 个；
    #    恢复守护 → DEVNUM 019→023→027 共 3 次，每次 hidraw=0 且栈顶
    #    掉回 com.droidlogic.mboxlauncher。
    #    描述符长度判据与 probe 的结论一致（都选 hidraw1），但零 USB 请求，
    #    也不依赖编号：重枚举后真控制口变成 hidraw0 时依然选得对。
    #    hwvr-probe 保留在模块里，仅供 fix/tools/hwvr1-check.sh 手动一次性验证。
    CTRL=""
    CTRL_LEN=-1
    for h in /sys/class/hidraw/hidraw*; do
        [ -e "$h" ] || continue
        pre=$(od -An -tx1 -N3 -v "$h/device/report_descriptor" 2>/dev/null | tr -d ' \n')
        [ "$pre" = "06ff00" ] || continue
        len=$(od -An -tx1 -v "$h/device/report_descriptor" 2>/dev/null | wc -w | tr -d ' \n')
        [ -n "$len" ] || len=0
        if [ "$len" -gt "$CTRL_LEN" ]; then
            CTRL_LEN=$len
            CTRL="/dev/${h##*/}"
        fi
    done
    if [ -n "$CTRL" ]; then
        MISS=0
        CUR=$(readlink /dev/hwvr1 2>/dev/null)
        if [ "$CUR" != "$CTRL" ]; then
            rm -f /dev/hwvr1
            ln -s "$CTRL" /dev/hwvr1 2>/dev/null && \
                echo "$(date) hwvr1 -> $CTRL (descLen=$CTRL_LEN)" >> "$LOG"
        fi
        # --- 眼镜插入自动拉起 VR 桌面（2026-11-08）---
        # 等 8 秒是给 USB 枚举 + 显示通路稳定；要求 VRService 已在跑，
        # 并且 vr_system_state 已发布（第二道闸，见下）。
        T=$(date +%s)
        if [ "$GLASS_WAS" != "1" ]; then
            GLASS_SEEN=$T
        fi
        if [ "$GLASS_LAUNCH_DONE" != "1" ] && [ $((T - GLASS_SEEN)) -ge 8 ] \
           && [ -n "$(pidof com.huawei.vrservice 2>/dev/null)" ]; then
            # vr_system_state 注册表是 com.huawei.vrlauncherx 进程内的
            # static Map（VrSystemRegistryProvider）。force-stop 桌面、
            # 拔插眼镜引起的进程重建都会清空它；HvrStatePublisher 只在
            # ArvrRuntimeService 启动握手时发布一次，不会补发。
            # 缺它 → Unity "CheckVrMode, is not VRMode, exit" → SDK Quit。
            VR_STATE=0
            R=$(timeout 5 content call \
                  --uri content://com.huawei.vrlauncherx.registry \
                  --method getService --arg vr_system_state 2>/dev/null)
            case "$R" in *binder=*) VR_STATE=1 ;; esac
            if [ "$VR_STATE" != "1" ] && [ "$STATE_RETRY" -lt 3 ]; then
                STATE_RETRY=$((STATE_RETRY + 1))
                am force-stop com.huawei.hvrsdkserverapp 2>/dev/null
                am start-service -n com.huawei.hvrsdkserverapp/com.huawei.hvrsdkserverapp.service.ArvrRuntimeService 2>/dev/null
                echo "$(date) vr_system_state 未发布 → 重启 Runtime 重发（第 $STATE_RETRY 次）" >> "$LOG"
                sleep 3
                R=$(timeout 5 content call \
                      --uri content://com.huawei.vrlauncherx.registry \
                      --method getService --arg vr_system_state 2>/dev/null)
                case "$R" in *binder=*) VR_STATE=1 ;; esac
            fi
            if [ "$VR_STATE" = "1" ]; then
                if am start -n com.huawei.vrlauncherx/.MainActivity >/dev/null 2>&1; then
                    GLASS_LAUNCH_DONE=1
                    echo "$(date) 眼镜在位 → vr_system_state OK → 已拉起 VR 桌面" >> "$LOG"
                fi
            elif [ "$STATE_RETRY" -ge 3 ]; then
                # 三次仍不发布：放行一次并写 WARN，避免「什么都不发生」
                GLASS_LAUNCH_DONE=1
                echo "$(date) [WARN] vr_system_state 始终未发布，仍尝试拉起桌面（预期 SDK Quit）" >> "$LOG"
                am start -n com.huawei.vrlauncherx/.MainActivity >/dev/null 2>&1
            fi
        fi
        # --- 眼镜激活兜底（2026-11-08 第六轮：点亮链）---
        # 现场取证：WalleDev.cpp ThreadLoop 在 read error 后把 glass 置
        # STATUS_FAULT，随后每 100ms 重复 closeDevice -> openDevice success，
        # 永远走不到 ioActiveDev()，眼镜停在未激活态（黑屏）。手册 4.3 记载
        # 眼镜激活态是粘性的，一次成功的 HIDIOCSFEATURE(5) 即可保持点亮。
        # 这里由模块低频补发一次，绕开 SDK 的死循环，不改 Java/native。
        # 冷却 30s + 只在「刚重插」或「检测到 STATUS_FAULT」时发，避免
        # 高频 USB 请求自激 EMI（见上方「不要在守护里跑 GET_FEATURE」教训）。
        if [ -f "$ACTIVATE_BIN" ] && [ -L /dev/hwvr1 ] \
           && [ $((T - ACTIVATE_LAST)) -ge 30 ]; then
            [ -x "$ACTIVATE_BIN" ] || chmod 755 "$ACTIVATE_BIN" 2>/dev/null
            NEED=0
            [ "$GLASS_WAS" != "1" ] && NEED=1
            if logcat -d -t 120 2>/dev/null | grep -q "STATUS_FAULT"; then
                NEED=1
            fi
            if [ "$NEED" = "1" ] && [ -x "$ACTIVATE_BIN" ]; then
                "$ACTIVATE_BIN" /dev/hwvr1 2 >> "$LOG" 2>&1 && \
                    echo "$(date) 补发眼镜激活 HIDIOCSFEATURE(5) (NEED=$NEED)" >> "$LOG"
                ACTIVATE_LAST=$T
            fi
        fi
        GLASS_WAS=1
    else
        # EMI 重枚举瞬态宽限：hub 端口被禁用重连时 hidraw 会短暂（1~2 轮）
        # 全部消失。立刻摘 symlink + 判定「眼镜拔出」会让守护跟着抖动，
        # 并把桌面拉进「刚拉起就遇到节点消失 → checkVRMode fail → SDK Quit」
        # 的闪退循环。连续 3 轮（约 9s）仍不在位才认定为真拔出。
        MISS=$((MISS + 1))
        if [ "$MISS" -ge 3 ]; then
            # 真拔出：清掉 symlink 或占位普通文件，让框架判据回到 false
            if [ -e /dev/hwvr1 ] || [ -L /dev/hwvr1 ]; then
                rm -f /dev/hwvr1
                echo "$(date) hwvr1 清除（控制接口不在位）" >> "$LOG"
            fi
            if [ "$GLASS_WAS" = "1" ]; then
                echo "$(date) 眼镜拔出，重插时将自动拉起 VR 桌面" >> "$LOG"
            fi
            GLASS_WAS=0
            GLASS_LAUNCH_DONE=0
            STATE_RETRY=0
        else
            # 瞬态窗口（2026-11-08 第四轮）：断链 symlink 的 File.exists()
            # 是 false。框架侧 VrMonitor.isVRGlassDevExist()（原版实现）和
            # VrPlatformCompat.hasGlassUsbIdentity()（glass-grace 回退判据）
            # 都看 /dev/hwvr1 是否存在，一断链就判「眼镜不在」→ checkVRMode
            # 凑够 2 个失败项 → 桌面闪退。用占位普通文件把节点撑住 1~2 轮，
            # 真控制口回来后由上面的 CTRL 分支自动换回 symlink。
            # 窗口期 WalleDev 若 open 到占位文件，ioctl 失败与节点消失等价，
            # 不会比原来更糟；真拔出时（MISS>=3）占位立即清除。
            if [ ! -e /dev/hwvr1 ]; then
                rm -f /dev/hwvr1
                : > /dev/hwvr1 2>/dev/null && chmod 666 /dev/hwvr1 2>/dev/null && \
                    echo "$(date) [EMI 宽限] /dev/hwvr1 占位（hidraw 暂失）" >> "$LOG"
            fi
        fi
    fi

    # --- vr_system_state 周期巡检（2026-11-08「打开应用就退出」补的缺口）---
    # 桌面 Unity 在 onPause 时会 finish all activity + ForceProcessExit，
    # 把 launcherx 进程连同注册表（进程内 static Map）一起杀掉。实测
    # 03:27:29 onPause → 03:27:29 ForceProcessExit → "has died: fg TOP"，
    # 触发点甚至可以是启动另一个 Activity / 投屏的 MediaProjection 授权框。
    # HvrStatePublisher 只在 Runtime handshake 时发一次，桌面死了不会补发；
    # 原实现只在「首次拉桌面」时查一次，之后注册表长期为 null → 回不去桌面。
    # 这里每 15 秒查一次，缺失就重启 Runtime 重发（同一故障 60 秒内只修一次，
    # 避免桌面反复自杀时把 Runtime 也拖进重启震荡）。
    # 注意：只修 binder，不强行把桌面拉回前台——用户可能正在用投屏等 2D 应用。
    NOW=$(date +%s)
    if [ $((NOW - STATE_LAST_CHECK)) -ge 15 ]; then
        STATE_LAST_CHECK=$NOW
        R=$(timeout 5 content call \
              --uri content://com.huawei.vrlauncherx.registry \
              --method getService --arg vr_system_state 2>/dev/null)
        case "$R" in
            *binder=*) ;;
            *)
                if [ $((NOW - STATE_REPAIR_LAST)) -ge 60 ]; then
                    STATE_REPAIR_LAST=$NOW
                    am force-stop com.huawei.hvrsdkserverapp 2>/dev/null
                    am start-service -n com.huawei.hvrsdkserverapp/com.huawei.hvrsdkserverapp.service.ArvrRuntimeService 2>/dev/null
                    echo "$(date) [巡检] vr_system_state 丢失 → 重启 Runtime 重发" >> "$LOG"
                fi
                ;;
        esac
    fi

    # --- /dev/ttyUSB* vcom 节点（2026-11-06 新增，受开关控制）---
    # 12d1:107e 的 3 个 vendor bulk 接口在通用内核里没有驱动绑定，
    # 因此永远不生成 /dev/ttyUSB0；VRService 的 UpgradeGlass.cpp 硬编码
    # open("/dev/ttyUSB0")，失败 5 次后放弃 -> heartbeat not init 死循环
    # -> proximity -1 -> 3D 桌面不启动。
    # 写 VID/PID 到 usbserial_generic 的 new_id 可让驱动接管并生成 ttyUSB0/1/2；
    # HID 接口无 bulk 端点会被驱动跳过，/dev/hwvr1 symlink 不受影响。
    # 眼镜 USB 每次重枚举都会重建节点并把权限打回 0660，故每轮校正。
    if [ -f /data/adb/hvrglass/ttyusb_compat ]; then
        if [ "$TTYUSB_REGISTERED" = "0" ] && \
           [ -w /sys/bus/usb-serial/drivers/generic/new_id ]; then
            echo "12d1 107e" > /sys/bus/usb-serial/drivers/generic/new_id 2>/dev/null &&
                TTYUSB_REGISTERED=1 &&
                echo "$(date) ttyusb_compat: new_id 已注册" >> "$LOG"
        fi
        for t in /dev/ttyUSB*; do
            [ -e "$t" ] || continue
            perm=$(stat -c '%a' "$t" 2>/dev/null)
            if [ "$perm" != "666" ]; then
                chmod 666 "$t" 2>/dev/null &&
                    echo "$(date) $t $perm -> 666" >> "$LOG"
            fi
        done
    fi

    # --- 无线 adb 5555 自愈（2026-11-08 第五轮，面具模块侧兜底）---
    # 背景：wadb 模块只在开机做「有限次」重拉（10 次 / 6s）后就退出，
    #   运行时任何把 adbd TCP 监听冲掉的事件（init 重配 usb gadget、误改
    #   sys.usb.config、adbd 崩溃）都会让 5555 永久关闭 —— 设备 ping 得通
    #   但 adb 连不上，只剩拔电源救砖。hvrglass 是设备上唯一常驻循环，
    #   在这里低频兜底，补上 wadb 的运行时空窗。
    # 只在端口确实没监听时动作，每 60 秒最多一次；用 ctl.stop/ctl.start 走
    #   init 级重拉，不用裸 kill（与 wadb 模块同一套写法）。
    # 开关：touch /data/adb/hvrglass/wadb_guard_off 可整体关闭。
    #
    # ⚠️ 严禁在模块里改 sys.usb.config / persist.sys.usb.config：
    #   2026-11-08 A/B 实证：setprop sys.usb.config none 会立刻打断唯一的
    #   无线 adb 通道（ping 0% 丢包、5555 拒绝连接，且 wadb/守护都没能
    #   自动恢复）。/sys/class/udc 空 + sys.usb.controller 空造成的 gadget
    #   配置残缺，目前没有软件侧安全修法，只能现场查线缆 / Type-C 转接 /
    #   hub 供电 / 环境干扰。不要再拿唯一调试通道做这类实验。
    if [ ! -f /data/adb/hvrglass/wadb_guard_off ]; then
        GUARD_NOW=$(date +%s)
        if [ $((GUARD_NOW - ADB_GUARD_LAST)) -ge 60 ]; then
            ADB_GUARD_LAST=$GUARD_NOW
            if command -v netstat >/dev/null 2>&1 && \
               ! netstat -tln 2>/dev/null | grep -q ':5555'; then
                setprop service.adb.tcp.port 5555
                setprop ctl.stop adbd 2>/dev/null
                sleep 1
                setprop ctl.start adbd 2>/dev/null
                echo "$(date) [adb-guard] 5555 丢失 -> init 级重拉 adbd" >> "$LOG"
            fi
        fi
    fi

    sleep 3
done
