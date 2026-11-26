#!/bin/sh
# apply-sbs-panel-fix.sh —— 把「SBS 面板按面积选大屏」修复注入到设备上已装好的 APK
#
# 背景（docs/SBS-PANEL-FIX.md）：2026-11-26 修复了 shared/java 里
#   VrPlatformCompat.externalDisplay() / HvrPanelFinder 的面板选择逻辑（改为按可视
#   面积取最大），解决 dual 档下 SBS 面板被压成 100x100 空壳。该改动已编译成
#   build/compat-dex/compat-sbs-panel-fix.dex。本脚本把它换进 APK 的 compat dex。
#
# 为什么是「换 dex」而不是「重编全包」：仓库 7 个 APK 各自注入了同一份 compat dex
#   （历史固定叫 classes4.dex），36 个 manifest/smali 补丁已固化在设备上的 APK 里。
#   只替换这一份 dex 即可生效，不必重跑整条补丁链，也不会动其他补丁。
#
# 前提：
#   - 设备上已安装打过 compat 补丁的华为 VR APK（含 classes4.dex / VrPlatformCompat 类）；
#   - adb 可用（ADB 变量可覆盖）；本机有 python3、java、zipalign、apksigner；
#   - 签名沿用 signing/hvr-compat-debug.jks（与其他包一致，免卸载）。
#
# 用法：
#   sh tools/apply-sbs-panel-fix.sh [serial] [package]
#     serial  : 默认 192.168.43.133:5555
#     package : 默认 com.huawei.vrlauncherx
#               （面板 Presentation 由桌面/投屏进程创建；两包都含 compat dex，
#                需要哪个就传哪个。可分别对本机相关包执行。）
#   环境变量：ADB, ZIPALIGN, APKSIGNER, JAVA, KEYSTORE, OUT
#
# 幂等：可重复执行；每次都从设备拉当前 APK 作底本，不叠加旧产物。
set -e

SERIAL="${1:-192.168.43.133:5555}"
PKG="${2:-com.huawei.vrlauncherx}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-adb}"
JAVA="${JAVA:-java}"
ZIPALIGN="${ZIPALIGN:-zipalign}"
APKSIGNER="${APKSIGNER:-apksigner}"
KEYSTORE="${KEYSTORE:-$ROOT/signing/hvr-compat-debug.jks}"
NEW_DEX="${NEW_DEX:-$ROOT/build/compat-dex/compat-sbs-panel-fix.dex}"
REPLACE_PY="$ROOT/fix/patches/vrdesktop/replace_dex.py"
OUT="${OUT:-$ROOT/build/tmp/sbs-panel-fix}"
FINAL="$OUT/$PKG.sbs-panel-fix.apk"

step() { echo "==> $*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }

[ -f "$NEW_DEX" ] || die "缺少新 dex：$NEW_DEX（先用 tools/build-compat-dex.sh 生成）"
[ -f "$KEYSTORE" ] || die "缺少签名库：$KEYSTORE"
[ -f "$REPLACE_PY" ] || die "缺少换 dex 工具：$REPLACE_PY"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"
command -v "$JAVA" >/dev/null 2>&1 || die "缺少 java：$JAVA"

mkdir -p "$OUT"

step "1/6 连接设备并拉取 $PKG 当前 APK（保留所有既有补丁）"
"$ADB" connect "$SERIAL" >/dev/null 2>&1 || true
P=$("$ADB" -s "$SERIAL" shell "pm path $PKG" 2>/dev/null | tr -d '\r' | sed 's/^package://' | head -1)
[ -n "$P" ] || die "设备上找不到 $PKG"
"$ADB" -s "$SERIAL" pull "$P" "$OUT/base.apk" >/dev/null
cp -f "$OUT/base.apk" "$OUT/base.orig.apk"
echo "  底本: $(stat -c %s "$OUT/base.apk") B"

step "2/6 定位 compat dex（含 VrPlatformCompat 类的那个）"
DEX_ENTRY=$(python3 - "$OUT/base.apk" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
marker = b'Lcom/huawei/vrframework/compat/VrPlatformCompat;'
hits = [n for n in z.namelist()
        if n.endswith('.dex') and marker in z.read(n)]
if len(hits) != 1:
    sys.stderr.write("期望恰好一个 compat dex，实际: %r\n" % hits)
    raise SystemExit(1)
print(hits[0])
PY
) || die "无法唯一定位 compat dex（该 APK 可能未打 compat 补丁）"
echo "  compat dex: $DEX_ENTRY"

step "3/6 校验新 dex 含修复方法"
python3 - "$NEW_DEX" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'dex\n', "不是 dex"
for k in (b'Lcom/huawei/vrframework/compat/VrPlatformCompat;',
          b'Lcom/huawei/vrvirtualscreen/mirror/HvrPanelFinder;',
          b'largestDisplay'):
    assert k in d, "新 dex 缺少 %s" % k.decode()
print("  新 dex %d B，类与 largestDisplay 方法齐全" % len(d))
PY

step "4/6 替换 dex（其余条目逐字节保留）"
python3 "$REPLACE_PY" "$OUT/base.apk" "$DEX_ENTRY" "$NEW_DEX" "$OUT/unsigned.apk"

step "5/6 对齐 + 重签"
"$ZIPALIGN" -p -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" sign --ks "$KEYSTORE" \
    --ks-key-alias hvrcompat --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$FINAL" "$OUT/aligned.apk"
"$JAVA" -jar "$APKSIGNER" verify --print-certs "$FINAL" 2>&1 | grep 'SHA-256' | head -1 || true
echo "  产物: $FINAL ($(stat -c %s "$FINAL") B)"

step "6/6 安装（pm install -r 保留数据）"
"$ADB" -s "$SERIAL" push "$FINAL" "/data/local/tmp/$(basename "$FINAL")" >/dev/null
"$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/$(basename "$FINAL")" | tr -d '\r'

echo
echo "完成。切换 dual 档让大屏当面板："
echo "  sh fix/tools/vr-overlay-mode.sh $SERIAL dual"
echo "验收："
echo "  adb -s $SERIAL shell logcat -d | grep -E 'panel by|panel presentation shown|HvrPanelFinder'"
echo "  （应显示 panel by ... #N <大屏尺寸>，不再是 100x100）"
