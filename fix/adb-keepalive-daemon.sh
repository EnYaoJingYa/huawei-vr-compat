#!/system/bin/sh
# =============================================================================
# 设备端常驻守护：无线 adb 5555 监听丢失时重拉 adbd
#
# 背景（2026-11-06 实测）：
#   wadb 模块的 service.sh 是「开机阶段有限 10 次自检、成功后 exit」，
#   运行中出现掉线就没人管。而 light-on.sh 的 stop/start surfaceflinger
#   会把 adbd 的 TCP 监听冲掉 —— 设备内核仍活着（ping 通、0% 丢包），
#   但 5555 关闭且不会自愈，只能手动拔电源；拔电源又会把刚点亮的
#   3200x1600p70 清零。这是「点亮了又没了」循环的真实成因。
#
# 本脚本由 fix/adb-keepalive.sh on 以 nohup 后台启动：
#   - 不写任何开机文件、不改 Magisk 模块、不动 init rc
#   - 重启即失效，可随时 off，属于纯运行时最小差分
#   - 与 wadb 不冲突：wadb 开机早期跑完就退出，这里只在运行中兜底
#
# 日志：/data/local/tmp/hvr-adbd-keepalive.log
# =============================================================================
LOG=/data/local/tmp/hvr-adbd-keepalive.log
PIDF=/data/local/tmp/hvr-adbd-daemon.pid

# su -c 退出时会给后台子进程发 SIGHUP，忽略它才能真正常驻
trap '' HUP

echo "$$" > "$PIDF"
echo "$(date) daemon start pid=$$" >> "$LOG"

while true; do
    if ! netstat -tln 2>/dev/null | grep -q ':5555'; then
        echo "$(date) 5555 lost -> re-adbd" >> "$LOG"
        setprop service.adb.tcp.port 5555
        setprop ctl.stop adbd 2>/dev/null
        sleep 1
        setprop ctl.start adbd 2>/dev/null
        sleep 2
    fi
    sleep 3
done
