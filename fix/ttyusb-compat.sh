#!/bin/sh
# =============================================================================
# 华为 VR Glass vcom 串口节点兼容（/dev/ttyUSB0）一键工具
#
#   sh fix/ttyusb-compat.sh                          # 默认设备 + check
#   sh fix/ttyusb-compat.sh 192.168.43.133:5555 check
#   sh fix/ttyusb-compat.sh 192.168.43.133:5555 on    # 启用（运行时，重启失效）
#   sh fix/ttyusb-compat.sh 192.168.43.133:5555 off   # 解绑（回退）
#   sh fix/ttyusb-compat.sh 192.168.43.133:5555 watch # 前台权限守护（调试用）
#
# 背景（2026-11-06 实测）：
#   12d1:107e "HUAWEI GLASS HID" 有 5 个 USB 接口：
#     :1.0 / :1.1 / :1.2 = class ff / subclass 13 vendor 专用，各有 bulk IN+OUT(512B)
#     :1.3 / :1.4 = HID（usbhid 正常接管，对应 hidraw）
#   通用内核里这 3 个 vendor 接口**没有驱动绑定**，所以永远不生成 /dev/ttyUSB*。
#   而 VRService 的 UpgradeGlass.cpp 硬编码 open("/dev/ttyUSB0")：
#     节点不存在 -> "VcomFdInit : /dev/ttyUSB0 don't exist!"
#     5 次失败 -> "5 times can not open vcom, stop try."
#     -> heartbeat not init 无限循环 -> proximity -1 -> 3D 桌面不启动。
#
#   内核已有 CONFIG_USB_SERIAL_GENERIC=y 与 usbserial_generic 驱动，
#   写 "12d1 107e" 到 /sys/bus/usb-serial/drivers/generic/new_id 即可让
#   驱动接管 3 个 bulk 接口，生成 /dev/ttyUSB0/1/2；HID 接口因无 bulk
#   端点会被驱动跳过，仍由 usbhid 接管（/dev/hwvr1 symlink 不受影响）。
#
# 第二层阻塞：ueventd 给节点 radio:radio 0660，VRService 是 u0_aXX，
#   open() 报 errno: Permission denied。且眼镜 USB 每次重枚举都会重建节点、
#   权限打回 0660 —— 必须常驻守护 chmod，不能只 chmod 一次。
#
# ⚠️ 已验证 / 未验证边界：
#   已验证：节点生成、Permission denied 消失、heartbeat not init 从
#     84~522 次降到 0、FATAL 全程 0。
#   未验证：华为私有 vcom 协议帧能否得到眼镜 MCU 正确响应
#     （getVersionByVcomNative 仍返回空、proximity 仍未推进到 3D 桌面）。
#   所以这个工具只负责「把节点与权限打通」，不等于「眼镜点亮 / 进桌面」。
#
# 可回退：new_id 是运行时注册，重启即消失；off 会立即 unbind。
#   本工具不写任何开机脚本、不改 post-fs-data.sh / 不动开机逻辑。
#   若需要开机后自动常驻，见 fix/magisk-module/modules/service.sh 内
#   受 /data/adb/hvrglass/ttyusb_compat 开关控制的守护段。
# =============================================================================
set -u

SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-check}"

find_adb() {
    if [ -n "${ADB:-}" ] && [ -x "$ADB" ]; then printf '%s' "$ADB"; return 0; fi
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    for c in "/d/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/f/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/c/platform-tools/adb.exe" \
             "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
ADB="$(find_adb)" || { echo "[FATAL] 找不到 adb，请设置 ADB 环境变量"; exit 1; }
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1 || {
    echo "[FATAL] 设备连不上：$SERIAL"; exit 1; }

REMOTE=/data/local/tmp/hvr-ttyusb-compat.sh
LOCAL=build/tmp/hvr-ttyusb-compat.sh
mkdir -p build/tmp 2>/dev/null

cat > "$LOCAL" <<'EOS'
#!/system/bin/sh
A="$1"
NEWID=/sys/bus/usb-serial/drivers/generic/new_id
DRV=/sys/bus/usb/drivers/usbserial_generic

check() {
    echo "--- 眼镜 USB 接口绑定 ---"
    for i in /sys/bus/usb/devices/*:1.*; do
        v=$(cat "${i%:1.*}/idVendor" 2>/dev/null)
        p=$(cat "${i%:1.*}/idProduct" 2>/dev/null)
        [ "$v$p" = "12d1107e" ] || continue
        printf "  %-18s class=%s driver=%s\n" "${i##*/}" \
            "$(cat "$i/bInterfaceClass" 2>/dev/null)" \
            "$(ls -l "$i/driver" 2>/dev/null | sed 's|.*/||')"
    done
    echo "--- /dev/ttyUSB* ---"
    ls -l /dev/ttyUSB* 2>&1 | head -6
    echo "--- new_id ---"
    cat "$NEWID" 2>/dev/null
    echo "--- 最近 USB 重枚举 ---"
    dmesg 2>/dev/null | grep -E "idVendor=12d1, idProduct=107e|device disconnected" | tail -6
    echo "--- VRService vcom 状态（最近 20 条）---"
    logcat -d 2>/dev/null | grep -iE "vcom|ttyUSB0|heartbeat not init" \
        | grep -v "heartbeat not init" | tail -8
    echo "    heartbeat_not_init_count=$(logcat -d 2>/dev/null | grep -c 'heartbeat not init')"
}

case "$A" in
    check) check ;;
    on)
        [ -w "$NEWID" ] || { echo "[FATAL] $NEWID 不可写（内核缺 usbserial_generic？）"; exit 1; }
        echo "12d1 107e" > "$NEWID" 2>/dev/null
        sleep 2
        chmod 666 /dev/ttyUSB* 2>/dev/null
        echo "[OK] 已注册 new_id 并放开权限；当前节点："
        ls -l /dev/ttyUSB* 2>&1 | head -6
        echo "[i] 眼镜重枚举后权限会打回 660，请用 watch 或 service.sh 守护段常驻。"
        ;;
    off)
        for i in /sys/bus/usb/devices/*:1.*; do
            v=$(cat "${i%:1.*}/idVendor" 2>/dev/null)
            p=$(cat "${i%:1.*}/idProduct" 2>/dev/null)
            [ "$v$p" = "12d1107e" ] || continue
            d=$(ls -l "$i/driver" 2>/dev/null | sed 's|.*/||')
            [ "$d" = "usbserial_generic" ] || continue
            echo "${i##*/}" > "$DRV/unbind" 2>/dev/null &&
                echo "  unbind ${i##*/}"
        done
        echo "[i] 已解绑；new_id 注册无法单独删除，重启设备即可彻底回退。"
        ;;
    watch)
        echo "[i] 前台守护中（Ctrl-C 结束）：每 3 秒校正 /dev/ttyUSB* 权限"
        while :; do
            for t in /dev/ttyUSB*; do
                [ -e "$t" ] || continue
                p=$(stat -c '%a' "$t" 2>/dev/null)
                [ "$p" = "666" ] || chmod 666 "$t" 2>/dev/null
            done
            sleep 3
        done
        ;;
    *) echo "用法: hvr-ttyusb-compat.sh {check|on|off|watch}"; exit 2 ;;
esac
EOS

"$ADB" -s "$SERIAL" push "$LOCAL" "$REMOTE" >/dev/null 2>&1 || {
    echo "[FATAL] push 失败（本地脚本：$LOCAL）"; exit 1; }
rm -f "$LOCAL"
"$ADB" -s "$SERIAL" shell "su -c 'sh $REMOTE $ACTION'" 2>&1 | tr -d '\r'
