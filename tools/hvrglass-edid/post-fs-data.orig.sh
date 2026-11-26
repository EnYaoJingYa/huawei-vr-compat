#!/system/bin/sh
#
# HUAWEI VR Glass 开机修复（Magisk 模块 hvrglass）
#
# 问题：VR Glass 的 DDC/EDID 在这台 RK3566 盒子上读不到
#       （/sys/class/drm/card0-HDMI-A-1/edid 长度 0，
#        dmesg 只有 "dwhdmi-rockchip: failed to get edid"），
#       内核于是没有可用模式 → 输出 1080p/720p，
#       而 VR Glass 是固定时序面板，只认 3200x1600@70，所以一直黑屏。
#
# 本模块做两件事：
#   1. 本脚本把一份只声明 3200x1600@70 的假 EDID 写进 debugfs 的
#      edid_override，并带 CEA/HDMI VSDB（600MHz TMDS），否则内核按
#      HDMI 1.4 的 165MHz 上限会把这个模式过滤掉。
#   2. Rockchip HWC 另有一份 CEA-861 分辨率白名单
#      /system/usr/share/resolution_white.xml（由模块 system/ 覆盖），
#      里面没有 3200x1600 时 HWC 会强行把 CRTC 设成 1920x1080。
#
# 必须在 HWC / SurfaceFlinger 首次 probe 之前生效。

MODDIR=${0%/*}
BIN="$MODDIR/common/edid_only.bin"
[ -f "$BIN" ] || BIN=/data/adb/hvrglass/edid_only.bin
OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
LOG=/data/local/tmp/edid_boot.log

[ -f "$BIN" ] || exit 0

mount | grep -q " /sys/kernel/debug " || mount -t debugfs none /sys/kernel/debug 2>/dev/null

i=0
while [ $i -lt 40 ]; do
    if [ -e "$OVR" ]; then
        if cat "$BIN" > "$OVR" 2>/dev/null; then
            echo "$(date) edid_override written ($(wc -c < "$OVR") bytes)" >> "$LOG"
            exit 0
        fi
    fi
    i=$((i + 1))
    sleep 1
done

echo "$(date) timeout waiting for $OVR" >> "$LOG"
exit 1
