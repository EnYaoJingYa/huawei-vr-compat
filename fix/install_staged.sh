#!/bin/sh
# =============================================================================
# install_staged.sh —— 分阶段上车（2026-11-04 两次卡 logo 后的定位方案）
#
# 背景：全量安装（模块 + 7 包）连续两次卡 logo。备份对比已把变量收敛到：
#   A. hvrglass 模块的 system/ overlay（public.libraries.txt + libc_secshared.so）
#   B. vrservice 12.0.0.302（重签 + sofix_x）
#   C. vrlauncherx ctxfix（apktool 重建）
# （appmarket"更新包"经 md5 对比与旧包相同，已排除；wadb 首次卡 logo 时未在场）
#
# 用法（每步之间重启观察；哪步卡 logo，元凶就是那步加的东西）：
#   sh install_staged.sh <serial> A    # 裸系统+wadb 自启模块（基线，必过）
#   sh install_staged.sh <serial> B    # + hvrglass 模块（无 overlay）
#   sh install_staged.sh <serial> C    # + 5 个旧版 APK（不含 vrservice/launcherx）
#   sh install_staged.sh <serial> D    # + vrservice 12
#   sh install_staged.sh <serial> E    # + vrlauncherx ctxfix（最终完整态）
#   sh install_staged.sh <serial> F    # 终态基础上补 overlay（B~E 全过才做）
#
# 卡了怎么办：USB 插盒子 → sh rescue_boot.sh --disable-hvrglass（或卸载对应 apk）
# =============================================================================
set -u
SERIAL="${1:-192.168.43.133:5555}"
STAGE="${2:-A}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in *MINGW*|*MSYS*|*CYGWIN*) command -v cygpath >/dev/null 2>&1 && HERE="$(cygpath -m "$HERE")" ;; esac
MSYS_NO_PATHCONV=1; export MSYS_NO_PATHCONV
ADB="/d/Tools/AndroidSDK/platform-tools/adb.exe"
SKIP_PKGS="vrservice vrlauncherx"   # C 阶段默认跳过的两个嫌疑包

step() { echo; echo "########## 阶段 $1 ##########"; }

case "$STAGE" in
A)
    step "A: 仅装 wadb 自启模块（基线）"
    "$ADB" -s "$SERIAL" push "$HERE/../build/tmp/wadb-v1.1.zip" /data/local/tmp/wadb.zip \
        && "$ADB" -s "$SERIAL" shell "su -c 'magisk --install-module /data/local/tmp/wadb.zip; setprop persist.adb.tcp.port 5555; rm -f /data/local/tmp/wadb.zip'"
    echo "  [i] 重启后 5555 自动在线。能开机即基线成立。"
    ;;
B)
    step "B: + hvrglass 模块（无 overlay）"
    SKIP_PKGS="vrservice vrlauncherx" sh "$HERE/install.sh" "$SERIAL" --skip-install
    ;;
C)
    step "C: + 5 个旧版 APK（跳过 vrservice / vrlauncherx）"
    SKIP_PKGS="vrservice vrlauncherx" sh "$HERE/install.sh" "$SERIAL"
    ;;
D)
    step "D: + vrservice 12（跳过 vrlauncherx）"
    SKIP_PKGS="vrlauncherx" sh "$HERE/install.sh" "$SERIAL" --skip-install >/dev/null 2>&1
    "$ADB" -s "$SERIAL" install -r -d "$HERE/apks/com.huawei.vrservice.apk" 2>&1 | sed 's/^/  /'
    ;;
E)
    step "E: + vrlauncherx ctxfix"
    "$ADB" -s "$SERIAL" install -r -d "$HERE/../build/tmp/com.huawei.vrlauncherx-ctxfix-signed.apk" 2>&1 | sed 's/^/  /'
    ;;
F)
    step "F: ⛔ 已禁用 —— system overlay 是卡 logo 元凶"
    echo "  2026-11-04 分阶段实测：A~E（无 overlay）全部正常开机，"
    echo "  而两次卡 logo 时 overlay 都在场（public.libraries.txt 整体替换"
    echo "  + libc_secshared.so）。vrservice/VR 链在无 overlay 下实测运行正常，"
    echo "  此 overlay 永久弃用。如确需再试，手动部署后必须保留 USB 救砖通道。"
    exit 1
    ;;
*)
    echo "未知阶段: $STAGE（A~F）"; exit 1
    ;;
esac

echo
echo "下一步：sync 后重启 —— adb -s $SERIAL shell \"su -c 'sync; reboot'\""
echo "开机判定：能连上 5555 且 getprop sys.boot_completed=1 → 本阶段通过，继续下一阶段；"
echo "卡 logo → 元凶=本阶段新增内容，USB 救砖见 rescue_boot.sh"
