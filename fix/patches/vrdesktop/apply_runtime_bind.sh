#!/bin/sh
# apply_runtime_bind.sh —— 补上从未发生的 bindRuntimeService，接通 6DoF 判定
#
# 现场（2026-11-08）：`bind RuntimeService : 0`、`mRuntimeInterface == null` 每帧刷、
# `Huawei 6Dof Header is false`。全 SDK 中 registerReceivers() 没有调用点（死代码），
# 而它内部的 TemperatureReceiver.register() 才是 bindRuntimeService 的唯一调用者。
# 于是在 HvrSdkBridge（手里握着 native SetClass 那份 Class）里补这一步。
#
# 关键：必须用 SetClass 那份 Class 的 ClassLoader 去加载 VrParamsRequester，
# 否则会落进 VrFrameworkBootstrap 另建的 L3 副本，静态单例不是同一个。
# 详见 fix_runtime_bind.py 头注释。
#
# 用法：
#   sh fix/patches/vrdesktop/apply_runtime_bind.sh [serial]
#
# 从设备当前 APK 拉底本继续打，保留 glass-grace / panel-bootstrap 等既有补丁。
set -e

SERIAL="${1:-192.168.43.133:5555}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -W 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"
BT="${BUILD_TOOLS:-D:/Tools/AndroidSDK/build-tools/34.0.0}"
JAVA="$ROOT/build/tmp/jre17/jdk-17.0.21+9-jre/bin/java.exe"
KS="$ROOT/signing/hvr-compat-debug.jks"
APKSIGNER="$BT/lib/apksigner.jar"
OUT="$ROOT/build/tmp/runtime_bind"

step() { echo "==> $*"; }

[ -f "$JAVA" ] || { echo "[FATAL] 缺少 $JAVA"; exit 1; }
[ -f "$APKSIGNER" ] || { echo "[FATAL] 缺少 $APKSIGNER"; exit 1; }
[ -f "$KS" ] || { echo "[FATAL] 缺少 $KS"; exit 1; }
for j in baksmali-fat.jar smali-fat.jar; do
    [ -f "$ROOT/tools/$j" ] || { echo "[FATAL] 缺少 $ROOT/tools/$j"; exit 1; }
done
mkdir -p "$OUT"
"$ADB" connect "$SERIAL" >/dev/null 2>&1

step "1/7 拉设备当前 APK 作底本（保留既有补丁）"
P=$("$ADB" -s "$SERIAL" shell 'pm path com.huawei.vrlauncherx' | tr -d '\r' | sed 's/^package://' | head -1)
[ -n "$P" ] || { echo "[FATAL] 设备上没有 com.huawei.vrlauncherx"; exit 1; }
"$ADB" -s "$SERIAL" pull "$P" "$OUT/base.apk" >/dev/null
cp -f "$OUT/base.apk" "$OUT/base.orig.apk"
echo "  底本: $(stat -c %s "$OUT/base.apk") B"

step "2/7 提取 classes.dex（HvrSdkBridge 在主 dex；classes4.dex 只放 HvrContextProvider）"
python -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],'wb').write(z.read('classes.dex'))" \
    "$OUT/base.apk" "$OUT/classes.dex"

step "3/7 baksmali 反编译"
rm -rf "$OUT/smali"
"$JAVA" -jar "$ROOT/tools/baksmali-fat.jar" d "$OUT/classes.dex" -o "$OUT/smali" 2>&1 | tail -1

step "4/7 patch HvrSdkBridge.offer 的 FRAMEWORK 分支（幂等）"
python "$ROOT/fix/patches/vrdesktop/fix_runtime_bind.py" "$OUT/smali"

step "5/7 smali 回编译"
"$JAVA" -jar "$ROOT/tools/smali-fat.jar" a "$OUT/smali" -o "$OUT/classes-new.dex" 2>&1 | tail -1
[ -s "$OUT/classes-new.dex" ] || { echo "[FATAL] smali 回编译失败"; exit 1; }

step "6/7 替换 dex + zipalign + 重签"
python "$ROOT/fix/patches/vrdesktop/replace_dex.py" \
    "$OUT/base.apk" classes.dex "$OUT/classes-new.dex" "$OUT/unsigned.apk"
"$BT/zipalign.exe" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" sign --ks "$KS" \
    --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/launcherx-runtime-bind.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" verify --print-certs "$OUT/launcherx-runtime-bind.apk" 2>&1 \
    | grep 'SHA-256' | head -1

step "7/7 安装（pm install -r 重启 launcherx，触发 HVRActivity -> applyFramework）"
MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push "$OUT/launcherx-runtime-bind.apk" \
    /data/local/tmp/launcherx-runtime-bind.apk >/dev/null
"$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/launcherx-runtime-bind.apk" | tr -d '\r'
mkdir -p "$ROOT/fix/apks"
cp -f "$OUT/launcherx-runtime-bind.apk" "$ROOT/fix/apks/com.huawei.vrlauncherx.runtime-bind.apk"
echo "完成。原包备份: $OUT/base.orig.apk"
echo "验收："
echo "  sh fix/tools/vr-input-check.sh $SERIAL"
echo "  adb -s $SERIAL shell logcat -d | grep -E 'HvrSdkBridge|bind RuntimeService|mRuntimeInterface|6Dof'"
