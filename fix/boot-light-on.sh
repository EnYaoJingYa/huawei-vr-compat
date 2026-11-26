#!/bin/sh
# =============================================================================
# 开机点亮开关 —— 恢复"重启就能亮灯"的历史行为（可逆、默认不启用）
#
# 用法：
#   sh fix/boot-light-on.sh [serial] [check|on|off|reboot]
#       check  (默认) 只读体检，不改任何东西
#       on            换真实 22f6 EDID 母本 + mode=force-vr（不重启）
#       off           还原原母本 + mode=auto（不重启）
#       reboot        显式执行一次 reboot（on/off 之后手动调用）
#
# ⚠️ 2026-11-06 修正（手册 6.12）：下面「EDID 尚未就绪」这一句已被证伪。
#   force-off 纯直通重启实测：override=0、内核自己读到 256B `22f6` 真实 EDID、
#   模式表含 3200x1600×2、白名单齐、resolution 属性已是 3200x1600@70，
#   HWC 开机仍选 1920x1080p60（PID 218 未重新初始化）。所以「开机早期写
#   override 赢过 probe」不是开机即亮的解法，EDID 注入也并非必需；
#   真正卡在 HWC 选模逻辑本身。本工具保留作历史对照，不再推荐作为点亮手段。
#
# 为什么需要它（2026-11-05 当时的推断，部分已过时）：
#   HWC 只在自身进程初始化时（开机约 6.5s）调用一次 UpdateDisplayMode，
#   当时推断「那一刻眼镜 EDID 尚未就绪 → 模式表里没有 3200 → 永远选 1080p」。
#   运行时 setprop / sys.resolution.changed / echo detect 全部证伪，
#   stop/start surfaceflinger 虽能瞬时切 3200 却会带崩 system_server。
#   老项目 PLAYBOX-排障操作手册 §2.2 的"开机早期写 edid_override + reboot"
#   正是让内核在 HWC probe 之前就拿到含 3200 的模式表 —— 这就是
#   "之前重启能亮灯"的机理。现在的 mode=auto 读到真实 EDID 就跳过注入，
#   等于把这一环拆了。
#
# 与老做法的关键差别：注入的是**眼镜自己的真实 EDID**
#   (.tmp-edid/edid_live.bin, 22f6, 2 条 DTD, md5 eba6de4e147d7973…)，
#   不是老项目那个 22d2 单 DTD 合成 EDID（edid_native70.bin，五档全黑）。
#
# 安全约束：
#   - 不改任何开机脚本，只换数据文件 + mode 文件，随时可 off 还原。
#   - on 前强制校验眼镜在位（connected + 22f6 + 模式表有 3200）。
#   - force-vr 是无条件注入：接便携屏时黑屏风险，用完接回普通屏前必须 off。
#   - 不自动重启，reboot 是独立显式动作。
#   - 已有整机备份 backup/box-2026-11-05/，最坏情况可回退。
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="$ROOT/.tmp-edid/edid_live.bin"
SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-check}"

ADB="${ADB:-}"
if [ -z "$ADB" ]; then
    for p in /d/Tools/AndroidSDK/platform-tools/adb.exe \
             /c/platform-tools/adb.exe \
             "$ROOT/tools/adb.exe"; do
        [ -x "$p" ] && ADB="$p" && break
    done
fi
[ -n "$ADB" ] || { echo "[FATAL] 找不到 adb.exe，请设置 ADB=..."; exit 1; }

MOD=/data/adb/modules/hvrglass
DAT=/data/adb/hvrglass
BIN=$MOD/common/edid_only.bin
ORIG=$MOD/common/edid_only.bin.orig
BIN2=$DAT/edid_only.bin
MODE_FILE=$DAT/mode
OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
CONN=/sys/class/drm/card0-HDMI-A-1

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" shell 'echo alive' >/dev/null 2>&1 || {
    echo "[FATAL] 设备不在线：$SERIAL"; exit 1; }

sh_su() { "$ADB" -s "$SERIAL" shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }

show() {
    echo "----- 开机点亮体检 -----"
    sh_su "echo HDMI=\$(cat $CONN/status 2>/dev/null); \
echo VENDOR=\$(dd if=$CONN/edid bs=1 skip=8 count=2 2>/dev/null | od -An -tx1); \
echo EDID_MD5=\$(md5sum $CONN/edid 2>/dev/null | cut -d\" \" -f1); \
echo MODES3200=\$(grep -c \"^3200x1600\" $CONN/modes 2>/dev/null); \
echo PHYSICAL=\$(head -7 /sys/kernel/debug/dri/0/summary 2>/dev/null | grep -m1 \"Display mode:\"); \
echo OVERRIDE_BYTES=\$(wc -c < $OVR 2>/dev/null); \
echo MODE=\$(cat $MODE_FILE 2>/dev/null || echo auto); \
echo BIN_COMMON=\$(md5sum $BIN 2>/dev/null | cut -d\" \" -f1); \
echo BIN_DATA=\$(md5sum $BIN2 2>/dev/null | cut -d\" \" -f1); \
echo ORIG_EXISTS=\$(test -f $ORIG && echo yes || echo no)"
    echo "  开机脚本 force-vr 分支：$(grep -c 'force-vr)' "$HERE/magisk-module/modules/post-fs-data.sh" 2>/dev/null) 处"
    echo "  真实母本 md5：$(md5sum "$SRC" 2>/dev/null | cut -c1-32) ($(wc -c < "$SRC" 2>/dev/null) 字节)"
}

case "$ACTION" in
check) show; exit 0 ;;

reboot)
    echo "[i] 执行 reboot（眼镜请保持 HDMI + USB 都插着）"
    "$ADB" -s "$SERIAL" shell "su -c 'reboot'" >/dev/null 2>&1
    echo "[i] 已发出重启命令，无线 adb 会短暂断开，约 90 秒后自动恢复"
    exit 0 ;;

off)
    echo "[i] 关闭开机注入：还原母本 + mode=auto"
    sh_su "if [ -f $ORIG ]; then cp -f $ORIG $BIN; else echo 1 > /dev/null; fi; \
chmod 644 $BIN; echo auto > $MODE_FILE; \
echo MODE=\$(cat $MODE_FILE); echo BIN=\$(md5sum $BIN | cut -d\" \" -f1)"
    echo "[i] 已完成。要生效需重启：sh $HERE/boot-light-on.sh $SERIAL reboot"
    exit 0 ;;

on) ;;

*) echo "[FATAL] 未知动作：$ACTION（check|on|off|reboot）"; exit 1 ;;
esac

# ---------------------------------------------------------------- on
[ -f "$SRC" ] || { echo "[FATAL] 缺真实 EDID 母本：$SRC"; exit 1; }
SZ=$(wc -c < "$SRC" | tr -d ' \r\n')
[ "$SZ" = "256" ] || { echo "[FATAL] 母本不是 256 字节（$SZ）"; exit 1; }

echo "[1/4] 前置校验：眼镜必须在位且是醒着的 22f6"
st=$(sh_su "cat $CONN/status 2>/dev/null")
vend=$(sh_su "dd if=$CONN/edid bs=1 skip=8 count=2 2>/dev/null | od -An -tx1" | tr -d ' \r\n')
m3200=$(sh_su "grep -c \"^3200x1600\" $CONN/modes 2>/dev/null" | tr -d ' \r\n')
echo "      status=$st  vendor=$vend  3200模式=$m3200"
[ "$st" = "connected" ] || { echo "[FATAL] 眼镜未连接，拒绝开启（接便携屏会黑屏）"; exit 1; }
[ "$vend" = "22f6" ] || { echo "[FATAL] EDID 厂商不是 22f6（眼镜可能失活），拒绝开启。按手册 4.3 先用 PC 点亮一次"; exit 1; }
[ "${m3200:-0}" -ge 1 ] || { echo "[FATAL] 模式表里没有 3200x1600，拒绝开启"; exit 1; }

echo "[2/4] 推送真实 EDID 并备份原母本"
# Git Bash/MSYS 坑（2026-11-06 实修）：
#   - 远端参数 /data/local/tmp/... 会被 MSYS 转成 Windows 本地路径，
#     报 remote secure_mkdirs failed: No such file or directory；
#   - 而 $SRC 是 /f/PY/... 形式的 MSYS 绝对路径，Windows adb.exe 不认，
#     在 MSYS_NO_PATHCONV=1 下报 cannot stat。
# 因此在仓库根目录用相对路径，并显式禁用本次调用的参数转换。
( cd "$ROOT" && MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$SERIAL" push \
    ".tmp-edid/edid_live.bin" /data/local/tmp/edid_real.bin ) || {
    echo "[FATAL] push 失败"; exit 1; }
sh_su "mkdir -p $MOD/common $DAT; \
if [ ! -f $ORIG ]; then cp -f $BIN $ORIG 2>/dev/null; fi; \
cp -f /data/local/tmp/edid_real.bin $BIN; chmod 644 $BIN; \
cp -f /data/local/tmp/edid_real.bin $BIN2; chmod 644 $BIN2"

echo "[3/4] 写 mode=force-vr 并双路径核对 md5"
sh_su "echo force-vr > $MODE_FILE; \
echo MODE=\$(cat $MODE_FILE); \
echo COMMON=\$(md5sum $BIN | cut -d\" \" -f1); \
echo DATA=\$(md5sum $BIN2 | cut -d\" \" -f1); \
echo EXPECT=\$(md5sum /data/local/tmp/edid_real.bin | cut -d\" \" -f1)"

echo "[4/4] 完成（尚未重启）"
echo "  下次开机会在 HWC probe 之前注入真实 22f6 EDID，模式表含 3200 → HWC 应直接选 3200x1600p70。"
echo "  要生效请执行： sh $HERE/boot-light-on.sh $SERIAL reboot"
echo "  ⚠️ 接回普通显示器前必须： sh $HERE/boot-light-on.sh $SERIAL off && ... reboot"
