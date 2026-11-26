#!/system/bin/sh
# =============================================================================
# light-on.sh —— 华为 VR Glass 一键点亮（2026-11-05 实测成功流程固化）
#
# root 下执行：
#   sh /data/adb/hvrglass/light-on.sh          # 一键点亮
#   sh /data/adb/hvrglass/light-on.sh check    # 只体检，不改任何东西
#   sh /data/adb/hvrglass/light-on.sh off      # 清除强制分辨率属性（接便携屏前）
#
# 成功流程（手册第六章；11-03 10:37:56、11-05 18:10 两次实测逐项一致）：
#   ① 3200x1600 白名单 bind mount（HWC mode_verify 只放行白名单内模式）
#   ② persist.vendor.resolution.HDMI-A-0 / main = 3200x1600@70
#      ★ 绝不动 persist.vendor.framebuffer.*：它残留会造成黑屏/假关机
#   ③ stop surfaceflinger 后【等 HWC PID 变化】再 start surfaceflinger
#      （HWC 约 4 秒才跟随退出重启；盲等 2 秒会接回旧 HWC → 永远 1080p，
#       2026-11-07 钉死的竞态根因，详见 ③ 段注释）
#      ★ 绝不用 setprop ctl.restart surfaceflinger（4.2 实测整机重启）
#   验收：Find best mode-id=4 : 3200x1600p70 / Display mode 3200x1600p70
#         / clk[412180]
#
# 前置硬条件：眼镜必须已激活。EDID 厂商 22f6 = HWV 真实 EDID（眼镜醒着，
# 自带 3200x1600@70/90 两条 DTD）；22d2 = 转换器默认 EDID（眼镜 DP 侧休眠）。
# 模式表里没有 3200x1600 就说明眼镜没醒 —— 按手册 4.3 先用 PC/手机点亮一次
# 再插回盒子，盒子单方面调时序没用。本脚本会拒绝执行，不做任何强扭。
#
# 开机阶段不做这些动作：EDID 注入 / detect 重探 / 自动重启 HWC / 自动重启 SF
# 都会卡 logo 或让图形会话僵死（手册 4.1、6.3、2026-11-05 崩循环复盘）。
# 本脚本只在用户主动调用时运行；开机时 HWC 首次 Init 选不到 3200
# （属性/挂载就位晚于 HWC 启动，2026-11-06/07 反复实测），所以
# ★ 每次开机/断电后都要重跑一次本脚本点亮。
# =============================================================================

LOG=/data/local/tmp/hvr-light-on.log
CONN=/sys/class/drm/card0-HDMI-A-1
SUMMARY=/sys/kernel/debug/dri/0/summary
WL_SRC=/data/adb/hvrglass/resolution_white.xml
WL_DST=/system/usr/share/resolution_white.xml
P_MAIN=persist.vendor.resolution.main
P_A0=persist.vendor.resolution.HDMI-A-0
RES=3200x1600@70

log() { echo "$*"; echo "$(date) $*" >> "$LOG"; }
die() { log "[FAIL] $*"; exit 1; }

# Magisk 的 resetprop 在，就真删；否则退到 setprop --delete；再不行设空值
# （HWC 读到空值会显示 Unkonw，等于没有强制分辨率，不会残留硬找 3200）。
del_prop() {
    resetprop --delete "$1" 2>/dev/null && return 0
    setprop --delete "$1" 2>/dev/null && return 0
    setprop "$1" "" 2>/dev/null
}

# ---------------------------------------------------------------- 体检
vendor=$(dd if="$CONN/edid" bs=1 skip=8 count=2 2>/dev/null | od -An -tx1 | tr -d ' \r\n')
status=$(cat "$CONN/status" 2>/dev/null | tr -d ' \r\n')
n3200=$(grep -c '^3200x1600' "$CONN/modes" 2>/dev/null)
[ -z "$n3200" ] && n3200=0
wl_sys=$(grep -c '3200x1600' "$WL_DST" 2>/dev/null)
[ -z "$wl_sys" ] && wl_sys=0
cur=$(head -7 "$SUMMARY" 2>/dev/null | grep -m1 'Display mode:' | tr -d '\r')

do_check() {
    echo "=== 眼镜 / 显示链路体检 ==="
    echo "  HDMI status      : ${status:-unknown}"
    echo "  EDID 厂商 ID     : ${vendor:-读不到}  (22f6=HWV 真实/醒着, 22d2=转换器默认/没醒)"
    echo "  模式表 3200 条数 : $n3200"
    echo "  /system 白名单 3200 条数 : $wl_sys"
    echo "  resolution.main  : $(getprop $P_MAIN)"
    echo "  resolution.HDMI-A-0 : $(getprop $P_A0)"
    echo "  framebuffer.main : $(getprop persist.vendor.framebuffer.main)"
    echo "  当前物理输出     : ${cur:-读不到}"
    echo "  HWC 最近一次选模 : $(logcat -d -s hwc-drm-connector 2>/dev/null | grep 'Find best mode' | tail -1)"
}

case "${1:-on}" in
    check) do_check; exit 0 ;;
    off)
        del_prop "$P_MAIN"; del_prop "$P_A0"
        log "[OK] 已清除强制分辨率属性（main/HDMI-A-0），framebuffer.* 未动。"
        log "     接便携屏前建议重启一次盒子让 HWC 重新 probe。"
        exit 0 ;;
    on|"") ;;
    *) echo "用法: sh light-on.sh [on|check|off]"; exit 1 ;;
esac

[ "$(id -u)" = "0" ] || die "需要 root：su -c 'sh /data/adb/hvrglass/light-on.sh'"
echo "===== $(date) 一键点亮开始 =====" >> "$LOG"

# ---------------------------------------------------------------- 无线 ADB 端口属性
# wadb 开机自检会同时写这两个属性；运行中重拉 adbd 时若只有 service.*，
# 重启后的 adbd 不开 TCP 监听，5555 永远不通 —— 这正是 2026-11-07
# 「点亮其实成功、却只能拔电源才能连回 ADB、一拔又把 3200 清零」的根因。
# 每次点亮幂等重写，保证后续任何一次 adbd 重拉都会监听 5555。
setprop persist.adb.tcp.port 5555
setprop service.adb.tcp.port 5555

# ---------------------------------------------------------------- 前置闸门
[ "$status" = "connected" ] || die "HDMI 未连接（$status）。先把眼镜插好再跑。"
if [ "$n3200" -lt 1 ]; then
    die "模式表里没有 3200x1600（EDID 厂商=${vendor:-无}）。眼镜 DP 侧没醒：
     按手册 4.3 先用 PC/手机把眼镜点亮一次，保持 Type-C 供电再插回盒子，
     然后重跑本脚本。盒子单方面调时序不会亮。"
fi
if [ "$vendor" != "22f6" ]; then
    log "[WARN] EDID 厂商是 ${vendor}（历史成功为 22f6），但模式表含 3200，继续尝试。"
fi

# ---------------------------------------------------------------- ① 白名单
if [ "$wl_sys" -lt 2 ]; then
    [ -f "$WL_SRC" ] || die "白名单母本缺失：$WL_SRC（重跑一键安装工具）"
    mount -o bind "$WL_SRC" "$WL_DST" 2>/dev/null || \
        log "[WARN] bind mount 返回失败，继续检查实际内容"
    wl_sys=$(grep -c '3200x1600' "$WL_DST" 2>/dev/null)
    [ -z "$wl_sys" ] && wl_sys=0
    [ "$wl_sys" -ge 2 ] || die "白名单没生效（/system 里 3200 条目=$wl_sys），HWC 会回落 1080p"
    log "[1/3] 白名单 bind mount 生效（/system 里 3200 条目=$wl_sys）"
else
    log "[1/3] 白名单已在位（/system 里 3200 条目=$wl_sys），跳过挂载"
fi

# ---------------------------------------------------------------- ② 属性
setprop "$P_A0" "$RES"
setprop "$P_MAIN" "$RES"
log "[2/3] resolution.HDMI-A-0 / main = $RES（framebuffer.* 保持不动）"

# 已经点亮就别再重启 SF：反复重启 HWC/SF 会让图形会话僵死
# （2026-11-04 晚 Surface$OutOfResourcesException 的教训）。
# ①/② 仍照做，保证 persist 属性就位。
if echo "$cur" | grep -q '3200x1600p70'; then
    log "[OK] 物理输出已是 3200x1600p70，跳过 SF 重启（避免无谓重启图形会话）。"
    log "     ★ 注意：重启/断电后 HWC 开机首次 Init 选不到 3200（时序问题），"
    log "       开机后需要重跑一次本脚本。"
    echo "✅ 眼镜已点亮（3200x1600@70），无需重启。"
    exit 0
fi

# ---------------------------------------------------------------- ③ 重启 SF
# 2026-11-07 竞态根因钉死：SF 停止后 HWC 约 4 秒才跟着退出（客户端死亡），
# init 随即重启 HWC、全新 Init 会按 属性+白名单+内核模式表 选到 3200。
# 旧版「sleep 2」太短，start surfaceflinger 把还没退出的旧 HWC 又接回去，
# HWC 不重新 Init → 永远 1080p。历史「时灵时不灵」全是这个竞态：
#   * 11-03 10:37 / 11-05 18:10 / 11-06 10:24 成功 = HWC 恰好来得及退出（新 PID）
#   * 11-06 23:34 / 11-07 06:58 失败 = 旧 PID 未变
# 现在盯住 HWC PID 变化，变了（= 全新 Init 完成）再启动 SF，一次成功。
HWC_PID_PROP=init.svc_debug_pid.vendor.hwcomposer-2-1
old_hwc=$(getprop $HWC_PID_PROP)
log "[3/3] stop surfaceflinger；等待 HWC 跟随重启（PID $old_hwc -> ?）..."

# ---------------------------------------------------------------- 点亮后自恢复无线 ADB
# stop/start surfaceflinger 会冲掉 adbd 的 5555 监听。PC 侧
# fix/adb-keepalive.sh 派生的守护是 adb shell → su -c 的后代，SF 停止时
# 会被会话一起清理（nohup / setsid 实测均无效，守护日志连「5555 lost」
# 都来不及写），结果只能靠拔电源后的 wadb 开机自检恢复 —— 而拔电源
# 又把刚点亮的 3200 清零，形成死循环。
# 本脚本是设备端进程且实测能活过 SF 重启，故由它自己安排一次定时重拉：
# 25 秒后（SF 已起、HWC 已选模、验收日志已写完）init 级 stop/start adbd，
# PC 侧无需断电即可连回复验。子 shell 的父进程是本脚本，不会被清理。
(
    sleep 25
    setprop service.adb.tcp.port 5555
    setprop ctl.stop adbd 2>/dev/null
    sleep 1
    setprop ctl.start adbd 2>/dev/null
) &
log "[adb] 已安排 25 秒后重拉 adbd 恢复 5555（无需拔电源）"

stop surfaceflinger
hwc_new=""
i=0
while [ $i -lt 25 ]; do
    sleep 2
    hwc_new=$(getprop $HWC_PID_PROP)
    if [ -n "$hwc_new" ] && [ "$hwc_new" != "$old_hwc" ]; then
        break
    fi
    i=$((i + 1))
done
if [ -n "$hwc_new" ] && [ "$hwc_new" != "$old_hwc" ]; then
    log "     HWC 已跟随重启：$old_hwc -> $hwc_new（约 $((i * 2 + 2)) 秒），全新 Init 选模中"
else
    log "[WARN] 50 秒内 HWC 未跟随重启（PID 仍 $old_hwc），照常启动 SF，本次可能不亮。"
fi
sleep 3
start surfaceflinger

# 这里必须轮询，不能固定 sleep 10 就判定：
#   * SF 重启后 HWC 要重新 probe + 选模，实测可能要 20-40 秒；
#   * 更麻烦的是 SF 重启偶尔会把 system_server 带崩触发整机重启，adb 短暂
#     断开、summary 读到旧值。2026-11-05 23:00 就因此误判失败，把刚写好的
#     persist 属性删掉，重启后 HWC 只能回落 1080p —— 成功配置反而被脚本毁了。
# 轮询最多 90 秒，期间绝不删属性。
summary=""
i=0
while [ $i -lt 30 ]; do
    sleep 3
    summary=$(head -7 "$SUMMARY" 2>/dev/null)
    if echo "$summary" | grep -q '3200x1600p70'; then
        break
    fi
    i=$((i + 1))
done

# ---------------------------------------------------------------- 验收
best=$(logcat -d -s hwc-drm-connector 2>/dev/null | grep 'Find best mode' | tail -1)
echo "$summary" >> "$LOG"
[ -n "$best" ] && echo "$best" >> "$LOG"

if echo "$summary" | grep -q '3200x1600p70'; then
    log "[OK] 点亮成功：$(echo "$summary" | grep -m1 'Display mode:' | tr -d '\r')"
    log "     $(echo "$summary" | grep -m1 'clk\[' | tr -d '\r')"
    [ -n "$best" ] && log "     $best"
    log "     ★ 重启/断电后开机不会自动亮（HWC 开机 Init 时序问题），需重跑本脚本。"
    echo
    echo "✅ 眼镜物理输出已锁定 3200x1600@70（clk 412180）。"
    echo "   接便携屏前执行: sh /data/adb/hvrglass/light-on.sh off"
    exit 0
fi

# 没点亮时**不要一律删属性**：眼镜在位、模式表含 3200 时，persist 属性
# 是下次开机 HWC 首次 probe 选到 3200 的唯一依据，删了就永远回落 1080p。
# 且眼镜没醒时 HWC 只是回落 1080p，不会崩（11-05 实测），保留风险很低。
# 只有「眼镜明确失活」才撤销，避免给普通显示器硬找 3200。
status_now=$(cat "$CONN/status" 2>/dev/null | tr -d ' \r\n')
n3200_now=$(grep -c '^3200x1600' "$CONN/modes" 2>/dev/null)
[ -z "$n3200_now" ] && n3200_now=0
if [ "$status_now" != "connected" ] || [ "$n3200_now" -lt 1 ]; then
    del_prop "$P_MAIN"; del_prop "$P_A0"
    log "[FAIL] 未点亮且眼镜已失活（status=$status_now, 3200 模式=$n3200_now），已回滚属性。"
    log "       按手册 4.3 先激活眼镜再重跑。"
else
    log "[WARN] 本次未切到 3200，但眼镜在位（22f6 / $n3200_now 条 3200）—— 保留 persist 属性。"
    log "       SF 重启可能触发了整机重启；等系统稳定后重跑本脚本，或重启一次让 HWC 重新 probe。"
    log "       接便携屏前才需要执行 off 清属性。"
fi
die "未点亮。当前输出：$(echo "$summary" | grep -m1 'Display mode:' | tr -d '\r')。
     体检：sh /data/adb/hvrglass/light-on.sh check；眼镜在位时可稍后重跑本脚本。"
