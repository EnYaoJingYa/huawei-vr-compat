#!/system/bin/sh
#
# wadb —— 无线 adb 开机自启（独立 Magisk 模块）
#
# 设计目标：**结构上不可能卡开机**。
#   - 没有 post-fs-data.sh：完全不在 zygote 之前执行任何东西
#   - service.sh 只做一件事：拉起一个后台子 shell 然后立刻退出，
#     所有等待/重试都在子 shell 里，且有次数上限
#   - 不 mount、不 remount、不碰 /system、不写任何系统文件
#   - 全程只操作属性和 adbd 进程（init 会自动拉回）
#
# 禁用开关：开机前 touch /data/adb/wadb/disable 即可整体跳过。
# 运行日志：/data/local/tmp/wadb.log
#
# 为什么独立成模块：
#   hvrglass 模块里有 EDID 注入、bind mount、HWC 白名单这些"重"逻辑，
#   一旦开机异常需要禁用它排查；adb 自启必须活下来当救砖通道。
#   职责拆开后：卡 logo → 禁 hvrglass → 无线 adb 依然在 → 还能远程修。
#
# 另一个教训（2026-11-04）：刷机会清掉 persist.adb.tcp.port。
#   所以这里每次开机都重新写入，不依赖上次持久化。

MODDIR=${0%/*}
LOG=/data/local/tmp/wadb.log

if [ -f /data/adb/wadb/disable ]; then
    echo "$(date) 检测到 disable 开关，跳过" >> "$LOG"
    exit 0
fi

echo "$(date) wadb service.sh 启动" >> "$LOG"

(
    # ---- 等 boot_completed（最多 120s），永不阻塞 boot 流程 ----
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do
        i=$((i + 1))
        sleep 2
    done
    if [ "$(getprop sys.boot_completed)" != "1" ]; then
        echo "$(date) 120s 内未完成开机，放弃本次自启" >> "$LOG"
        exit 0
    fi
    sleep 5   # 再让网络栈起一下

    # ---- 端口持久化（刷机后必丢，每次重写）----
    setprop persist.adb.tcp.port 5555 2>/dev/null
    setprop service.adb.tcp.port 5555 2>/dev/null

    # ---- 有限次自检：5555 没监听就 init 级重启 adbd ----
    # 用 ctl.stop/ctl.start 而不是 kill：init 会带着当前属性完整地重新拉起 adbd，
    # 裸 kill 后 init 的自动重启在部分固件上不会进入 tcp 监听模式。
    # 重试 10 次、间隔约 6s，全部有界。
    n=0
    while [ $n -lt 10 ]; do
        if netstat -tln 2>/dev/null | grep -q ':5555'; then
            echo "$(date) adb tcp 5555 监听正常（第 $n 轮检查）" >> "$LOG"
            exit 0
        fi
        n=$((n + 1))
        echo "$(date) 5555 未监听，init 级重拉 adbd（第 $n/10 次）" >> "$LOG"
        setprop service.adb.tcp.port 5555
        setprop ctl.stop adbd 2>/dev/null
        sleep 1
        setprop ctl.start adbd 2>/dev/null
        sleep 5
    done
    echo "$(date) 10 次重拉后 5555 仍未监听 —— 插 USB 排查 adbd" >> "$LOG"
) &

exit 0
