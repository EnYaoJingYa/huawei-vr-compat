#!/bin/sh
# =============================================================================
# boot-whitelist.sh —— 开机阶段点亮方案 B：空白名单让 mode_verify 全放行
#
# 依据（2026-11-06 逆向 hwcomposer.rk30board.so，手册 6.13）：
#   DrmDevice::mode_verify(m) 在 white_modes_.empty() 时直接 return true；
#   init_white_modes() 只在 DrmDevice::Init()（开机约 6.03s）读一次
#   /system/usr/share/resolution_white.xml。
# 原厂白名单无 3200 → 内核给的 3200 模式被剔除 → HWC 自造 1080p60。
# 本方案把白名单换成空表，让内核模式表（真实 22f6 EDID 自带
# 3200x1600@70/90 两条）全部放行，配合 persist.vendor.resolution=3200x1600@70
# 让 HWC 开机就选 3200p70 —— 目标「重启即亮」。
#
# 两处同时写，覆盖两种挂载时机：
#   ① /data/adb/modules/hvrglass/system/usr/share/resolution_white.xml
#      （Magisk systemless overlay，magiskd magic mount，早于模块脚本）
#   ② /data/adb/hvrglass/resolution_white.xml
#      （post-fs-data.sh 运行时 bind mount 的 WL_SRC）
# 只改数据文件与开关，不改开机脚本逻辑。备份在
# /data/local/tmp/hvr-empty-wl-backup，off 可完整回退。生效需一次受控重启。
#
#   sh fix/boot-whitelist.sh <serial> on       # 部署（自动备份）
#   sh fix/boot-whitelist.sh <serial> check    # 只读体检
#   sh fix/boot-whitelist.sh <serial> reboot   # 受控重启并等待上线
#   sh fix/boot-whitelist.sh <serial> verify   # 重启后验收判据
#   sh fix/boot-whitelist.sh <serial> off      # 回退（恢复备份 + 删 overlay）
# =============================================================================
set -u
ADB=${ADB:-adb}
SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-check}"
HERE=$(cd "$(dirname "$0")" && pwd)
D=/data/local/tmp
EMPTY_LOCAL=empty-resolution_white.xml
EMPTY_DEV=$D/hvr-empty-wl.xml
BK=$D/hvr-empty-wl-backup
WL_SRC=/data/adb/hvrglass/resolution_white.xml
WL_OVL=/data/adb/modules/hvrglass/system/usr/share/resolution_white.xml
WL_DST=/system/usr/share/resolution_white.xml

"$ADB" connect "$SERIAL" >/dev/null 2>&1
rsh() { "$ADB" -s "$SERIAL" shell "su -c '$1'" 2>&1; }

show() {
    rsh "echo MODE=\$(cat /data/adb/hvrglass/mode); echo UPTIME=\$(cut -d\" \" -f1 /proc/uptime); echo BOOT=\$(getprop sys.boot_completed); echo HWC_PID=\$(getprop init.svc_debug_pid.vendor.hwcomposer-2-1); echo EDID=\$(dd if=/sys/class/drm/card0-HDMI-A-1/edid bs=1 skip=8 count=2 2>/dev/null | od -An -tx1); echo MODES3200=\$(grep -c \"^3200x1600\" /sys/class/drm/card0-HDMI-A-1/modes); echo WL_SRC_MD5=\$(md5sum $WL_SRC | cut -c1-16); echo WL_OVL=\$(test -f $WL_OVL && md5sum $WL_OVL | cut -c1-16 || echo none); echo WL_SYS_3200=\$(grep -c 3200x1600 $WL_DST); echo SUPPORTED_3200=\$(dumpsys display | grep supportedModes | grep -c 3200); echo VOP=\$(grep -m1 Display /sys/kernel/debug/dri/0/summary); echo CLK=\$(grep -m1 clk /sys/kernel/debug/dri/0/summary); echo P_MAIN=\$(getprop persist.vendor.resolution.main)"
}

case "$ACTION" in
    on)
        [ -f "$HERE/$EMPTY_LOCAL" ] || { echo "  [FAIL] 缺少 $EMPTY_LOCAL"; exit 1; }
        (cd "$HERE" && MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push \
            "$EMPTY_LOCAL" "$EMPTY_DEV" >/dev/null 2>&1) || {
                echo "  [FAIL] push 空表失败"; exit 1; }
        sz=$(rsh "wc -c < $EMPTY_DEV" | tr -d '\r ')
        [ "${sz:-0}" -gt 20 ] 2>/dev/null || { echo "  [FAIL] push 后文件为空"; exit 1; }
        rsh "mkdir -p $BK /data/adb/modules/hvrglass/system/usr/share; cat $WL_SRC > $BK/resolution_white.xml; if [ -f $WL_OVL ]; then cat $WL_OVL > $BK/overlay.xml; else echo missing > $BK/overlay.missing; fi; echo BACKUP_OK"
        # magic mount 会把 WL_SRC 变成 ro bind 到自身，必须先解挂才能原地写
        rsh "umount $WL_SRC 2>/dev/null; umount -l $WL_SRC 2>/dev/null; cat $EMPTY_DEV > $WL_SRC; cat $EMPTY_DEV > $WL_OVL; chmod 644 $WL_SRC $WL_OVL; echo WRITE_RC=\$?"
        rsh "setprop persist.vendor.resolution.main 3200x1600@70; setprop persist.vendor.resolution.HDMI-A-0 3200x1600@70; echo auto > /data/adb/hvrglass/mode; echo DEPLOYED"
        echo "  [i] 已部署空白名单（备份在 $BK），需 reboot 生效；off 可回退"
        show | head -14
        ;;
    off)
        rsh "[ -d $BK ] || { echo NO_BACKUP; exit 1; }; umount $WL_SRC 2>/dev/null; umount -l $WL_SRC 2>/dev/null; cat $BK/resolution_white.xml > $WL_SRC; chmod 644 $WL_SRC; if [ -f $BK/overlay.missing ]; then rm -f $WL_OVL; else cat $BK/overlay.xml > $WL_OVL; fi; echo RESTORED"
        echo "  [i] 已回退；再 reboot 一次让开机挂载恢复"
        show | head -14
        ;;
    check|verify)
        show | head -16
        ;;
    reboot)
        rsh "reboot" >/dev/null 2>&1
        "$ADB" disconnect "$SERIAL" >/dev/null 2>&1
        echo "  [i] 等待设备重新上线（最多 3 分钟）..."
        ok=0
        for i in $(seq 1 30); do
            "$ADB" connect "$SERIAL" >/dev/null 2>&1
            b=$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
            u=$("$ADB" -s "$SERIAL" shell 'cat /proc/uptime' 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            if [ "$b" = "1" ] && [ -n "$u" ] && [ "$u" -lt 300 ] 2>/dev/null; then
                ok=1; echo "  [OK] 第 ${i} 次探测上线，uptime=${u}s"; break
            fi
            sleep 6
        done
        echo "  BOOT_OK=$ok"
        [ "$ok" = "1" ] && show | head -16
        ;;
    *)
        echo "用法: sh boot-whitelist.sh <serial> [on|off|check|reboot|verify]"; exit 1 ;;
esac
