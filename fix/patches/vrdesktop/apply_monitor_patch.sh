#!/bin/sh
# apply_monitor_patch.sh —— 一键重出 com.huawei.vrservice（双补丁）
#
# 补丁 1：VRService.onCreate 里 mDeviceNodeMonitor 创建后补 start()，
#   让 /dev/ttyUSB1 vcom 读线程跑起来，遮挡传感器（PROXIMITY）事件才能
#   到达 VR 桌面（黑屏/亮屏）。详见 inject_monitor_start.py 头注释。
# 补丁 2（2026-11-08）：VRDeviceNodeMonitor.processBattery 的 below-5 /
#   below-20 两个分支 no-op 化。补丁 1 让 monitor 跑起来后，本机电池通道
#   Broken pipe 恒读 0 → 0x12 关机通知 → launcher 放弃 VR 准备 → 黑屏。
#   详见 fix_battery_noop.py 头注释与 2026-11-08 排查分析第二章。
#
# 用法：
#   BASE_APK=/path/to/原包.apk sh apply_monitor_patch.sh [serial]
#   （不带 BASE_APK 则从设备拉当前安装包作底本）
#
# 依赖：项目根目录的 tools/{baksmali-fat,smali-fat}.jar、JRE17、
#   AndroidSDK build-tools、signing/hvr-compat-debug.jks。
set -e

SERIAL="${1:-}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -W 2>/dev/null || cd "$(dirname "$0")/../../.." && pwd)"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"
BT="${BUILD_TOOLS:-D:/Tools/AndroidSDK/build-tools/34.0.0}"
JAVA="$ROOT/build/tmp/jre17/jdk-17.0.21+9-jre/bin/java.exe"
OUT="$ROOT/build/tmp/vrsvc"
KS="$ROOT/signing/hvr-compat-debug.jks"

step() { echo "==> $*"; }

[ -f "$JAVA" ] || { echo "[FATAL] 缺少 $JAVA"; exit 1; }
for j in baksmali-fat.jar smali-fat.jar; do
    [ -f "$ROOT/tools/$j" ] || { echo "[FATAL] 缺少 $ROOT/tools/$j"; exit 1; }
done
mkdir -p "$OUT"

step "1/6 确定底本 APK"
if [ -n "$BASE_APK" ]; then
    cp -f "$BASE_APK" "$OUT/base.apk"
else
    [ -n "$SERIAL" ] || { echo "[FATAL] 无 BASE_APK 时需要 serial 参数"; exit 1; }
    "$ADB" connect "$SERIAL" >/dev/null 2>&1
    P=$("$ADB" -s "$SERIAL" shell "pm path com.huawei.vrservice" | tr -d '\r' | sed 's/^package://' | head -1)
    [ -n "$P" ] || { echo "[FATAL] 设备上没有 com.huawei.vrservice"; exit 1; }
    "$ADB" -s "$SERIAL" pull "$P" "$OUT/base.apk" >/dev/null
fi
echo "  底本: $(stat -c %s "$OUT/base.apk") B"

step "2/6 baksmali 反编译 classes.dex"
rm -rf "$OUT/smali"
"$JAVA" -jar "$ROOT/tools/baksmali-fat.jar" d "$OUT/base.apk" -o "$OUT/smali" 2>&1 | tail -1

step "3/7 注入 monitor start()"
python "$ROOT/fix/patches/vrdesktop/inject_monitor_start.py" "$OUT/smali"

step "4/7 封掉假低电量关机通知（battery no-op）"
python "$ROOT/fix/patches/vrdesktop/fix_battery_noop.py" "$OUT/smali"

step "5/7 smali 回编译 + 替换 classes.dex"
"$JAVA" -jar "$ROOT/tools/smali-fat.jar" a "$OUT/smali" -o "$OUT/classes-new.dex" 2>&1 | tail -1
python "$ROOT/fix/patches/vrdesktop/replace_dex.py" "$OUT/base.apk" classes.dex \
    "$OUT/classes-new.dex" "$OUT/unsigned.apk"

step "6/7 zipalign + 重签"
"$BT/zipalign.exe" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner.bat" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/prox-signed.apk" "$OUT/aligned.apk"
"$BT/apksigner.bat" verify --print-certs "$OUT/prox-signed.apk" 2>&1 | grep "SHA-256" | head -1

step "7/7 安装 + 归档"
if [ -n "$SERIAL" ]; then
    "$ADB" -s "$SERIAL" push "$OUT/prox-signed.apk" /data/local/tmp/vrsvc-prox.apk >/dev/null
    "$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/vrsvc-prox.apk" | tr -d '\r'
fi
cp -f "$OUT/prox-signed.apk" "$ROOT/fix/apks/com.huawei.vrservice.apk"
echo "  产物: $OUT/prox-signed.apk（已归档到 fix/apks/com.huawei.vrservice.apk）"
echo "完成。验证：logcat | grep -E 'DeviceNodeMonitor|buffer type'"
