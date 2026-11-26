#!/usr/bin/env bash
# VR Glass 6DoF 上机核验脚本（Git Bash / Linux 均可）
# 用法： ./probe-vr.sh            自动找 adb
#        ADB=/d/Tools/AndroidSDK/platform-tools/adb.exe ./probe-vr.sh
# 目的：确认「驱动到底在哪、叫什么」，把 /vendor 里的 hivrar 实现与内核模块定位出来
set -u
ADB="${ADB:-adb}"
if ! command -v "$ADB" >/dev/null 2>&1 && [ ! -x "$ADB" ]; then
  for c in /d/Tools/AndroidSDK/platform-tools/adb.exe "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"; do
    [ -x "$c" ] && ADB="$c" && break
  done
fi
say() { printf '\n\033[36m===== %s =====\033[0m\n' "$*"; }

say "设备"
"$ADB" devices -l

say "① 系统属性：VR / hivrar 相关"
"$ADB" shell "getprop | grep -iE 'hivrar|vr_|\bvr\b|glass'" 2>/dev/null

say "② VR 属性全集（Android VR 模式）"
"$ADB" shell "getprop | grep -iE 'vr\.|virtual'" 2>/dev/null

say "③ vendor 里的 hivrar HAL 实现（★ 真正的驱动入口）"
"$ADB" shell "ls -l /vendor/lib64/hw/ 2>/dev/null | grep -iE 'hivrar|vr'; ls -l /vendor/lib64/ | grep -iE 'hivrar|vr'" 2>/dev/null

say "④ vendor 的 init 配置（HAL 服务名/启动条件）"
"$ADB" shell "ls /vendor/etc/init/ | grep -iE 'hivrar|vr'; echo '---'; grep -RniE 'hivrar|vr' /vendor/etc/init/ 2>/dev/null | head -20" 2>/dev/null

say "⑤ system 侧服务是否在跑"
"$ADB" shell "ps -A | grep -iE 'hivrar|hvrsdk|vrservice|arengine'" 2>/dev/null
"$ADB" shell "service list | grep -iE 'vr|hivrar|ar'" 2>/dev/null

say "⑥ 内核模块"
"$ADB" shell "lsmod | grep -iE 'vr|glass|cam'" 2>/dev/null
"$ADB" shell "ls /vendor/lib/modules/ 2>/dev/null | grep -iE 'vr|glass'" 2>/dev/null

say "⑦ 设备节点"
"$ADB" shell "ls -l /dev/ | grep -iE 'vr|glass|cam|hid|video'" 2>/dev/null

say "⑧ USB 拓扑（眼镜/6DoF 摄像头配件的 VID:PID）"
"$ADB" shell "lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null | grep -E 'Vendor|Product|Manufacturer|Cls|Driver'" 2>/dev/null

say "⑨ 相机：眼镜双摄是否作为普通 Camera 暴露"
"$ADB" shell "dumpsys media.camera | grep -iE 'Camera [0-9]|facing|glass|vr' | head -30" 2>/dev/null
"$ADB" shell "dumpsys media.camera | grep -c 'Camera [0-9]'" 2>/dev/null

say "⑩ 6DoF 数据通路是否活着（抓 20 秒日志）"
"$ADB" shell "logcat -d -t 400 | grep -iE 'vr6dof|Walle|VrPoseState|SLAM|Handler.*Pose'" 2>/dev/null

say "⑪ IMU 原始日志（华为自带的抓取开关产物）"
"$ADB" shell "ls -l /sdcard/immlog/ 2>/dev/null | head" 2>/dev/null

say "⑫ VR 命令"
"$ADB" shell "which vr; vr 2>&1 | head -5" 2>/dev/null

cat <<'EOF'

---- 判读要点 ----
· ③ 里出现 vendor.huawei.hardware.hivrar@2.x-impl.so  → 驱动实现在 vendor，属 HAL 层
· ⑥ 有 vr/glass 相关 .ko                        → 有独立内核模块（否则是走标准 usbhid/uvc）
· ⑦ 出现 /dev/video* 且 ⑨ 相机数量 = 手机摄像头 + 2 → 眼镜双摄是普通 UVC，6DoF 全靠用户态算
· ⑩ 有 "GetPose succ" / "SetVioPose" 行            → 华为自己那套 6DoF 正在跑
· 拿不到 ⑩ 说明 hivrarserver 没起：setprop hal.hivrarddk.exist yes 后再试
EOF
