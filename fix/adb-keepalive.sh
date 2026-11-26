#!/bin/sh
# =============================================================================
# 无线 adb 5555 运行时守护（一键开关，纯运行时、不改开机逻辑）
#
#   sh fix/adb-keepalive.sh 192.168.43.133:5555 on      # 启动守护
#   sh fix/adb-keepalive.sh 192.168.43.133:5555 check   # 只读体检
#   sh fix/adb-keepalive.sh 192.168.43.133:5555 off     # 停止守护
#
# 用途：跑 light-on.sh 的 stop/start surfaceflinger 之前先 on，
#       SF 重启冲掉 adbd 的 TCP 监听后守护会在几秒内把 5555 拉回来，
#       点亮结果可以连续验收，不必再手动拔电源（拔电源会清掉 3200）。
# 守护是 nohup 后台进程，重启即失效；不写开机文件、不改 Magisk 模块。
# =============================================================================
set -u
ADB=${ADB:-adb}
SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-check}"
HERE=$(cd "$(dirname "$0")" && pwd)
D=/data/local/tmp
DAEMON=$D/hvr-adbd-daemon.sh
PIDF=$D/hvr-adbd-daemon.pid
LOG=$D/hvr-adbd-keepalive.log

"$ADB" connect "$SERIAL" >/dev/null 2>&1
rsh() { "$ADB" -s "$SERIAL" shell "su -c '$1'"; }

case "$ACTION" in
    on)
        # Windows 版 adb.exe 不认 MSYS2 的 /f/... 绝对路径；用相对文件名 +
        # MSYS2_ARG_CONV_EXCL 保留设备端 /data/... 路径不被转换。
        (cd "$HERE" && MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push \
            adb-keepalive-daemon.sh "$DAEMON" >/dev/null 2>&1) || {
                echo "  [FAIL] push 守护脚本失败"; exit 1; }
        rsh "chmod 755 $DAEMON; [ -f $PIDF ] && kill \$(cat $PIDF) 2>/dev/null; rm -f $PIDF; nohup sh $DAEMON >/dev/null 2>&1 &"
        sleep 2
        rsh "echo PID=\$(cat $PIDF 2>/dev/null); echo LISTEN=\$(netstat -tln 2>/dev/null | grep -c 5555); tail -2 $LOG"
        echo "  [OK] 守护已启动（重启后失效，off 可停）"
        ;;
    off)
        rsh "[ -f $PIDF ] && kill \$(cat $PIDF) 2>/dev/null; rm -f $PIDF; echo stopped"
        ;;
    check)
        rsh "echo PID=\$(cat $PIDF 2>/dev/null); echo LISTEN=\$(netstat -tln 2>/dev/null | grep -c 5555); echo DAEMON_PROC=\$(ps -A 2>/dev/null | grep -c hvr-adbd-daemon); tail -5 $LOG"
        ;;
    *)
        echo "用法: sh adb-keepalive.sh <serial> [on|off|check]"; exit 1 ;;
esac
