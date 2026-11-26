#!/bin/sh
# =============================================================================
# 一键点亮华为 VR Glass（本地入口 / Git Bash、Linux、macOS 通用）
#
#   sh fix/light-on.sh                        # 默认 192.168.43.133:5555
#   sh fix/light-on.sh 192.168.43.133:5555   # 指定设备
#   sh fix/light-on.sh <serial> check        # 只体检
#   sh fix/light-on.sh <serial> off          # 清除强制分辨率属性（接便携屏前）
#
# 自包含：设备端没有 light-on.sh 时会自动 push 一份再执行，
# 所以刷机后不用先跑完整安装工具也能单独点亮。
# 逻辑全部在设备端 fix/magisk-module/runtime/light-on.sh，本脚本只负责转发。
# =============================================================================
set -u

SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-on}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
    *MINGW*|*MSYS*|*CYGWIN*)
        command -v cygpath >/dev/null 2>&1 && HERE="$(cygpath -m "$HERE")" ;;
esac
SRC="$HERE/magisk-module/runtime/light-on.sh"
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

find_adb() {
    if [ -n "${ADB:-}" ] && [ -x "$ADB" ]; then printf '%s' "$ADB"; return 0; fi
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    for c in "/d/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/f/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/c/platform-tools/adb.exe" \
             "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
ADB="$(find_adb)" || { echo "[FATAL] 找不到 adb，请设置 ADB 环境变量"; exit 1; }

[ -f "$SRC" ] || { echo "[FATAL] 缺少 $SRC"; exit 1; }

echo "[i] adb    = $ADB"
echo "[i] 设备   = $SERIAL"
echo "[i] 动作   = $ACTION"
"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1 || {
    echo "[FATAL] 设备连不上（检查盒子是否开机、无线 adb 是否开启）"; exit 1; }

# 每次都同步一次（脚本只有几 KB），保证用的是本地最新母本
echo "[i] 同步点亮脚本到设备 ..."
"$ADB" -s "$SERIAL" push "$SRC" /data/local/tmp/light-on.sh >/dev/null 2>&1 || {
    echo "[FATAL] push 失败"; exit 1; }
"$ADB" -s "$SERIAL" shell "su -c 'mkdir -p /data/adb/hvrglass; cp /data/local/tmp/light-on.sh /data/adb/hvrglass/light-on.sh; chmod 755 /data/adb/hvrglass/light-on.sh'" >/dev/null 2>&1

echo
TMPOUT="${TMPDIR:-/tmp}/hvr-light-on.out"
DEVLOG=/data/local/tmp/hvr-light-on.log

# 设备端日志是追加的。先记下执行前行数，后面只判定「本次新增」的终态，
# 否则上一轮的「点亮成功」会被误当成这一轮的结果。
N0=$("$ADB" -s "$SERIAL" shell "su -c 'wc -l < $DEVLOG 2>/dev/null'" 2>/dev/null | tr -d '\r\n ')
case "$N0" in ''|*[!0-9]*) N0=0 ;; esac

"$ADB" -s "$SERIAL" shell "su -c 'sh /data/adb/hvrglass/light-on.sh $ACTION'" > "$TMPOUT" 2>&1
tr -d '\r' < "$TMPOUT"

case "$ACTION" in
    on|"")
        # stop surfaceflinger 会冲掉 5555 监听，设备端脚本在 25 秒后由自己的
        # 子 shell 做 init 级 stop/start adbd 恢复。这里等它收尾再回读验收，
        # 避免「点亮其实成功、PC 侧却只看到连接断开」的历史误判。
        echo
        echo "[i] 等待设备端收尾 / 无线 ADB 自恢复（最多 90 秒）..."
        NEW=""; i=0
        while [ "$i" -lt 90 ]; do
            "$ADB" connect "$SERIAL" >/dev/null 2>&1
            if "$ADB" -s "$SERIAL" shell "true" >/dev/null 2>&1; then
                NEW=$("$ADB" -s "$SERIAL" shell "su -c 'tail -n +$((N0 + 1)) $DEVLOG'" 2>/dev/null | tr -d '\r')
                echo "$NEW" | grep -qE '点亮成功|物理输出已是|\[FAIL\]|本次未切到' && break
            fi
            sleep 3
            i=$((i + 3))
        done
        echo
        echo "=== 本次设备端日志 ==="
        echo "$NEW" | grep -v '^$' | tail -12 | sed 's/^/  /'
        echo
        echo "=== 内核物理输出（点亮硬指标）==="
        PHYS=$("$ADB" -s "$SERIAL" shell "su -c 'head -7 /sys/kernel/debug/dri/0/summary'" 2>/dev/null | tr -d '\r' | grep -E 'Display mode:|clk\[' | head -2)
        if [ -n "$PHYS" ]; then echo "$PHYS" | sed 's/^/  /'
        else echo "  （读不到：眼镜 HDMI 可能未连接 / VOP 未使能）"; fi
        if echo "$NEW" | grep -qE '点亮成功|物理输出已是'; then
            echo "  [OK] 点亮链路完成"; RC=0
        else
            echo "  [FAIL] 未确认点亮（看上方日志；眼镜没插好/没激活时属预期拒绝）"; RC=1
        fi
        ;;
    *) RC=0 ;;
esac
echo
echo "[i] 设备端完整日志：$DEVLOG"
exit $RC
