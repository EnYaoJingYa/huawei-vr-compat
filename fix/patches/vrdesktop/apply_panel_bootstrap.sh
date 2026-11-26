#!/bin/sh
# apply_panel_bootstrap.sh —— 一键让 VR 桌面进程启动时预建「HUAWEI VR Display」
#
# 修的是显示承载链第 ①/② 环的**启动时机**（详见 fix_panel_bootstrap.py 头注释）：
#   原版只在「桌面内部点图标」时顺带建屏，而 SurfaceView 的 surface 是异步
#   回调，当次必然拿不到 displayId -> HvrDisplayRouter 打印 not up yet ->
#   应用全部落到 displayId=0 主屏，VR 桌面 3D 场景里看不到。
# 本补丁把建屏前移到 HvrContextProvider.onCreate()（平台保证 Context 非 null），
# 且屏由 launcherx 自己创建，与后续 setLaunchDisplayId 同 uid，不需要 LSPosed。
#
# 用法：
#   sh fix/patches/vrdesktop/apply_panel_bootstrap.sh [serial]
#
# 与 apply_glass_grace.sh 可叠加：本脚本从**设备当前 APK** 拉底本继续打，
# 不会覆盖 glass-grace 补丁。签名沿用 signing/hvr-compat-debug.jks。
set -e

SERIAL="${1:-192.168.43.133:5555}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -W 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"
BT="${BUILD_TOOLS:-D:/Tools/AndroidSDK/build-tools/34.0.0}"
JAVA="$ROOT/build/tmp/jre17/jdk-17.0.21+9-jre/bin/java.exe"
KS="$ROOT/signing/hvr-compat-debug.jks"
APKSIGNER="$BT/lib/apksigner.jar"
OUT="$ROOT/build/tmp/panel_bootstrap"

step() { echo "==> $*"; }

[ -f "$JAVA" ] || { echo "[FATAL] 缺少 $JAVA"; exit 1; }
[ -f "$APKSIGNER" ] || { echo "[FATAL] 缺少 $APKSIGNER"; exit 1; }
[ -f "$KS" ] || { echo "[FATAL] 缺少 $KS"; exit 1; }
for j in baksmali-fat.jar smali-fat.jar; do
    [ -f "$ROOT/tools/$j" ] || { echo "[FATAL] 缺少 $ROOT/tools/$j"; exit 1; }
done
mkdir -p "$OUT"
"$ADB" connect "$SERIAL" >/dev/null 2>&1

step "1/7 拉设备当前 APK 作底本（保留 glass-grace 等既有补丁）"
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

step "4/7 patch HvrContextProvider.onCreate（幂等）"
python "$ROOT/fix/patches/vrdesktop/fix_panel_bootstrap.py" "$OUT/smali"

step "5/7 smali 回编译"
"$JAVA" -jar "$ROOT/tools/smali-fat.jar" a "$OUT/smali" -o "$OUT/classes4-new.dex" 2>&1 | tail -1

step "6/7 替换 dex + zipalign + 重签"
python "$ROOT/fix/patches/vrdesktop/replace_dex.py" \
    "$OUT/base.apk" classes4.dex "$OUT/classes4-new.dex" "$OUT/unsigned.apk"
"$BT/zipalign.exe" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" sign --ks "$KS" \
    --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/launcherx-panel-boot.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" verify --print-certs "$OUT/launcherx-panel-boot.apk" 2>&1 \
    | grep 'SHA-256' | head -1

step "7/7 安装（pm install -r 会重启 launcherx，触发 provider onCreate）"
MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push "$OUT/launcherx-panel-boot.apk" \
    /data/local/tmp/launcherx-panel-boot.apk >/dev/null
"$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/launcherx-panel-boot.apk" | tr -d '\r'
mkdir -p "$ROOT/fix/apks"
cp -f "$OUT/launcherx-panel-boot.apk" "$ROOT/fix/apks/com.huawei.vrlauncherx.panel-boot.apk"
echo "完成。原包备份: $OUT/base.orig.apk"
echo "验收（眼镜不在位也能验逻辑链）："
echo "  sh fix/tools/vr-display-check.sh $SERIAL"
echo "  adb -s $SERIAL shell logcat -d | grep -E 'HvrPanelBoot|HvrVrPanel|HvrVrDisplay|HvrDisplayRouter'"
