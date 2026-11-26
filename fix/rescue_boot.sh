#!/bin/sh
# =============================================================================
# rescue_boot.sh —— 卡 logo 救砖（USB 线连盒子后在本机 Git Bash 执行）
#
# 用法：
#   sh rescue_boot.sh                     # 交互式：取证 + 列出模块
#   sh rescue_boot.sh --disable-hvrglass  # 取证后禁用 hvrglass 模块并重启
#   sh rescue_boot.sh --install-wadb      # 顺便装上 wadb 自启模块 zip
#
# 原理：卡 logo 阶段 USB adbd 通常已经起来（adbd 由 init 极早拉起），
#       只要 USB 调试开着就能远程操作；无线 5555 反而要等 boot_completed。
# =============================================================================
set -u
ADB="/d/Tools/AndroidSDK/platform-tools/adb.exe"
SERIAL="${1:-}"
DO=""
case "${1:-}" in
    --disable-hvrglass) DO="$1"; SERIAL="${2:-}" ;;
    --install-wadb)     DO="$1"; SERIAL="${2:-}" ;;
esac
MSYS_NO_PATHCONV=1; export MSYS_NO_PATHCONV

if [ -z "$SERIAL" ]; then
    "$ADB" start-server >/dev/null 2>&1
    SERIAL=$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')
    [ -n "$SERIAL" ] || { echo "[FATAL] 没有在线设备。USB 插好盒子再跑，或指定序列号"; exit 1; }
fi
echo "[i] 设备: $SERIAL"
sh_() { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }

echo "===== 1. 开机状态 ====="
echo "  boot_completed = $(sh_ getprop sys.boot_completed)"
echo "  init crashing  = $(sh_ getprop sys.init.updatable_crashing)"
echo "  vold.decrypt   = $(sh_ getprop vold.decrypt)"
echo "  bootanim       = $(sh_ getprop init.svc.bootanim)"

echo "===== 2. system_server / zygote 是否在崩溃循环 ====="
sh_ "logcat -d -b crash -t 200 | grep -E 'FATAL EXCEPTION|Process: system_server|Zygote' | tail -20" | sed 's/^/  /'
sh_ "logcat -d -t 300 | grep -iE 'system_server.*(died|crash)|Watchdog' | tail -15" | sed 's/^/  /'

echo "===== 3. Magisk 模块清单 ====="
sh_ "su -c 'ls /data/adb/modules'" | sed 's/^/  /'
sh_ "su -c 'for m in /data/adb/modules/*/; do echo \$m: \$(ls \$m | tr \n  ); done'" | sed 's/^/  /'

echo "===== 4. 模块自身日志 ====="
sh_ "tail -20 /data/local/tmp/edid_boot.log" 2>/dev/null | sed 's/^/  /'
sh_ "tail -20 /data/local/tmp/hidraw_perm.log" 2>/dev/null | sed 's/^/  /'
sh_ "tail -20 /data/local/tmp/wadb.log" 2>/dev/null | sed 's/^/  /'

echo "===== 5. 最近一次重启原因 ====="
sh_ "getprop sys.boot.reason; getprop ro.boot.bootreason" | sed 's/^/  /'

if [ "$DO" = "--disable-hvrglass" ]; then
    echo "===== 禁用 hvrglass 模块 ====="
    sh_ "su -c 'touch /data/adb/modules/hvrglass/disable && ls /data/adb/modules/hvrglass/disable'"
    echo "  [i] 下次开机 Magisk 会跳过该模块（伪装/EDID/白名单全部还原为裸系统）"
fi

if [ "$DO" = "--install-wadb" ]; then
    HERE="$(cd "$(dirname "$0")" && pwd)"
    ZIP="$HERE/../build/tmp/wadb-v1.0.zip"
    [ -f "$ZIP" ] || ZIP="$HERE/../magisk-module/wadb.zip"
    echo "===== 安装 wadb 模块: $ZIP ====="
    "$ADB" -s "$SERIAL" push "$ZIP" /data/local/tmp/wadb.zip >/dev/null \
        && sh_ "su -c 'magisk --install-module /data/local/tmp/wadb.zip'" | sed 's/^/  /'
fi

if [ "$DO" != "" ]; then
    echo "===== 重启验证（如确认执行）====="
    echo "  确认无误后执行: adb -s $SERIAL shell \"su -c 'reboot'\""
fi
echo "===== 完成。结论判读：见 刷机后问题分析与恢复手册.md ====="
