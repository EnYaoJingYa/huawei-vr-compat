#!/bin/sh
# =============================================================================
# DDC / EDID 直通验证 —— 判定「内核能不能自己从眼镜读到真实 EDID」
#
# 用法：
#   sh fix/ddc-passthrough.sh [serial] [check|passthrough|restore|reboot|verify]
#       check       (默认) 只读体检，并自动判定直通是否成立
#       passthrough 备份 mode → 写 force-off（不重启，EDID 文件一律保留）
#       restore     从备份恢复 mode（无备份则 force-vr）
#       reboot      显式执行一次 reboot（passthrough/restore 之后手动调用）
#       verify      重启后的完整判据输出
#
# 判据（三者同时成立才算「DDC 直通坐实」）：
#   ① /sys/kernel/debug/dri/0/HDMI-A-1/edid_override == 0 字节
#      —— 内核没有被注入任何 EDID（debugfs 节点重启后重建，不会残留）
#   ② /sys/class/drm/card0-HDMI-A-1/edid > 0 字节，且厂商字节 = 22 f6
#      —— 内核自己从 DDC 读到眼镜真实 EDID
#   ③ /data/local/tmp/edid_boot.log 本次开机只有「启动，mode=force-off」，
#      没有「已写入 VR EDID」
#
# 为什么用 mode=force-off 而不是移走 edid_only.bin：
#   post-fs-data.sh 开头有 `[ -f "$BIN" ] || exit 0`。一旦把两份 EDID 文件
#   改名/删掉，脚本会提前退出，连 resetprop ro.product.manufacturer=HUAWEI、
#   ro.vr.surport=true 和 resolution_white.xml 白名单 bind mount 都会一起丢，
#   等于把 VR 框架状态倒退。force-off 是脚本原生分支：伪装 + 白名单照常执行，
#   只是 apply=0 不写 override —— 这才是干净的「摘覆盖」。
#
# 2026-11-06 实测结论（RK3566 / H96 Max / 转接器独立供电后）：
#   override=0、edid=256B md5 eba6de4e…、厂商 22 f6、modes 含 3200x1600×2；
#   HPD detect 重读后仍是同一份 → DDC 实时应答，EDID 注入确实是多余的。
#   但物理输出仍是 1920x1080p60 / clk[148500]：EDID 就绪 ≠ HWC 选到 3200，
#   点亮的卡点在 HWC 选模，不在这份 EDID。
#
# 安全约束：
#   - 不改任何开机脚本，只动 /data/adb/hvrglass/mode 这个已有配置开关。
#   - 不删/不改名任何 EDID 文件。
#   - 不自动重启，reboot 是独立显式动作；最坏情况有整机备份可回退。
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

DAT=/data/adb/hvrglass
MODE_FILE=$DAT/mode
MODE_BAK=/data/local/tmp/hvr-mode.before-ddc
OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
CONN=/sys/class/drm/card0-HDMI-A-1
LOG=/data/local/tmp/edid_boot.log
SUMMARY=/sys/kernel/debug/dri/0/summary

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" shell 'echo alive' >/dev/null 2>&1 || {
    echo "[FATAL] 设备不在线：$SERIAL"; exit 1; }

sh_su() { "$ADB" -s "$SERIAL" shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }

probe() {
    sh_su "echo MODE=\$(cat $MODE_FILE 2>/dev/null || echo auto); \
echo HDMI=\$(cat $CONN/status 2>/dev/null); \
echo OVERRIDE_BYTES=\$(wc -c < $OVR 2>/dev/null); \
echo EDID_BYTES=\$(wc -c < $CONN/edid 2>/dev/null); \
echo EDID_MD5=\$(md5sum $CONN/edid 2>/dev/null | cut -d\" \" -f1); \
echo VENDOR=\$(dd if=$CONN/edid bs=1 skip=8 count=2 2>/dev/null | od -An -tx1 | tr -d \" \"); \
echo MODES3200=\$(grep -c \"^3200x1600\" $CONN/modes 2>/dev/null); \
echo PHYSICAL=\$(grep -m1 \"Display mode:\" $SUMMARY 2>/dev/null | sed \"s/^ *//\"); \
echo HWC_PID=\$(getprop init.svc_debug_pid.vendor.hwcomposer-2-1); \
echo MANUFACTURER=\$(getprop ro.product.manufacturer); \
echo VRSURPORT=\$(getprop ro.vr.surport); \
echo WHITELIST_MOUNT=\$(mount | grep -c resolution_white); \
echo BOOTLOG_LAST=\$(tail -2 $LOG 2>/dev/null | tr \"\\n\" \"|\")"
}

verdict() {
    ov=$(sh_su "wc -c < $OVR 2>/dev/null" | tr -d ' \r\n')
    ed=$(sh_su "wc -c < $CONN/edid 2>/dev/null" | tr -d ' \r\n')
    vd=$(sh_su "dd if=$CONN/edid bs=1 skip=8 count=2 2>/dev/null | od -An -tx1" | tr -d ' \r\n')
    echo "----- 判定 -----"
    if [ "${ov:-x}" = "0" ] && [ "${ed:-0}" -gt 0 ] 2>/dev/null; then
        echo "[PASS] DDC 直通成立：override=0，内核自己读到 ${ed}B EDID（厂商=${vd}）"
        if [ "$vd" = "22f6" ]; then
            echo "       读到的是眼镜真实 HWV EDID；EDID 注入是多余的。"
        else
            echo "       ⚠️ 厂商不是 22f6，可能是转接器兜底 EDID，需人工核对 DTD。"
        fi
    elif [ "${ov:-x}" != "0" ]; then
        echo "[N/A]  当前 override=${ov}B（注入态），无法判定直通；先 passthrough + reboot。"
    else
        echo "[FAIL] DDC 不通：override=0 但 edid=${ed}B —— 转接器 HDMI 输入侧没应答。"
    fi
    echo "       注意：直通成立 ≠ 眼镜点亮。点亮看 PHYSICAL 是否为 3200x1600p70。"
}

case "$ACTION" in
check)
    echo "----- DDC 直通体检（只读）-----"
    probe
    verdict
    ;;

verify)
    echo "----- 重启后完整判据 -----"
    sh_su "date; uptime; getprop ro.boot.bootreason"
    probe
    echo "----- 本次开机日志尾部 -----"
    sh_su "tail -6 $LOG 2>/dev/null"
    verdict
    ;;

passthrough)
    echo "[1/2] 存档当前 mode 并切到 force-off"
    sh_su "cp -f $MODE_FILE $MODE_BAK 2>/dev/null; \
cp -f $OVR /data/local/tmp/hvr-edid-before-ddc.bin 2>/dev/null; \
echo BEFORE=\$(cat $MODE_BAK 2>/dev/null); \
echo force-off > $MODE_FILE; \
echo NOW=\$(cat $MODE_FILE); \
echo BIN_COMMON=\$(ls -l /data/adb/modules/hvrglass/common/edid_only.bin 2>/dev/null | wc -l); \
echo BIN_DATA=\$(ls -l $DAT/edid_only.bin 2>/dev/null | wc -l)"
    echo "[2/2] 完成（尚未重启）。两份 EDID 文件保留，伪装与白名单不会丢。"
    echo "      重启：sh $HERE/ddc-passthrough.sh $SERIAL reboot"
    echo "      重启后：sh $HERE/ddc-passthrough.sh $SERIAL verify"
    ;;

restore)
    echo "[i] 恢复验证前的 mode"
    sh_su "if [ -f $MODE_BAK ]; then cp -f $MODE_BAK $MODE_FILE; else echo force-vr > $MODE_FILE; fi; \
echo MODE=\$(cat $MODE_FILE)"
    echo "      下次开机会按该 mode 注入；运行时 override 不受影响。"
    ;;

reboot)
    echo "[i] 执行 reboot（眼镜 HDMI + 独立供电请保持接通）"
    "$ADB" -s "$SERIAL" shell "su -c 'reboot'" >/dev/null 2>&1
    echo "[i] 无线 adb 会短暂断开；约 30~90 秒后用 verify 查判据。"
    ;;

*)
    echo "[FATAL] 未知动作：$ACTION（check|passthrough|restore|reboot|verify）"
    exit 2
    ;;
esac
