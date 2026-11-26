#!/bin/sh
# build-compat-dex.sh —— 从 shared/java 重新编译兼容层 dex（含 SBS 面板修复）
#
# 这是 build/build-module.ps1 里「编译存根 → 编译 shared/java → d8」三步的
# Linux/Mac 版，只产出单独的 compat dex，供 apply-sbs-panel-fix.sh 换芯用。
# 不碰 manifest / smali / 重编整包，因此不需要 decode 树或 36 个补丁。
#
# 依赖：javac、java、android.jar、r8.jar（D8）。可用环境变量覆盖路径：
#   JAVAC, JAVA, ANDROID_JAR, D8_JAR, OUT
#
# 用法：sh tools/build-compat-dex.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
ANDROID_JAR="${ANDROID_JAR:-$ROOT/tools/android.jar}"
D8_JAR="${D8_JAR:-$ROOT/tools/r8.jar}"
OUT="${OUT:-$ROOT/build/compat-dex/compat-sbs-panel-fix.dex}"
WORK="${WORK:-$ROOT/build/tmp/compat-build}"

step() { echo "==> $*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }

command -v "$JAVAC" >/dev/null 2>&1 || die "缺少 javac：$JAVAC"
[ -f "$ANDROID_JAR" ] || die "缺少 android.jar：$ANDROID_JAR（可用 ANDROID_JAR 指定）"
[ -f "$D8_JAR" ] || die "缺少 r8.jar：$D8_JAR（可用 D8_JAR 指定，见文档下载方式）"

rm -rf "$WORK" && mkdir -p "$WORK/stub" "$WORK/compat" "$WORK/dex"

step "1/3 编译隐藏 API 存根（shared/stubs）"
find "$ROOT/shared/stubs" -name '*.java' -print > "$WORK/stub.txt"
"$JAVAC" -nowarn -Xlint:none -encoding UTF-8 -source 8 -target 8 \
    -cp "$ANDROID_JAR" -d "$WORK/stub" @"$WORK/stub.txt"

step "2/3 编译兼容层（shared/java）"
find "$ROOT/shared/java" -name '*.java' -print > "$WORK/compat.txt"
"$JAVAC" -nowarn -Xlint:none -encoding UTF-8 -source 8 -target 8 \
    -cp "$ANDROID_JAR:$WORK/stub" -d "$WORK/compat" @"$WORK/compat.txt"
echo "  编译类数: $(find "$WORK/compat" -name '*.class' | wc -l)"

step "3/3 D8 生成 dex"
find "$WORK/compat" -name '*.class' -print | sort > "$WORK/classes.txt"
"$JAVA" -cp "$D8_JAR" com.android.tools.r8.D8 \
    --lib "$ANDROID_JAR" --min-api 24 --output "$WORK/dex" @"$WORK/classes.txt"

mkdir -p "$(dirname "$OUT")"
cp -f "$WORK/dex/classes.dex" "$OUT"
echo "完成: $OUT ($(stat -c %s "$OUT") B)"
echo "下一步：sh tools/apply-sbs-panel-fix.sh <serial> <package>"
