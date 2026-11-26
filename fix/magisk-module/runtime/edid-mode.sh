#!/system/bin/sh
#
# 运行时切换 HDMI-A-1 的 EDID 覆盖（需要 root）
#
#   edid-mode.sh vr      注入 VR Glass 的 3200x1600@70
#   edid-mode.sh 1080p   注入 1920x1080@60（便携屏/普通显示器救急）
#   edid-mode.sh show    只看状态，不改
#
# 说明：
#   edid_override 一旦写入就常驻内核，**没法清空回直通**（写 0 字节无效）。
#   要恢复「用屏幕自己的 EDID」必须重启，并把 /data/adb/hvrglass/mode
#   设为 force-off，让 post-fs-data.sh 不再注入。
#
#   改完 EDID 后**拔插一次 HDMI 线**（HPD 上升沿），让内核重读 EDID 并换时序。
#   ⚠️ 本盒子不要用 `setprop ctl.restart surfaceflinger`：实测会导致卡死/重启。

OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
CONN=/sys/class/drm/card0-HDMI-A-1
DIR=/data/adb/hvrglass          # 可写数据目录（1080p EDID、mode 文件）
MOD=/data/adb/modules/hvrglass  # 模块目录（VR EDID 在其 common/ 下）

mount | grep -q " /sys/kernel/debug " || mount -t debugfs none /sys/kernel/debug 2>/dev/null

show() {
    echo "连接状态: $(cat $CONN/status 2>/dev/null)"
    echo "当前 EDID: $(wc -c < $CONN/edid 2>/dev/null) 字节"
    echo "覆盖文件: $(wc -c < $OVR 2>/dev/null) 字节"
    echo "启动模式: $(cat $DIR/mode 2>/dev/null || echo auto)"
    sed -n 's/^ *Display mode: /实际输出: /p' /sys/kernel/debug/dri/0/summary 2>/dev/null
}

apply() {
    src="$1"
    name="$2"
    if [ ! -f "$src" ]; then
        echo "缺少 $src"
        exit 1
    fi
    cat "$src" > "$OVR" || { echo "写入 $OVR 失败"; exit 1; }
    echo "已写入 $name（$(wc -c < "$OVR") 字节）"
    echo ""
    echo ">>> 现在请把 HDMI 线（眼镜）拔下来，等 3 秒再插回去 <<<"
    echo "    热插拔会让内核重读 EDID，从而应用新时序。"
    echo "    （不要用 'setprop ctl.restart surfaceflinger'：本盒子会直接卡死/重启）"
    echo ""
    show
}

case "$1" in
    vr)
        apply "$MOD/common/edid_only.bin" "VR Glass 3200x1600@70"
        ;;
    1080p|hd)
        apply "$DIR/edid_1080p.bin" "通用 1920x1080@60"
        ;;
    show|"")
        show
        ;;
    *)
        echo "用法: $0 {vr|1080p|show}"
        exit 2
        ;;
esac
