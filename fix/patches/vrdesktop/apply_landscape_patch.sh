#!/bin/sh
# =============================================================================
# 修复「VR 桌面被掰成竖屏 → 眼镜只显示双目小窗」的一键工具
#
#   sh fix/patches/vrdesktop/apply_landscape_patch.sh [serial]
#
# 背景（2026-11-07 实测）：
#   VrSystemActor.lockLandscape() 是给「手机原生竖屏」写的，无条件写
#   USER_ROTATION=ROTATION_90(1)。RK3566 盒子原生就是 1920x1080 横屏，
#   再转 90° 变成 1080x1920 竖屏，而 HWC 物理输出是 3200x1600 横屏
#   → VR 桌面被 letterbox 压成中央小窗、上下大黑边。
#
#   纯 settings 层改不回来：lockLandscape() 会持续写回 1（守护拉锯会让
#   Unity 黑屏）。必须改 dex。
#
# 做法（最小差分）：
#   在 com.huawei.hvrsdkserverapp 的 classes4.dex 里，把 lockLandscape()
#   的 `const/4 v4, 0x1` 改成 `const/4 v4, 0x0`（字节码 12 14 -> 12 04）。
#   v4 在该方法里只用于 getInt 默认值和 putInt(USER_ROTATION, v4)，
#   于是 USER_ROTATION 写入 ROTATION_0，盒子保持横屏。
#   只改 1 个字节（+ 重算 DEX 的 SHA1/Adler32），其余 404 个 APK 条目
#   逐字节不变；签名沿用项目 debug 密钥，可 pm install -r 覆盖。
#
#   实测：USER_ROT 稳定为 0、日志 `display locked to landscape`、
#   主屏 real 1920x1080 横屏、眼镜双目画面横向铺满（对比此前中央小窗）。
#
# 依赖：python3、Android build-tools 的 zipalign/apksigner.jar、java（JRE 17），
#       以及 fix/signing/hvr-compat-debug.jks（口令 android）。
#       可用环境变量 ADB / JAVA / BUILD_TOOLS 覆盖路径。
#
# 可回退：脚本把设备原 APK 存到 build/tmp/landscape/base.apk，
#         adb install -r 该文件即可还原；或重跑 fix/install.sh 的 full 模式。
# =============================================================================
set -eu

SERIAL="${1:-192.168.43.133:5555}"
# 必须用盘符风格（pwd -W）：Windows 原生 python/java 不认 MSYS 的 /f/... 路径。
ROOT=$(cd "$(dirname "$0")/../../.." && (pwd -W 2>/dev/null || pwd))
OUT="$ROOT/build/tmp/landscape"
PATCHDIR="$ROOT/fix/patches/vrdesktop"
KEYSTORE="$ROOT/fix/signing/hvr-compat-debug.jks"

find_adb() {
    [ -n "${ADB:-}" ] && [ -x "$ADB" ] && { printf '%s' "$ADB"; return 0; }
    command -v adb 2>/dev/null && return 0
    for c in "/d/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/f/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/c/platform-tools/adb.exe"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
ADB=$(find_adb) || { echo "[FATAL] 找不到 adb，请设置 ADB 环境变量"; exit 1; }

find_java() {
    [ -n "${JAVA:-}" ] && [ -x "$JAVA" ] && { printf '%s' "$JAVA"; return 0; }
    command -v java 2>/dev/null && return 0
    for j in "$ROOT"/build/tmp/jre17/*/bin/java.exe /c/Program\ Files/Java/*/bin/java.exe; do
        [ -x "$j" ] && { printf '%s' "$j"; return 0; }
    done
    return 1
}
JAVA=$(find_java) || {
    echo "[FATAL] 找不到 java（apksigner 需要）。可下载 Temurin JRE 17 解压到"
    echo "        build/tmp/jre17/ 或设置 JAVA=/path/to/java.exe"; exit 1; }

# 同样用盘符风格：apksigner.jar 的路径要交给 Windows java.exe。
BT="${BUILD_TOOLS:-D:/Tools/AndroidSDK/build-tools/34.0.0}"
[ -x "$BT/zipalign.exe" ] || { echo "[FATAL] zipalign 不存在：$BT"; exit 1; }
[ -f "$BT/lib/apksigner.jar" ] || { echo "[FATAL] apksigner.jar 不存在：$BT"; exit 1; }
[ -f "$KEYSTORE" ] || { echo "[FATAL] 签名密钥不存在：$KEYSTORE"; exit 1; }

MSYS2_ARG_CONV_EXCL='*'; export MSYS2_ARG_CONV_EXCL
mkdir -p "$OUT"

step() { echo; echo "===== $* ====="; }

step "1/7 连接设备并拉取当前 hvrsdkserverapp APK"
"$ADB" connect "$SERIAL" >/dev/null 2>&1
P=$("$ADB" -s "$SERIAL" shell "pm path com.huawei.hvrsdkserverapp" | tr -d '\r' | sed 's/^package://')
[ -n "$P" ] || { echo "[FATAL] 设备上没有该包"; exit 1; }
"$ADB" -s "$SERIAL" pull "$P" "$OUT/base.apk" 2>&1 | tail -1
echo "  原 APK: $(stat -c %s "$OUT/base.apk") B（回退底本）"

step "2/7 提取 classes4.dex 并定位目标指令"
python3 - "$OUT/base.apk" "$OUT/classes4.dex" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    b = z.read('classes4.dex')
open(sys.argv[2], 'wb').write(b)
print('  classes4.dex:', len(b), 'B')
PY
python3 "$PATCHDIR/patch_lock_landscape.py" inspect "$OUT/classes4.dex"

step "3/7 打 1 字节补丁（12 14 -> 12 04）"
python3 "$PATCHDIR/patch_lock_landscape.py" patch "$OUT/classes4.dex" "$OUT/classes4-patched.dex"

step "4/7 替换 dex（其余条目逐字节保留）"
python3 "$PATCHDIR/replace_dex.py" "$OUT/base.apk" classes4.dex \
    "$OUT/classes4-patched.dex" "$OUT/unsigned.apk"

step "5/7 zipalign + apksigner v1/v2 重签"
"$BT/zipalign.exe" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$BT/lib/apksigner.jar" sign \
    --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/patched-signed.apk" "$OUT/aligned.apk"

step "6/7 校验签名与证书一致性"
"$JAVA" -jar "$BT/lib/apksigner.jar" verify --print-certs "$OUT/patched-signed.apk" \
    | grep -E "Signer #1 certificate SHA-256" | head -1
NEW=$("$JAVA" -jar "$BT/lib/apksigner.jar" verify --print-certs "$OUT/patched-signed.apk" \
      2>/dev/null | grep "SHA-256 digest" | head -1)
OLD=$("$JAVA" -jar "$BT/lib/apksigner.jar" verify --print-certs "$OUT/base.apk" \
      2>/dev/null | grep "SHA-256 digest" | head -1)
[ "$NEW" = "$OLD" ] || { echo "[FATAL] 签名证书与原包不一致，拒绝安装"; exit 1; }
echo "  [OK] 证书与原包一致，可 pm install -r 覆盖"

step "7/7 安装到设备"
"$ADB" -s "$SERIAL" push "$OUT/patched-signed.apk" /data/local/tmp/hvr-landscape.apk 2>&1 | tail -1
"$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/hvr-landscape.apk" 2>&1 | tr -d '\r'
"$ADB" -s "$SERIAL" shell "rm -f /data/local/tmp/hvr-landscape.apk" >/dev/null 2>&1

echo
echo "[完成] 重新触发一次 VR 会话（辅助屏删掉再写回，或重跑一键安装）后验收："
echo "  settings get system user_rotation   -> 0（由框架自己写，不需要守护）"
echo "  dumpsys display | grep mOverrideDisplayInfo  -> real 1920 x 1080（横屏）"
echo "  眼镜应显示横向铺满的左右眼画面，而非中央小窗"
echo
echo "[回退] adb install -r $OUT/base.apk"
