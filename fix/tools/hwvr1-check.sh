#!/bin/sh
# hwvr1-check.sh —— 一键体检「/dev/hwvr1 是否指到真控制接口」+ 第二道闸
#
# 用法：
#   sh fix/tools/hwvr1-check.sh [serial]     # 默认 192.168.43.133:5555
#
# 背景（2026-11-08 真机实测，见 fix/2026-11-08-眼镜黑屏排查分析.md 第七章）：
#   眼镜黑屏/桌面退回 VRPrepareActivity 有两道软件闸：
#     闸 1  /dev/hwvr1 指到 CV10(hidraw0) 而非控制口(hidraw1)。
#           两者描述符前 3 字节都是 `06 ff 00`，不能只靠前缀判断；
#           必须真发一次 HIDIOCGFEATURE(4)（hwvr-probe）或比对描述符长度。
#     闸 2  vr_system_state binder 未发布 → CheckVrMode "is not VRMode" → SDK Quit。
#   本脚本只读，不改设备状态。probe 仅在这里手动一次性调用；
#   **守护主循环已改为纯 sysfs 描述符长度判据、不再每 3 秒发 GET_FEATURE**
#   （2026-11-08 第三轮：频繁发 USB control transfer 会加剧 hub 端口
#   `disabled by hub (EMI?)` 重连，导致「一进 VR 桌面就闪退」，见 README 11.8）。
set -u

SERIAL="${1:-192.168.43.133:5555}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"
PROBE_LOCAL="$ROOT/fix/magisk-module/modules/hwvr-probe"
PROBE=/data/local/tmp/hwvr-probe

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1 || {
    echo "[FATAL] 连不上 $SERIAL"; exit 1; }

# 探测二进制：优先用模块自带的，其次把仓库里的推到 /data/local/tmp
if ! "$ADB" -s "$SERIAL" shell '[ -x /data/adb/modules/hvrglass/hwvr-probe ]' \
        >/dev/null 2>&1; then
    if [ -f "$PROBE_LOCAL" ]; then
        MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push \
            "$PROBE_LOCAL" "$PROBE" >/dev/null 2>&1
        "$ADB" -s "$SERIAL" shell "chmod 755 $PROBE" >/dev/null 2>&1
    fi
else
    PROBE=/data/adb/modules/hvrglass/hwvr-probe
fi

echo "===== 1. hidraw 枚举（pre=描述符前3B / bytes=实际长度 / probe=协议应答）====="
"$ADB" -s "$SERIAL" shell "
for d in /sys/class/hidraw/hidraw*; do
    [ -e \"\$d\" ] || continue
    n=\$(basename \$d)
    pre=\$(od -An -tx1 -N3 -v \$d/device/report_descriptor 2>/dev/null | tr -d ' \n')
    len=\$(od -An -tx1 -v \$d/device/report_descriptor 2>/dev/null | wc -w)
    hid=\$(grep HID_ID \$d/device/uevent 2>/dev/null | tr -d '\r')
    nm=\$(grep HID_NAME \$d/device/uevent 2>/dev/null | cut -d= -f2- | tr -d '\r')
    if [ -x $PROBE ]; then $PROBE /dev/\$n >/dev/null 2>&1; rc=\$?; else rc=NA; fi
    printf '%-9s pre=%-8s bytes=%-4s probe_rc=%-3s %s %s\n' \"\$n\" \"\$pre\" \"\$len\" \"\$rc\" \"\$hid\" \"\$nm\"
done" 2>&1 | sed 's/^/  /'

echo
echo "===== 2. /dev/hwvr1 指向 ====="
CUR=$("$ADB" -s "$SERIAL" shell 'readlink /dev/hwvr1' 2>/dev/null | tr -d '\r')
echo "  hwvr1 -> ${CUR:-（不存在）}"
BEST=$("$ADB" -s "$SERIAL" shell "
best=''; rank=-1
for d in /sys/class/hidraw/hidraw*; do
    [ -e \"\$d\" ] || continue
    pre=\$(od -An -tx1 -N3 -v \$d/device/report_descriptor 2>/dev/null | tr -d ' \n')
    [ \"\$pre\" = '06ff00' ] || continue
    dev=/dev/\$(basename \$d); r=0
    if [ -x $PROBE ] && $PROBE \$dev >/dev/null 2>&1; then r=10000; fi
    len=\$(od -An -tx1 -v \$d/device/report_descriptor 2>/dev/null | wc -w | tr -d ' \n')
    [ -n \"\$len\" ] || len=0
    r=\$((r + len))
    if [ \$r -gt \$rank ]; then rank=\$r; best=\$dev; fi
done
echo \$best" 2>/dev/null | tr -d '\r')
echo "  应为   -> ${BEST:-（未发现控制接口）}"
if [ -n "$BEST" ] && [ "$CUR" = "$BEST" ]; then
    echo "  [OK] 闸 1 通过"
else
    echo "  [FAIL] 闸 1 未通过：守护会把链接改回错误接口（每 3 秒一次）"
    echo "         修法：更新 fix/magisk-module/modules/service.sh 并重新部署模块"
fi

echo
echo "===== 3. vr_system_state 注册表（闸 2）====="
REG=$("$ADB" -s "$SERIAL" shell 'timeout 5 content call --uri content://com.huawei.vrlauncherx.registry --method getService --arg vr_system_state' 2>/dev/null | tr -d '\r')
case "$REG" in
    *binder=*) echo "  [OK] 已发布：$REG" ;;
    *) echo "  [FAIL] 未发布（$REG）→ 桌面会 CheckVrMode SDK Quit"
       echo "         修法：先 force-stop 并重启 ArvrRuntimeService，再启动桌面" ;;
esac

echo
echo "===== 4. 栈顶与最近失败计数 ====="
"$ADB" -s "$SERIAL" shell 'dumpsys activity activities | grep -E "mResumedActivity" | head -1' 2>/dev/null | sed 's/^/  /'
L=$("$ADB" -s "$SERIAL" logcat -d -v threadtime 2>/dev/null)
for k in "ioGetVendorInfo failed" "dev_open" "OnApplicationQuit" "active device(2) OK" "is not VRMode"; do
    n=$(printf '%s\n' "$L" | grep -c "$k")
    printf '  %-28s %s\n' "$k" "$n"
done

echo
echo "===== 5. 守护最近改链接记录 ====="
"$ADB" -s "$SERIAL" shell 'su -c "grep -E \"hwvr1|vr_system_state\" /data/local/tmp/hidraw_perm.log | tail -8"' 2>/dev/null | sed 's/^/  /'
echo "完成（全程只读）"
