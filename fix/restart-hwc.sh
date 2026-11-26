#!/bin/sh
# =============================================================================
# 让 HWC 重新 Init —— 取证工具（实测会整机重启且无效，勿当点亮手段）
#
# ⚠️ 2026-11-06 22:0x 实测结论：kill -9 HAL 后 `onrestart restart surfaceflinger`
#    引发整机重启，HWC 新 PID 215 / boottime 6.04s，仍回到「HWC 先 Init、
#    白名单后挂载」的同一时序，supportedModes 依旧只有 1080p。
#    任何运行时重启 SF/HWC 的路径都逃不出这个时序死结，必须改开机阶段。
#    本工具保留作取证，不再推荐 restart；详见手册 6.13。
#
# 用法：
#   sh fix/restart-hwc.sh [serial] [check|restart|verify]
#       check    (默认) 只读体检，不改任何东西
#       restart  kill -9 composer HAL，等 init 拉起，再自动 verify
#       verify   只输出判据
#
# 为什么要它（2026-11-06 逆向 hwcomposer.rk30board.so 实锤，见手册 6.13）：
#   DrmDevice::mode_verify(DrmMode) 只放行「白名单六字段全等」的模式：
#       h_display / v_display / h_total / v_total / clock / flags
#   白名单为空则全放行，非空但不匹配则剔除。
#   init_white_modes() 只在 DrmDevice::Init() 里被调用一次
#   （0x42dd4，lib 未 strip，符号 _ZN7android9DrmDevice16init_white_modesEv
#    @0x42744，读 /system/usr/share/resolution_white.xml）——也就是
#   **HWC HAL 进程启动时读一次，之后再也不重读**。
#
#   盒子 HWC 开机约 6.03s 就 Init，而 post-fs-data.sh 的 resolution_white.xml
#   bind mount 稍晚，所以 HWC 拿到的是原厂白名单（无 3200）→ 3200 被剔除
#   → dumpsys display 的 supportedModes 只有 1920x1080@60 → HWC 日志永远
#   `UpdateDisplayMode,line=439, Find best mode-id=17 : 1920x1080p60`。
#   历史成功是 `line=385, Find best mode-id=4 : 3200x1600p70`。
#
#   ⚠️ 因此 `stop/start surfaceflinger`（fix/light-on.sh 的做法）**永远无效**：
#   它只重连 HWC，不会重新 DrmDevice::Init()。必须让 HAL 进程本身重启。
#
# init rc（/vendor/etc/init/android.hardware.graphics.composer@2.1-service.rc）：
#   class hal animation / user system，无 oneshot → kill 后 init 自动拉起；
#   `onrestart restart surfaceflinger` → 会连带重启 SF。
#
# 风险与回退：
#   - 纯运行时动作，不改任何文件、不改开机脚本、不写 EDID、不动属性。
#   - 可能触发 SF 重启 / 整机重启（历史上 SF 重启会级联），adb 会短暂掉线；
#     脚本内建等待与自动重连。
#   - 回退：直接重启设备即可；最坏情况有 backup/box-2026-11-05/ 整机镜像。
#   - 前置：白名单 bind mount 必须已在位且含 3200 条目（check 会校验）。
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-check}"

ADB="${ADB:-}"
if [ -z "$ADB" ]; then
    for p in /d/Tools/AndroidSDK/platform-tools/adb.exe \
             /c/platform-tools/adb.exe \
             "$ROOT/tools/adb.exe"; do
        [ -x "$p" ] && ADB="$p" && break
    done
fi
[ -n "$ADB" ] || { echo "[FATAL] 找不到 adb.exe，请设置 ADB=..."; exit 1; }

connect() {
    "$ADB" connect "$SERIAL" >/dev/null 2>&1
    "$ADB" -s "$SERIAL" shell 'echo OK' 2>/dev/null | tr -d '\r'
}
sh_su() { "$ADB" -s "$SERIAL" shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }

show() {
    echo "----- HWC / 模式表体检 -----"
    # 分条执行，避免一条 su -c 里塞太多转义导致整条被远端 sh 判为语法错误
    sh_su "echo HWC_PID=\$(getprop init.svc_debug_pid.vendor.hwcomposer-2-1); echo HWC_SVC=\$(getprop init.svc.vendor.hwcomposer-2-1); echo HWC_BOOTTIME_NS=\$(getprop ro.boottime.vendor.hwcomposer-2-1)"
    sh_su "echo WHITELIST_MOUNT=\$(mount | grep -c resolution_white); echo WHITELIST_3200=\$(grep -c \"<hdisplay>3200\" /system/usr/share/resolution_white.xml)"
    sh_su "echo RESOLUTION_PROP=\$(getprop persist.vendor.resolution.main); echo FRAMEBUFFER_PROP=\$(getprop persist.vendor.framebuffer.main)"
    sh_su "echo SUPPORTED_MODES=\$(dumpsys display | grep -oE \"supportedModes \\[[^]]*\\]\" | head -1)"
    sh_su "echo PHYSICAL=\$(grep -m1 \"Display mode:\" /sys/kernel/debug/dri/0/summary); echo UPTIME_S=\$(cut -d\" \" -f1 /proc/uptime)"
    echo "  判据：SUPPORTED_MODES 里出现 3200 才算白名单生效；"
    echo "        PHYSICAL 出现 3200x1600p70 / clk[412180] 才算点亮。"
}

wait_device() {
    echo "[i] 等待设备回来（最多 4 分钟）..."
    i=0
    while [ $i -lt 40 ]; do
        [ "$(connect)" = "OK" ] && { echo "[OK] 第 $i 次探测在线"; return 0; }
        i=$((i + 1))
        sleep 6
    done
    echo "[FATAL] 设备未回来"
    return 1
}

# adb daemon 每次新 shell 会话可能重启并丢连接，所有分支都先连一次
[ "$(connect)" = "OK" ] || { echo "[FATAL] 设备不在线：$SERIAL"; exit 1; }

case "$ACTION" in
check)
    show
    ;;
verify)
    show
    echo "----- 最近 HWC 选模日志 -----"
    sh_su "logcat -d 2>/dev/null | grep -iE \"UpdateDisplayMode|Find best mode|mode_verify|white_modes|failed to parse\" | tail -15"
    ;;
restart)
    echo "[0/4] 前置校验"
    [ "$(connect)" = "OK" ] || { echo "[FATAL] 设备不在线：$SERIAL"; exit 1; }
    wl=$(sh_su "grep -c \"<hdisplay>3200\" /system/usr/share/resolution_white.xml 2>/dev/null" | tr -d ' \r\n')
    echo "      白名单 3200 条目 = ${wl:-0}"
    [ "${wl:-0}" -ge 2 ] || { echo "[FATAL] 白名单未在位或不含 3200，拒绝执行"; exit 1; }
    old=$(sh_su "getprop init.svc_debug_pid.vendor.hwcomposer-2-1" | tr -d ' \r\n')
    echo "      当前 HWC PID = ${old:-?}"

    echo "[1/4] kill -9 composer HAL（init 会自动拉起并连带 restart surfaceflinger）"
    sh_su "pkill -9 -f 'android.hardware.graphics.composer@2.1-service' 2>/dev/null || kill -9 \$(pidof android.hardware.graphics.composer@2.1-service) 2>/dev/null; echo KILL_SENT"
    wait_device || exit 1
    sleep 8

    echo "[2/4] 等待新 HWC 进程"
    new=$(sh_su "getprop init.svc_debug_pid.vendor.hwcomposer-2-1" | tr -d ' \r\n')
    echo "      HWC PID: ${old:-?} -> ${new:-?}"
    svc=$(sh_su "getprop init.svc.vendor.hwcomposer-2-1" | tr -d ' \r\n')
    echo "      init.svc.vendor.hwcomposer-2-1 = ${svc:-?}"

    echo "[3/4] 判据"
    show

    echo "[4/4] 选模日志"
    sh_su "logcat -d 2>/dev/null | grep -iE \"UpdateDisplayMode|Find best mode|failed to parse|white\" | tail -12"

    modes=$(sh_su "dumpsys display | grep -oE \"supportedModes \\[[^]]*\\]\" | grep -c 3200" | tr -d ' \r\n')
    if [ "${modes:-0}" -ge 1 ]; then
        echo "[OK] supportedModes 已出现 3200 —— 白名单生效。"
    else
        echo "[!] supportedModes 仍无 3200。可能：HWC 未真正重新 Init / 整机又重启了 /"
        echo "    白名单六字段(clock,flags 等)与内核 mode 不一致。看上面 PHYSICAL 与 UPTIME 判断。"
    fi
    ;;
*)
    echo "[FATAL] 未知动作：$ACTION（check|restart|verify）"
    exit 2
    ;;
esac
