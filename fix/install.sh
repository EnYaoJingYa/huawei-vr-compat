#!/bin/sh
# =============================================================================
# install.sh —— 华为 VR 全栈一键安装（RK3566 盒子 / Android 11 / Magisk）
#
# 用法：
#   sh install.sh 192.168.43.133:5555              # 完整安装 + 一键点亮眼镜
#   sh install.sh 192.168.43.133:5555 --skip-install   # 只部署模块 + 授权（不装 APK）
#   sh install.sh 192.168.43.133:5555 --no-launch      # 完整安装但不启动应用市场
#   sh install.sh 192.168.43.133:5555 --no-light-on    # 装完不点亮（先用便携屏时）
#   sh install.sh 192.168.43.133:5555 --with-overlay   # 部署 system overlay（不建议，会卡 logo）
#   sh install.sh 192.168.43.133:5555 --no-stable-boot # 不部署开机即亮稳定态
#   sh install.sh 192.168.43.133:5555 --ttyusb-compat  # 打开 ttyUSB 权限守护
#
# --- 只部署/只体检「开机即亮稳定态」，不装 APK、不重启、可回退 ---
#   sh install.sh <serial> --stable-check   # 只读体检
#   sh install.sh <serial> stable          # 只部署三件套（最小差分）
#   sh install.sh <serial> --stable-off    # 回退到部署前母本/mode
#
# 参数可任意顺序、可叠加。本脚本幂等，可反复执行。所有细节见 README.md。
# 眼镜点亮部分严格复刻手册第六章成功流程，见 light-on.sh 头部注释。
#
# 2026-11-07 更新：一键安装现在会 ① 部署 wadb 无线 ADB 开机自启模块 +
# 幂等写 persist./service.adb.tcp.port，② 点亮后等待设备端脚本内嵌的
# 25 秒 adbd 自恢复窗口再做验收。因此整条链路可一次跑完，不再需要
# PC 侧守护或手动拔电源。每次开机/断电后单独点亮只需一条：
#   sh fix/light-on.sh <serial>
# 注意：眼镜 HDMI/EDID 物理链路断开时，点亮脚本会自检拒绝（不误改配置），
# 安装其余步骤照常完成。
# =============================================================================
set -u

SERIAL="${1:-192.168.43.133:5555}"
MODE=full                 # full | --skip-install | --no-launch
WITH_OVERLAY=0            # system overlay 默认不装（卡 logo 元凶）
LIGHT_ON=1                # 装完默认执行一键点亮；眼镜没激活时脚本会自检跳过
STABLE_BOOT=0             # 默认关闭：2026-11-06 两次重启实测证伪（见下）
STABLE_ONLY=0
STABLE_CHECK=0
STABLE_OFF=0
TTYUSB_GUARD=-1           # -1 不动 / 1 打开 / 0 关闭
[ "$#" -gt 0 ] && shift
for a in "$@"; do
    case "$a" in
        --skip-install|--no-launch|full) MODE="$a" ;;
        --with-overlay) WITH_OVERLAY=1 ;;
        --no-light-on)  LIGHT_ON=0 ;;
        --light-on)     LIGHT_ON=1 ;;
        stable|--only-stable) STABLE_ONLY=1 ;;
        --stable-check) STABLE_CHECK=1 ;;
        --stable-off)   STABLE_OFF=1 ;;
        --no-stable-boot) STABLE_BOOT=0 ;;
        --ttyusb-compat) TTYUSB_GUARD=1 ;;
        --no-ttyusb-compat) TTYUSB_GUARD=0 ;;
    esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
# Git Bash / MSYS 下把路径转成 Windows 形式，否则 Windows adb.exe 吃不了 /f/... 路径
case "$(uname -s)" in
    *MINGW*|*MSYS*|*CYGWIN*)
        command -v cygpath >/dev/null 2>&1 && HERE="$(cygpath -m "$HERE")" ;;
esac

# ---- Git Bash 路径转换会破坏 adb 的远端路径，统一关掉 ----
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

# ---- 找 adb ----
find_adb() {
    if [ -n "${ADB:-}" ] && [ -x "$ADB" ]; then printf '%s' "$ADB"; return 0; fi
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    for c in "/d/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/c/platform-tools/adb.exe" "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

ADB="$(find_adb)" || { echo "[FATAL] 找不到 adb，请设置 ADB 环境变量"; exit 1; }
echo "[i] adb = $ADB"
echo "[i] 目标设备 = $SERIAL"

sh_()   { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
# root_()：优先 su -c；su 不可用（未授权/无 Magisk）但 adbd 本身是 root（adb root / 宽松固件）时直接明文执行
root_() {
  local out
  out=$("$ADB" -s "$SERIAL" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')
  if [ "$out" = "0" ]; then
    "$ADB" -s "$SERIAL" shell "su -c '$*'" 2>/dev/null | tr -d '\r'
  else
    "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'
  fi
}

step() { echo; echo "===== $* ====="; }

# ---------------------------------------------------------------------------
# 2026-11-07：点亮会 stop/start surfaceflinger，adbd 的 5555 监听会掉。
# 设备端 light-on.sh 自己是设备端进程，已内嵌「25 秒后 init 级
# stop/start adbd」恢复监听（并幂等写 persist./service.adb.tcp.port），
# 实测 uptime 连续、无需拔电源、无需 PC 侧守护。安装脚本必须等过这段
# 窗口再继续，否则 6/7 验收、7/7 启动全是空输出 —— 旧版「一键安装
# 跑不完」就卡在这里（原来只 sleep 3）。
# ---------------------------------------------------------------------------
adb_alive() {
    "$ADB" connect "$SERIAL" >/dev/null 2>&1
    "$ADB" -s "$SERIAL" shell "true" >/dev/null 2>&1
}

wait_adb() {
    _max="${1:-90}"
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        adb_alive && return 0
        sleep 3
        _i=$((_i + 3))
    done
    return 1
}

# 无线 ADB 开机自启模块：刷机后 persist.adb.tcp.port 必丢，且点亮链路里
# adbd 会被重拉。它纯 late_start、无 post-fs-data、无 mount，结构上不会
# 卡 logo（2026-11-04 分阶段上车 A 阶段实测）。逐文件 push 避免目录嵌套。
ensure_wadb() {
    [ -f "$HERE/magisk-module/wadb/service.sh" ] || {
        echo "  [wadb] 本地缺 wadb 模块文件，跳过"; return 1; }
    "$ADB" -s "$SERIAL" shell mkdir -p /data/local/tmp/hvrfix/wadb >/dev/null 2>&1
    for _f in module.prop service.sh customize.sh; do
        MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push \
            "$HERE/magisk-module/wadb/$_f" "/data/local/tmp/hvrfix/wadb/$_f" >/dev/null 2>&1
    done
    R_SZ=$(sh_ "wc -c < /data/local/tmp/hvrfix/wadb/service.sh 2>/dev/null" | tr -d ' \r\n')
    if [ "${R_SZ:-0}" -lt 500 ]; then
        echo "  [wadb] 推送校验失败（service.sh ${R_SZ:-0}B），跳过部署，设备未改动"
        return 1
    fi
    root_ "mkdir -p /data/adb/modules/wadb /data/adb/wadb; \
cp -f /data/local/tmp/hvrfix/wadb/module.prop /data/adb/modules/wadb/module.prop; \
cp -f /data/local/tmp/hvrfix/wadb/service.sh  /data/adb/modules/wadb/service.sh; \
chmod 644 /data/adb/modules/wadb/module.prop; \
chmod 755 /data/adb/modules/wadb/service.sh; \
setprop persist.adb.tcp.port 5555; \
setprop service.adb.tcp.port 5555; \
rm -rf /data/local/tmp/hvrfix/wadb" >/dev/null 2>&1
    WADB_SZ=$(root_ 'wc -c < /data/adb/modules/wadb/service.sh 2>/dev/null' | tr -d ' \r\n')
    echo "  [wadb] 开机 5555 自启就位（service.sh ${WADB_SZ:-0}B, persist port $(sh_ 'getprop persist.adb.tcp.port')）"
    echo "  [wadb] 端口属性 persist/service.adb.tcp.port = 5555（幂等重写）"
}

# =============================================================================
# 开机即亮稳定态（10-30 / 11-02 历史成功配方，2026-11-06 从另两个项目的
# 会话记录里翻出并固化）。三件套，缺一个都不行：
#   ① EDID 母本用「单 DTD、只声明 3200x1600@70」的 256B 版本
#      (md5 138fb20e…)，内核 modes 只剩一条 3200x1600，HWC 没法回落 1080p。
#      当前设备上被 boot-light-on.sh 换成真实 22f6 多模式 EDID (eba6de4e…)，
#      modes 变成 10 条、含 1080p60 —— 这正是现在点不亮的直接差异。
#   ② resolution_white.xml 走 Magisk systemless overlay
#      (模块 system/usr/share/)，在开机挂载阶段就位；原来只靠
#      post-fs-data.sh 运行时 bind mount，实测 6.5s 晚于 HWC 的 6.03s
#      DrmDevice::Init()/init_white_modes()，白名单永远读不到 3200。
#      注意：这不是 --with-overlay 那个卡 logo 的 public.libraries.txt
#      整体替换；11-04 20:50 分阶段上车已实锤卡 logo 元凶是后者。
#   ③ mode=force-vr 无条件注入。
# 只写数据文件 + 开关，不改开机脚本逻辑、不动 system 分区、不重启；
# --stable-off 可整体回退。生效需要一次受控重启。
#
# ⚠️ 2026-11-06 22:45 真机实测：本方案**未能点亮**，两次受控重启均如此。
#    验收：EDID 已是单模式 138fb20e、内核 modes 只剩一条
#    `3200x1600 clock=412180 h=3200/3260/3268/3308 v=1600/1613/1614/1780
#    flags=0x5`、HWC 命名空间白名单 md5 与 adb 一致且含 3200 条目（含为
#    单模式 EDID 补的 vsync 1613/1614 变体）、mode=force-vr —— 三件套全到位，
#    但 supportedModes 仍只有 [{1920x1080@60}]、VOP 仍
#    `1920x1080p60 / clk[148500] type[40]`（HWC 自造模式）。
#    结合 07:36 的时序证据（HWC 由 late-fs 在开机 6.03s 启动并 Init，
#    post-fs-data 的 EDID 注入/白名单在约 6.5s，晚 0.4s），结论是
#    **HWC 首次 Init 时既没读到 3200 白名单、内核也还没给它 3200 模式**，
#    之后不重读；Magisk systemless overlay 也没抢赢这一刻。
#    → 开机阶段方案（让 EDID + 白名单早于 HWC 6.03s）仍须用户明确授权。
#
# ✅ 2026-11-06 23:02 复核更正：11-05 整机备份 `backup/box-2026-11-05/`
#    里另有一套**运行时点亮配方**，不是开机注入，而且 11-06 18:52 已复现
#    点亮（`clk[412180]`，代价是约 1 分钟后整机重启）。配方四件套：
#      mode=auto（真实 22f6 EDID 直通不注入）
#      + resolution_white.xml md5 528d4e07…（2 条 3200，内核真值 1663/1664）
#      + light-on.sh md5 e3253876…（11-05 18:17 成功版）
#      + 两个 persist.vendor.resolution=3200x1600@70（绝不动 framebuffer.*）
#    再由 light-on.sh 的 bind mount → 属性 → 一次 stop/start surfaceflinger
#    让 HWC 重新初始化选模。**因此本方案默认关闭**，设备已按备份配方还原；
#    需要开机阶段实验时再显式 `sh install.sh <serial> stable`。
#    本段保留作为一键部署/回退能力，供授权后的开机阶段方案直接使用。
# =============================================================================
STABLE_BIN="$HERE/magisk-module/modules/common/edid_only.bin"
STABLE_WL="$HERE/magisk-module/modules/resolution_white.xml"
STABLE_TMP=/data/local/tmp/hvrfix/stable

stable_check() {
    echo "----- 开机即亮稳定态体检（只读）-----"
    root_ "echo BIN_MD5=\$(md5sum /data/adb/modules/hvrglass/common/edid_only.bin 2>/dev/null | cut -d\" \" -f1); \
echo BIN_SIZE=\$(wc -c < /data/adb/modules/hvrglass/common/edid_only.bin 2>/dev/null); \
echo WL_OVERLAY=\$(test -f /data/adb/modules/hvrglass/system/usr/share/resolution_white.xml && echo yes || echo no); \
echo WL_DATA=\$(test -f /data/adb/hvrglass/resolution_white.xml && echo yes || echo no); \
echo MODE=\$(cat /data/adb/hvrglass/mode 2>/dev/null || echo auto); \
echo MODES3200=\$(grep -c \"^3200x1600\" /sys/class/drm/card0-HDMI-A-1/modes 2>/dev/null); \
echo MODES_TOTAL=\$(wc -l < /sys/class/drm/card0-HDMI-A-1/modes 2>/dev/null); \
echo OVERRIDE_BYTES=\$(wc -c < /sys/kernel/debug/dri/0/HDMI-A-1/edid_override 2>/dev/null); \
echo PHYSICAL=\$(head -7 /sys/kernel/debug/dri/0/summary 2>/dev/null | grep -m1 \"Display mode:\"); \
echo TTYUSB_GUARD=\$(test -f /data/adb/hvrglass/ttyusb_compat && echo on || echo off)" | sed 's/^/  /'
    echo "  期望：BIN_MD5=138fb20e… / WL_OVERLAY=yes / MODE=force-vr / 重启后 PHYSICAL 含 3200x1600p70"
}

deploy_stable_boot() {
    [ -f "$STABLE_BIN" ] && [ -f "$STABLE_WL" ] || {
        echo "  [WARN] 缺母本文件，跳过稳定态部署"; return 1; }
    LOCAL_MD5=$(md5sum "$STABLE_BIN" 2>/dev/null | cut -d' ' -f1)
    echo "  [stable] 本地单模式母本 md5: $LOCAL_MD5"
    case "$LOCAL_MD5" in
        138fb20e*) ;;
        *) echo "  [WARN] 本地母本不是「单 DTD 3200x1600@70」版本，拒绝部署"
           echo "         （要保留当前母本请加 --no-stable-boot）"; return 1 ;;
    esac
    "$ADB" -s "$SERIAL" shell mkdir -p "$STABLE_TMP" >/dev/null 2>&1
    MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push "$STABLE_BIN" "$STABLE_TMP/edid_only.bin" >/dev/null 2>&1
    MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push "$STABLE_WL" "$STABLE_TMP/resolution_white.xml" >/dev/null 2>&1
    # 绝不能让 push 失败演变成「用空文件覆盖 EDID 母本」——先校验远端字节数
    R_SZ=$(sh_ "wc -c < $STABLE_TMP/edid_only.bin 2>/dev/null" | tr -d ' \r\n')
    R_WL=$(sh_ "wc -c < $STABLE_TMP/resolution_white.xml 2>/dev/null" | tr -d ' \r\n')
    if [ "$R_SZ" != "256" ] || [ "${R_WL:-0}" -lt 1000 ]; then
        echo "  [FATAL] 推送校验失败（母本 ${R_SZ:-0}B / 白名单 ${R_WL:-0}B），已中止，设备未改动"
        return 1
    fi
    root_ "mkdir -p /data/adb/modules/hvrglass/system/usr/share /data/adb/hvrglass; \
if [ ! -f /data/adb/hvrglass/edid_only.bin.pre-stable ]; then cp -f /data/adb/modules/hvrglass/common/edid_only.bin /data/adb/hvrglass/edid_only.bin.pre-stable 2>/dev/null; fi; \
if [ ! -f /data/adb/hvrglass/mode.pre-stable ]; then cp -f /data/adb/hvrglass/mode /data/adb/hvrglass/mode.pre-stable 2>/dev/null || echo auto > /data/adb/hvrglass/mode.pre-stable; fi; \
cp -f $STABLE_TMP/edid_only.bin /data/adb/modules/hvrglass/common/edid_only.bin; \
cp -f $STABLE_TMP/resolution_white.xml /data/adb/modules/hvrglass/system/usr/share/resolution_white.xml; \
cat $STABLE_TMP/resolution_white.xml > /data/adb/hvrglass/resolution_white.xml; \
chmod 644 /data/adb/modules/hvrglass/common/edid_only.bin /data/adb/modules/hvrglass/system/usr/share/resolution_white.xml /data/adb/hvrglass/resolution_white.xml; \
echo force-vr > /data/adb/hvrglass/mode; \
rm -rf $STABLE_TMP" >/dev/null 2>&1
    echo "  [stable] 已部署：单模式 EDID + systemless 白名单 + mode=force-vr"
    echo "  [stable] 重启生效；回退：sh install.sh $SERIAL --stable-off（再重启）"
}

stable_off() {
    root_ "if [ -f /data/adb/hvrglass/edid_only.bin.pre-stable ]; then cp -f /data/adb/hvrglass/edid_only.bin.pre-stable /data/adb/modules/hvrglass/common/edid_only.bin; chmod 644 /data/adb/modules/hvrglass/common/edid_only.bin; fi; \
rm -f /data/adb/modules/hvrglass/system/usr/share/resolution_white.xml; \
if [ -f /data/adb/hvrglass/mode.pre-stable ]; then cp -f /data/adb/hvrglass/mode.pre-stable /data/adb/hvrglass/mode; fi" >/dev/null 2>&1
    echo "  [stable] 已回退母本 / 白名单 overlay / mode（重启生效）"
}

# =============================================================================
step "0/7 连接设备并体检"
"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device || { echo "[FATAL] 设备连不上"; exit 1; }

DEV_MODEL=$(sh_ getprop ro.product.model)
DEV_VER=$(sh_ getprop ro.build.version.release)
DEV_ABI=$(sh_ getprop ro.product.cpu.abilist)
echo "  型号: $DEV_MODEL  Android: $DEV_VER"
echo "  ABI : $DEV_ABI"
echo "$DEV_ABI" | grep -q armeabi-v7a || echo "  [WARN] 无 32 位支持：除 vrservice 外的 6 个包装不上"

if root_ "id" | grep -q "uid=0"; then
    echo "  root: OK (su 可用)"
else
    echo "  [FATAL] 无 root（su 失败），模块和授权步骤无法执行"
    exit 1
fi

# --- 只体检 / 只部署 / 只回退稳定态：不装 APK、不重启、不动开机脚本 ---
"$ADB" connect "$SERIAL" >/dev/null 2>&1
if [ "$STABLE_CHECK" = "1" ]; then stable_check; exit 0; fi
if [ "$STABLE_OFF" = "1" ];   then stable_off; stable_check; exit 0; fi
if [ "$STABLE_ONLY" = "1" ];  then deploy_stable_boot; stable_check; exit 0; fi

# =============================================================================
step "1/7 安装七个 APK（统一 hvr-compat 签名）"
if [ "$MODE" = "--skip-install" ]; then
    echo "  （--skip-install，跳过）"
else
    "$ADB" -s "$SERIAL" shell mkdir -p /data/local/tmp/hvrfix >/dev/null 2>&1
    install_one() {
        f="$1"; pkg="$(basename "$f" .apk)"
        out=$("$ADB" -s "$SERIAL" install -r -d "$f" 2>&1)
        if echo "$out" | grep -q "Success"; then
            echo "  OK     $pkg"
            return 0
        fi
        # 签名不一致（比如之前装过华为原签/旧签名包）→ 卸载重装
        if echo "$out" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
            echo "  REINST $pkg（签名不一致，卸载重装，数据会丢）"
            "$ADB" -s "$SERIAL" uninstall "$pkg" >/dev/null 2>&1
            out=$("$ADB" -s "$SERIAL" install -r -d "$f" 2>&1)
            echo "$out" | grep -q "Success" && { echo "  OK     $pkg"; return 0; }
        fi
        echo "  FAIL   $pkg"
        echo "$out" | sed 's/^/         /'
        return 1
    }
    FAILED=0
    for f in "$HERE"/apks/*.apk; do
        # SKIP_PKGS：空格分隔的包名文件名片段（不带 .apk），命中则跳过——分阶段排查用
        base="$(basename "$f" .apk)"
        skip=0
        for p in ${SKIP_PKGS:-}; do
            case "$base" in *"$p"*) skip=1; break ;; esac
        done
        [ "$skip" = 1 ] && { echo "  SKIP   $base（SKIP_PKGS）"; continue; }
        install_one "$f" || FAILED=1
    done
    [ "$FAILED" = 0 ] || echo "  [WARN] 有包没装上，见上方输出，后续步骤照常执行"
fi

# =============================================================================
step "2/7 部署 hvrglass Magisk 模块（EDID 按需注入 + hidraw 权限）"
"$ADB" -s "$SERIAL" shell mkdir -p /data/local/tmp/hvrfix >/dev/null 2>&1
"$ADB" -s "$SERIAL" push "$HERE/magisk-module" /data/local/tmp/hvrfix/ >/dev/null 2>&1 \
    || "$ADB" -s "$SERIAL" push "$HERE/magisk-module/." /data/local/tmp/hvrfix/magisk-module/ >/dev/null 2>&1

root_ "mkdir -p /data/adb/hvrglass
cp -rf /data/local/tmp/hvrfix/magisk-module/modules/. /data/adb/modules/hvrglass/
cp -f  /data/local/tmp/hvrfix/magisk-module/runtime/edid-mode.sh    /data/adb/hvrglass/
cp -f  /data/local/tmp/hvrfix/magisk-module/runtime/edid_1080p.bin  /data/adb/hvrglass/
cp -f  /data/local/tmp/hvrfix/magisk-module/runtime/resolution_white.backup.xml /data/adb/hvrglass/
# --- 一键点亮脚本（手册第六章成功流程，刷机/眼镜失活后单独跑 fix/light-on.sh 即可）---
cp -f  /data/local/tmp/hvrfix/magisk-module/runtime/light-on.sh     /data/adb/hvrglass/
# --- 眼镜点亮关键：3200x1600 白名单（模块 post-fs-data.sh 开机 bind mount 到
#     /system/usr/share/resolution_white.xml，HWC 的 mode_verify 只放行白名单内
#     的模式；原厂白名单没有 3200x1600，眼镜（无 scaler）必黑屏。条目值必须是
#     内核解析真值（tools/modeinfo.c 读出的），手算必错 —— 见恢复手册 6.1 ---
cp -f  /data/local/tmp/hvrfix/magisk-module/modules/resolution_white.xml /data/adb/hvrglass/resolution_white.xml
[ -f /data/adb/hvrglass/mode ] || echo auto > /data/adb/hvrglass/mode
chmod 755 /data/adb/modules/hvrglass /data/adb/modules/hvrglass/post-fs-data.sh /data/adb/modules/hvrglass/service.sh /data/adb/hvrglass/edid-mode.sh /data/adb/hvrglass/light-on.sh
# 眼镜激活兜底工具（HIDIOCSFEATURE(5)，见 README 11.15 / 分析文档第十五章）
chmod 755 /data/adb/modules/hvrglass/hwvr-activate 2>/dev/null
# --- 控制接口协议探测二进制（service.sh 用它真发 HIDIOCGFEATURE(4) 挑接口；
#     2026-11-08 修判据后必须有，否则会退化为按描述符长度兜底）---
chmod 755 /data/adb/modules/hvrglass/hwvr-probe
chmod 644 /data/adb/modules/hvrglass/module.prop /data/adb/modules/hvrglass/common/edid_only.bin /data/adb/hvrglass/edid_1080p.bin /data/adb/hvrglass/resolution_white.xml /data/adb/hvrglass/mode" >/dev/null 2>&1

# --- 可选 system overlay（public.libraries.txt 替换 + libc_secshared.so）---
# 仅当第三个参数 --with-overlay 才部署。2026-11-04 两次卡 logo 时它都在场，
# 默认不装（vrservice 私有 lib 自带所需 so，多数情况不再需要它）。
if [ "$WITH_OVERLAY" = "1" ]; then
    root_ "mkdir -p /data/adb/modules/hvrglass/system/etc /data/adb/modules/hvrglass/system/lib64
cp -f /data/local/tmp/hvrfix/magisk-module/overlay-optional/etc/public.libraries.txt /data/adb/modules/hvrglass/system/etc/
cp -f /data/local/tmp/hvrfix/magisk-module/overlay-optional/lib64/libc_secshared.so /data/adb/modules/hvrglass/system/lib64/
chmod 644 /data/adb/modules/hvrglass/system/etc/public.libraries.txt /data/adb/modules/hvrglass/system/lib64/libc_secshared.so" >/dev/null 2>&1
    echo "  [i] system overlay 已部署（--with-overlay）"
else
    echo "  [i] system overlay 未部署（默认；卡 logo 排查期间保持关闭）"
fi

# --- 开机即亮稳定态（已证伪，默认不部署；显式 stable 才上车）---
if [ "$STABLE_BOOT" = "1" ]; then
    deploy_stable_boot
else
    echo "  [stable] --no-stable-boot：保持旧行为（不部署单模式 EDID / systemless 白名单 / force-vr）"
fi

# --- ttyUSB 权限守护开关（service.sh 里默认关闭，显式指定才动）---
if [ "$TTYUSB_GUARD" = "1" ]; then
    root_ "mkdir -p /data/adb/hvrglass; touch /data/adb/hvrglass/ttyusb_compat" >/dev/null 2>&1
    echo "  [i] ttyUSB 守护 = on（运行时立即生效可跑: sh fix/ttyusb-compat.sh $SERIAL on）"
elif [ "$TTYUSB_GUARD" = "0" ]; then
    root_ "rm -f /data/adb/hvrglass/ttyusb_compat" >/dev/null 2>&1
    echo "  [i] ttyUSB 守护 = off"
fi
root_ "rm -rf /data/local/tmp/hvrfix/magisk-module" >/dev/null 2>&1

# --- 无线 ADB 开机自启（刷机后必丢；也是点亮后 adbd 重拉能监听 5555 的前提）---
ensure_wadb

echo "  模块: $(root_ 'ls /data/adb/modules/hvrglass/module.prop && echo OK')"
echo "  显示当前内核输出时序："
root_ "sh /data/adb/hvrglass/edid-mode.sh show" | sed 's/^/    /'
echo "  [i] 眼镜不亮 → 一键点亮: sh fix/light-on.sh  /  双击 fix/一键点亮.bat"
echo "      设备端等价: su -c 'sh /data/adb/hvrglass/light-on.sh'"
echo "  [i] 便携屏黑屏时执行: su -c 'sh /data/adb/hvrglass/edid-mode.sh 1080p'"
echo "  [i] 别用 force-vr 固化、别在开机阶段注入 EDID（手册 4.1：会卡 logo）"

# =============================================================================
step "3/7 绕过 launcherx 隐私页（Android 11 禁写 Settings.System 自定义键）"
root_ "settings put system PRIVACY_ACCEPTED 1" >/dev/null 2>&1
echo "  PRIVACY_ACCEPTED = $(sh_ 'settings get system PRIVACY_ACCEPTED')"

# 跳过手柄设置弹窗（OOBE），进桌面直达主页。OOBE 场景由 Unity PlayerPrefs
# needShowOOBE / needShowPhoneOOBE / needShowNoloOOBE 控制（默认 1=显示），
# WalleXSceneManager.NeedShowOobe() 读它们决定是否进 OOBESimpleScene。
# 注意：必须先 force-stop 再改文件，Unity 退出时会用内存值覆盖 XML。
root_ "am force-stop com.huawei.vrlauncherx; sleep 1
F=/data/data/com.huawei.vrlauncherx/shared_prefs/com.huawei.vrlauncherx.v2.playerprefs.xml
if [ -f \$F ] && ! grep -q needShowOOBE \$F; then
  sed -i 's|</map>|    <int name=\"needShowOOBE\" value=\"0\" />\\n    <int name=\"needShowPhoneOOBE\" value=\"0\" />\\n    <int name=\"needShowNoloOOBE\" value=\"0\" />\\n</map>|' \$F
  echo \"  needShowOOBE=0 已写入（OOBE 弹窗跳过）\"
else
  echo \"  OOBE 开关已存在或 prefs 缺失，跳过\"
fi" 2>&1 | grep -v "^$" | tail -2

# =============================================================================
step "4/7 补授权（appops / pm grant / deviceidle / 日志级别）"
sh "$HERE/tools/grant-vr-perms.sh" "$SERIAL" 2>/dev/null || \
    echo "  [WARN] grant-vr-perms.sh 执行异常，可手动重跑"

# --- 模拟辅助显示设备：VR 会话要 externalDisplay=true，但窗口不能挡左眼 ---
# VrPlatformCompat.externalDisplay() 要求存在一块「非 DEFAULT_DISPLAY 且
# STATE_ON」的屏。盒子只有一块 HDMI（被安卓当内置屏 display 0），所以靠
# 开发者选项「模拟辅助显示设备」造一块辅助屏来满足在位判定。
# 这块辅助屏会以系统窗口叠在主屏合成上，且窗口内容是主屏的缩小镜像，
# 形成递归叠影；左眼正好落在主屏左半，就会看到错乱画面（2026-11-07
# 用户实测「左眼不对、右眼对」）。反复改这个 setting 还会残留多个旧窗口。
# 100x100/320 是实测能被创建的最小尺寸：判定仍为 true，窗口缩到几乎不可见，
# 左右眼双目画面完整对称。
# 回退：settings delete global overlay_display_devices（VR 会话会退出）。
root_ "settings put global overlay_display_devices 100x100/320" >/dev/null 2>&1
echo "  overlay_display_devices = $(sh_ 'settings get global overlay_display_devices')"

# --- 恢复模块启用 + 平台伪装 + VR 服务链（都是历史实证的既有配置，非新增开机逻辑）---
# ① rescue_boot.sh --disable-hvrglass 救砖后会留下 disable 标记。若不删，
#    模块整套不跑：无 HUAWEI 伪装、无白名单 bind mount、无 hidraw 权限守护、
#    也无 VR 服务开机自启 —— 表现就是「VR 服务全空 / 投屏弹不支持 / 眼镜不亮」。
# ② post-fs-data.sh 的 resetprop 只在开机执行，本次安装不重启，故运行时补一次；
#    模块启用后下次开机会自动再设。
root_ "rm -f /data/adb/modules/hvrglass/disable" >/dev/null 2>&1
echo "  hvrglass 模块 = $(sh_ 'test -f /data/adb/modules/hvrglass/disable && echo DISABLED || echo enabled')"
root_ "resetprop ro.product.manufacturer HUAWEI; resetprop ro.vr.surport true" >/dev/null 2>&1
echo "  ro.vr.surport = $(sh_ 'getprop ro.vr.surport')"
root_ "am start-service -n com.huawei.vrservice/com.huawei.vrservice.VRService; am start-service -n com.huawei.hvrsdkserverapp/com.huawei.hvrsdkserverapp.service.ArvrRuntimeService; am start-foreground-service -n com.huawei.vrhandle/.service.VRHandleService -a com.huawei.vrservice.ACTION_RECONNECT_MSG" >/dev/null 2>&1
echo "  VR 服务进程："
sh_ "ps -A | grep -E 'vrservice|ArvrRuntimeService' | grep -v grep" | sed 's/^/    /' || \
    echo "    （未起，检查 deviceidle 白名单是否含 vrservice / hvrsdkserverapp）"

# =============================================================================
step "5/7 一键点亮 VR 眼镜（严格按手册第六章成功流程）"
# light-on.sh 内部先自检：眼镜 EDID 必须醒着（模式表含 3200x1600），
# 否则直接拒绝、不写属性也不重启 SF —— 眼镜失活时盒子单方面强扭没用。
# 注意：绝不用 setprop ctl.restart surfaceflinger（手册 4.2 实测整机重启/卡死）。
if [ "$LIGHT_ON" = "1" ]; then
    # 只有「当前没点亮」时设备端才会真的 stop/start SF，并安排 25 秒后
    # init 级重拉 adbd。等过这段窗口再验收，否则 6/7 进程列表会是空的，
    # 且 adbd 重拉会打断紧接着的命令。已点亮时走快速路径，不多等。
    PRE_LIT=$(root_ 'head -7 /sys/kernel/debug/dri/0/summary | grep -c 3200x1600p70' | tr -d '\r\n ')
    case "$PRE_LIT" in ''|*[!0-9]*) PRE_LIT=0 ;; esac
    echo "  [i] 点亮前物理输出命中 3200x1600p70 的行数 = $PRE_LIT"
    root_ "sh /data/adb/hvrglass/light-on.sh" | sed 's/^/  /'
    if [ "$PRE_LIT" = "0" ]; then
        echo "  [i] 本次触发 SF 重启，等待设备端 25 秒 adbd 自恢复窗口（约 30 秒）..."
        sleep 30
    fi
    if wait_adb 60; then
        echo "  [i] 无线 ADB 已恢复，继续验收（无需拔电源、无需守护）"
        # stop/start surfaceflinger 会把 4/7 刚拉起的 VR 服务一并冲掉
        # （2026-11-07 实测：装完只剩 7/7 启动的应用市场，6/7 进程为空）。
        # 点亮完成后补拉一次，保证安装结束时 VR 栈是活的。
        echo "  [i] 点亮后补拉 VR 服务（SF 重启会冲掉 4/7 拉起的进程）..."
        root_ "am start-service -n com.huawei.vrservice/com.huawei.vrservice.VRService; am start-service -n com.huawei.hvrsdkserverapp/com.huawei.hvrsdkserverapp.service.ArvrRuntimeService; am start-foreground-service -n com.huawei.vrhandle/.service.VRHandleService -a com.huawei.vrservice.ACTION_RECONNECT_MSG" >/dev/null 2>&1
        sleep 3
    else
        echo "  [WARN] 90 秒内无线 ADB 未恢复，下面验收可能为空。"
        echo "         设备端日志仍在 /data/local/tmp/hvr-light-on.log；"
        echo "         稍后执行 sh fix/light-on.sh $SERIAL 可复查显示时序。"
    fi
else
    echo "  （--no-light-on，跳过。随时可跑: sh fix/light-on.sh 或双击 fix/一键点亮.bat）"
fi

# =============================================================================
step "6/7 状态验收"
echo "-- 已安装的华为 VR 包 --"
sh_ "pm list packages" | grep -E 'com\.huawei\.(appmarket\.vr|vrlauncherx|himovie\.vr|vrvirtualscreen|vrhandle|hvrsdkserverapp|vrservice)' | sed 's/^/  /'
echo "-- 关键进程 --"
PROCS=$(sh_ "ps -A | grep -E 'vrservice|vrvirtualscreen|vrhandle|himovie|hvrsdkserverapp|vrlauncherx|appmarket' | grep -v grep")
if [ -n "$PROCS" ]; then
    echo "$PROCS" | sed 's/^/  /'
else
    echo "  （暂无 VR 服务进程：若 5/7 刚重启过 surfaceflinger，framework 重启后需数十秒由模块拉回；"
    echo "    7/7 应用市场能启动即表示安装成功，可稍后 adb shell ps -A | grep vr 复查）"
fi
echo "-- vr_system 服务（目前仍缺，属已知问题，非安装失败）--"
if sh_ "service list" | grep -q vr_system; then
    echo "  vr_system 已注册！（意外之喜，说明系统侧桩已生效）"
else
    echo "  vr_system 未注册 —— 需 LSPosed 在 system_server 注册桩，或走 ALVR 路线（见 README）"
fi

# =============================================================================
step "7/7 启动验证"
if [ "$MODE" = "--no-launch" ]; then
    echo "  （--no-launch，跳过）"
else
    "$ADB" -s "$SERIAL" shell am start -W -n \
        com.huawei.appmarket.vr/com.huawei.hwmarket.vr.MainActivity 2>/dev/null | tr -d '\r' | grep -E 'Status|TotalTime|Error' | sed 's/^/  /'
fi

echo
echo "===== 完成 ====="
echo "  ⚠️ 每次开机/断电后：  sh fix/light-on.sh $SERIAL   # 一条即可，ADB 自动恢复；守护可选"
echo "  眼镜没亮 / 之后又黑：sh fix/light-on.sh 或双击 fix/一键点亮.bat"
echo "  眼镜物理链路检查：    sh fix/light-on.sh $SERIAL check  # status/EDID/modes 为空就是没插好或没激活"
echo "  只体检不改动：      sh fix/light-on.sh $SERIAL check"
echo "  接便携屏前：        sh fix/light-on.sh $SERIAL off"
echo "  开机即亮稳定态：    sh install.sh $SERIAL --stable-check | stable | --stable-off"
echo "  vcom 运行时恢复：   sh fix/ttyusb-compat.sh $SERIAL on"
echo "  DDC 直通验证：      sh fix/ddc-passthrough.sh $SERIAL verify"
echo "  HWC 选模取证：      sh fix/restart-hwc.sh $SERIAL check"
echo "  细节与排障见 README.md / 刷机后问题分析与恢复手册.md 6.6、6.12、6.13"
