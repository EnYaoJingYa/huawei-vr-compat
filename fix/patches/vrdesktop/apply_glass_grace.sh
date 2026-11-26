#!/bin/sh
# apply_glass_grace.sh —— 一键给 com.huawei.vrlauncherx 补「USB 瞬态宽限」
#
# 问题：眼镜 USB 因 `disabled by hub (EMI?)` 整条 hub 掉线重连 1~2 秒，
#   UsbManager.getDeviceList() 瞬间为空 -> VrPlatformCompat 判 usb=false ->
#   VrMonitor.checkVRMode() 凑够 2 个失败项 -> 桌面 SDK 自杀 -> 系统重拉，
#   用户看到「一打开 VR 桌面就闪退」。
#
# 修法：只改 launcherx 的 classes4.dex 里 VrPlatformCompat.hasGlassUsbIdentity()，
#   枚举不到眼镜时回退华为原版判据 new File("/dev/hwvr1").exists()。
#   该节点由 service.sh 在 EMI 窗口用占位普通文件顶住（见 11.9）。
#   必须配合新版 service.sh 一起部署，单改 APK 无效。
#
# 用法：
#   sh fix/patches/vrdesktop/apply_glass_grace.sh [serial]
#
# 依赖：tools/{baksmali-fat,smali-fat}.jar、build/tmp/jre17、AndroidSDK
#   build-tools、signing/hvr-compat-debug.jks（与设备上现有包同签名）。
set -e

SERIAL="${1:-192.168.43.133:5555}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -W 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"
BT="${BUILD_TOOLS:-D:/Tools/AndroidSDK/build-tools/34.0.0}"
JAVA="$ROOT/build/tmp/jre17/jdk-17.0.21+9-jre/bin/java.exe"
KS="$ROOT/signing/hvr-compat-debug.jks"
APKSIGNER="$BT/lib/apksigner.jar"
OUT="$ROOT/build/tmp/glass_grace"

step() { echo "==> $*"; }

[ -f "$JAVA" ] || { echo "[FATAL] 缺少 $JAVA"; exit 1; }
[ -f "$APKSIGNER" ] || { echo "[FATAL] 缺少 $APKSIGNER"; exit 1; }
[ -f "$KS" ] || { echo "[FATAL] 缺少 $KS"; exit 1; }
for j in baksmali-fat.jar smali-fat.jar; do
    [ -f "$ROOT/tools/$j" ] || { echo "[FATAL] 缺少 $ROOT/tools/$j"; exit 1; }
done
mkdir -p "$OUT"
"$ADB" connect "$SERIAL" >/dev/null 2>&1

step "1/7 拉底本 APK（并备份）"
P=$("$ADB" -s "$SERIAL" shell 'pm path com.huawei.vrlauncherx' | tr -d '\r' | sed 's/^package://' | head -1)
[ -n "$P" ] || { echo "[FATAL] 设备上没有 com.huawei.vrlauncherx"; exit 1; }
"$ADB" -s "$SERIAL" pull "$P" "$OUT/base.apk" >/dev/null
cp -f "$OUT/base.apk" "$OUT/base.orig.apk"
echo "  底本: $(stat -c %s "$OUT/base.apk") B"

step "2/7 提取 classes4.dex（compat 类所在）"
python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],'wb').write(z.read('classes4.dex'))" \
    "$OUT/base.apk" "$OUT/classes4.dex"

step "3/7 baksmali 反编译"
rm -rf "$OUT/smali"
"$JAVA" -jar "$ROOT/tools/baksmali-fat.jar" d "$OUT/classes4.dex" -o "$OUT/smali" 2>&1 | tail -1

step "4/7 patch hasGlassUsbIdentity（幂等）"
python "$ROOT/fix/patches/vrdesktop/fix_glass_grace.py" "$OUT/smali"

step "5/7 smali 回编译"
"$JAVA" -jar "$ROOT/tools/smali-fat.jar" a "$OUT/smali" -o "$OUT/classes4-new.dex" 2>&1 | tail -1

step "6/7 替换 dex + zipalign + 重签"
python "$ROOT/fix/patches/vrdesktop/replace_dex.py" \
    "$OUT/base.apk" classes4.dex "$OUT/classes4-new.dex" "$OUT/unsigned.apk"
"$BT/zipalign.exe" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" sign --ks "$KS" \
    --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/launcherx-glass-grace.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" verify --print-certs "$OUT/launcherx-glass-grace.apk" 2>&1 \
    | grep 'SHA-256' | head -1

step "7/7 安装（pm install -r，签名须与现包一致）"
MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push "$OUT/launcherx-glass-grace.apk" \
    /data/local/tmp/launcherx-glass-grace.apk >/dev/null
"$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/launcherx-glass-grace.apk" | tr -d '\r'
mkdir -p "$ROOT/fix/apks"
cp -f "$OUT/launcherx-glass-grace.apk" "$ROOT/fix/apks/com.huawei.vrlauncherx.glass-grace.apk"
echo "完成。原包备份: $OUT/base.orig.apk"
echo "验证: adb shell logcat -d | grep -E 'glass probe|checkVRMode|PrepareActivity Quit'"
