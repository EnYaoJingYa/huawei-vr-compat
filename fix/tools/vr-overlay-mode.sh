#!/bin/sh
# vr-overlay-mode.sh —— 切换副屏（overlay_display_devices）尺寸档位
#
# 背景（2026-11-08，分析文档第十二章 12.4 / 第十三章）：
#   同一块 overlay 副屏被两件事共用，目标互相冲突：
#     A. HvrVrPanelPresenter 在副屏上起 Presentation + SurfaceView，
#        再把 3200x1600 的 `HUAWEI VR Display` 输出进去（需要面积够大）；
#     B. HvrMirrorService 按副屏尺寸推算 SBS 双目每眼分辨率：
#          scale = min((副屏宽/2)/1920, 副屏高/1080)
#          eye   = (round(1920*scale), round(1080*scale))
#   第九章为消除「overlay 是主屏缩小镜像、叠在主屏合成里递归叠影」把副屏
#   压到 100x100/320 -> 每眼仅 50x28，SBS 面板成了空壳（stacks=0）。
#   手册 7.4 成功态是 1920x1080/320 -> 每眼 608x1080。
#
# 本脚本只改 settings global overlay_display_devices，不刷机、不改 APK。
# 修改会触发 DisplayManager 拆掉重建 overlay display，当前 Presentation
# 会 dismiss、虚拟屏随之释放，需重启 VR 桌面进程重新走 panel-bootstrap。
#
# 用法（默认 show，只读）：
#   sh fix/tools/vr-overlay-mode.sh [serial] show
#   sh fix/tools/vr-overlay-mode.sh [serial] small            # 100x100/320，消叠影
#   sh fix/tools/vr-overlay-mode.sh [serial] panel            # 1920x1080/320，SBS 全尺寸
#   sh fix/tools/vr-overlay-mode.sh [serial] dual             # 100x100 + 1920x1080 两块
#   sh fix/tools/vr-overlay-mode.sh [serial] set '800x600/320'
#   sh fix/tools/vr-overlay-mode.sh [serial] restore          # 恢复修改前的值
#
# 注意：dual 提供「两块屏职责分开」的硬件前提（小屏满足在位判据、大屏承载 SBS）。
#   2026-11-26 起，面板选择已按可视面积取最大：VrPlatformCompat.externalDisplay()
#   与 HvrPanelFinder 的各级判据都改为 largestDisplay()，因此大屏会被选为面板，
#   不再退回 100x100 小屏。前提是 APK 用含该修复的兼容层重新构建（见
#   docs/SBS-PANEL-FIX.md）。旧 APK 不含此修复时 dual 仍会命中小屏。
set -u

SERIAL="${1:-192.168.43.133:5555}"
MODE="${2:-show}"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"
BAK="/data/local/tmp/hvr_overlay_display_devices.bak"
KEY="overlay_display_devices"

"$ADB" connect "$SERIAL" >/dev/null 2>&1
sh_shell() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" shell "$1" 2>/dev/null | tr -d '\r'; }

cur() { sh_shell "settings get global $KEY"; }

eye_of() {
    # $1 = WxH/DPI[,;...]；只按第一块算（HvrMirrorService 找的是第一块副屏）
    first=$(printf '%s' "$1" | cut -d';' -f1 | cut -d/ -f1)
    w=$(printf '%s' "$first" | cut -dx -f1)
    h=$(printf '%s' "$first" | cut -dx -f2)
    printf '%s %s' "${w:-0}" "${h:-0}" | awk '{ w=$1+0; h=$2+0; s=(w/2)/1920; t=h/1080; if(t<s)s=t; printf "每眼约 %dx%d", int(1920*s+0.5), int(1080*s+0.5) }'
}

show() {
    v=$(cur)
    echo "=== overlay 副屏现状 ==="
    echo "  $KEY = ${v:-（未设置）}"
    [ "${v:-null}" = "null" ] || echo "  $(eye_of "$v")"
    echo
    echo "  HUAWEI VR Display : $(sh_shell 'dumpsys display | grep -c "DisplayDeviceInfo{\"HUAWEI VR Display\""') 块"
    sh_shell 'dumpsys display | grep -o "DisplayDeviceInfo{\"[^\"]*\": uniqueId=\"[^\"]*\", [0-9]* x [0-9]*" | head -8' | sed 's/^/    /'
    echo
    echo "  眼镜在位: hidraw=$(sh_shell 'ls /dev/hidraw* 2>/dev/null | wc -l')  /dev/hwvr1=$(sh_shell 'test -e /dev/hwvr1 && echo yes || echo no')"
    echo "  备份文件: $(sh_shell "test -f $BAK && cat $BAK || echo '（无）'")"
}

apply() {
    spec="$1"
    old=$(cur)
    if [ -z "$(sh_shell "ls $BAK 2>/dev/null")" ]; then
        sh_shell "settings get global $KEY > $BAK; chmod 644 $BAK" >/dev/null
    fi
    sh_shell "settings put global $KEY '$spec'" >/dev/null
    new=$(cur)
    echo "[+] $KEY: ${old:-（未设置）}  ->  $new"
    echo "    $(eye_of "$new")"
    echo "    原值已备份到设备 $BAK（restore 可回滚）"
    echo "    注意：overlay 重建会 dismiss 当前 Presentation 并释放虚拟屏，"
    echo "          需重启 VR 桌面让 panel-bootstrap 重新建屏。"
}

case "$MODE" in
    show)
        show
        echo
        echo "档位说明：small=消左眼叠影；panel=SBS 全尺寸（可能重新叠影）；"
        echo "          dual=小屏满足在位 + 大屏当面板（需含 2026-11-26 面积优先修复的 APK）"
        ;;
    small)   apply "100x100/320" ;;
    panel)   apply "1920x1080/320" ;;
    dual)    apply "100x100/320;1920x1080/320" ;;
    set)     apply "${3:-100x100/320}" ;;
    restore)
        if [ -z "$(sh_shell "ls $BAK 2>/dev/null")" ]; then
            echo "[!] 设备上没有备份文件 $BAK，无法回滚"; exit 1
        fi
        old=$(sh_shell "cat $BAK")
        if [ "${old:-null}" = "null" ]; then
            sh_shell "settings delete global $KEY" >/dev/null
            echo "[+] 已删除 $KEY（恢复为未设置）"
        else
            apply "$old"
        fi
        ;;
    *)
        echo "用法: sh fix/tools/vr-overlay-mode.sh [serial] {show|small|panel|dual|set SPEC|restore}"
        exit 1
        ;;
esac
