#!/system/bin/sh
#
# HUAWEI VR Glass EDID 注入（Magisk 模块 hvrglass）
#
# 背景：
#   VR Glass 是固定时序面板，只认 3200x1600@70，但它的 DDC/EDID 在这台
#   RK3566 盒子上读不到（dmesg: "dwhdmi-rockchip: failed to get edid"）。
#   没有 EDID 时内核只会给 1080p/720p，眼镜必然黑屏 —— 所以要注入。
#
# 但反过来说：一旦注入，**任何**接在 HDMI 上的屏幕都会被告知「我只支持
#   3200x1600@70」，普通显示器/便携屏锁不上这个时序 → 黑屏。
#   2026-11-02 就是这么把便携屏搞黑的。
#
# 所以这里改成按需注入：
#   mode=auto（默认）  接屏且能读到真实 EDID → 不动；读不到 EDID（眼镜）→ 注入
#   mode=force-vr      无条件注入（确定接的是 VR Glass）
#   mode=force-off     永不注入（纯直通，等于停用本模块的 EDID 部分）
#
# 切换：echo force-off > /data/adb/hvrglass/mode 然后重启。
# 运行时手动切换见同目录 edid-mode.sh（无需重启，但要重启 SurfaceFlinger）。

MODDIR=${0%/*}
BIN="$MODDIR/common/edid_only.bin"
[ -f "$BIN" ] || BIN=/data/adb/hvrglass/edid_only.bin

OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
CONN=/sys/class/drm/card0-HDMI-A-1
LOG=/data/local/tmp/edid_boot.log

[ -f "$BIN" ] || exit 0

mount | grep -q " /sys/kernel/debug " || mount -t debugfs none /sys/kernel/debug 2>/dev/null

MODE=$(cat /data/adb/hvrglass/mode 2>/dev/null | tr -d ' \r\n')
[ -z "$MODE" ] && MODE=auto
echo "$(date) 启动，mode=$MODE" >> "$LOG"

# 等 debugfs 节点出现（HWC 首次 probe 之前必须写好）
i=0
while [ ! -e "$OVR" ] && [ $i -lt 40 ]; do
    i=$((i + 1))
    sleep 1
done
if [ ! -e "$OVR" ]; then
    echo "$(date) 超时：$OVR 未出现" >> "$LOG"
    exit 1
fi

apply=0
case "$MODE" in
    force-vr)
        apply=1
        ;;
    force-off|off|passthrough)
        apply=0
        ;;
    *)
        status=$(cat "$CONN/status" 2>/dev/null | tr -d ' \r\n')
        if [ "$status" = "connected" ]; then
            # 给内核留点时间把真实 EDID 读上来
            sleep 2
            size=$(wc -c < "$CONN/edid" 2>/dev/null | tr -d ' \r\n')
            [ -z "$size" ] && size=0
            if [ "$size" -gt 0 ]; then
                apply=0
                echo "$(date) auto: 读到真实 EDID ${size}B，跳过注入" >> "$LOG"
            else
                apply=1
                echo "$(date) auto: 已接屏但 EDID 为空，判定为 VR Glass，注入" >> "$LOG"
            fi
        else
            # 开机时没接屏：不注入，让后来插上的任何屏幕用自己的 EDID
            apply=0
            echo "$(date) auto: 未接屏（$status），跳过注入" >> "$LOG"
        fi
        ;;
esac

if [ "$apply" = "1" ]; then
    if cat "$BIN" > "$OVR" 2>/dev/null; then
        echo "$(date) 已写入 VR EDID（$(wc -c < "$OVR") 字节）" >> "$LOG"
        exit 0
    fi
    echo "$(date) 写入失败：$OVR" >> "$LOG"
    exit 1
fi

exit 0
