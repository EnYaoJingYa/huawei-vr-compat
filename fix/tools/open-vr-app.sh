#!/bin/sh
# open-vr-app.sh —— 不依赖手柄射线输入，从 adb 直接打开 VR 应用
#
# 用法：
#   sh fix/tools/open-vr-app.sh [serial] list                 # 列出可启动的 VR 应用
#   sh fix/tools/open-vr-app.sh [serial] alvr                 # 打开 ALVR
#   sh fix/tools/open-vr-app.sh [serial] com.xxx/.Activity    # 直接指定组件
#
# 背景（2026-11-08 真机实测，见 fix/2026-11-08-眼镜黑屏排查分析.md 第十一章）：
#   VR 桌面点图标靠 3DoF CF20 手柄的射线输入（6DoF 视觉定位链与 CF20 是
#   完全独立的两套，见 docs/6DoF-为什么没起来.md 第五章）。射线指针异常时
#   点图标不会触发 launchApp，看起来像「所有应用都打不开」。实测 am start
#   下 ALVR / 应用市场 / 华为视频 / 投屏全部 Status: ok 并驻留，
#   所以应用本身是好的，这是桌面输入链路问题。
#   本脚本用 cmd package resolve-activity 拿真实入口（各包的入口 Activity
#   并不叫 MainActivity，写死会报 "Activity class does not exist"）。
set -u

SERIAL="${1:-192.168.43.133:5555}"
APP="${2:-list}"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1 || {
    echo "[FATAL] 连不上 $SERIAL"; exit 1; }

resolve() {
    # 注意 </dev/null：adb shell 会继承 stdin，在 while 管道里会吃掉剩余包名
    r=$("$ADB" -s "$SERIAL" shell "cmd package resolve-activity --brief $1" </dev/null 2>/dev/null \
        | tr -d '\r' | tail -1)
    case "$r" in
        */*) echo "$r" ;;
        *)   echo "" ;;
    esac
}

case "$APP" in
    list|--list)
        echo "=== 设备上可启动的 VR 应用（$SERIAL）==="
        PKGS=$("$ADB" -s "$SERIAL" shell 'pm list packages -3' </dev/null 2>/dev/null \
            | tr -d '\r' | sed 's/^package://' | grep -Ei 'vr|alvr')
        for p in $PKGS; do
            c=$(resolve "$p")
            [ -n "$c" ] && printf '  %-40s %s\n' "$p" "$c" \
                || printf '  %-40s (无启动入口)\n' "$p"
        done
        echo
        echo "别名：desktop / alvr / market / cast / himovie / youku"
        exit 0 ;;
    alvr|ALVR)            PKG=com.lht.huaweivr.alvr ;;
    desktop|home|vr桌面)   PKG=com.huawei.vrlauncherx ;;
    market|应用市场)       PKG=com.huawei.appmarket.vr ;;
    cast|投屏|mirror)      PKG=com.huawei.vrvirtualscreen ;;
    himovie|华为视频)      PKG=com.huawei.himovie.vr ;;
    youku|优酷)            PKG=com.youku.vr ;;
    */*)                  COMP="$APP"; PKG="" ;;
    *)                    PKG="$APP" ;;
esac

if [ -z "${COMP:-}" ]; then
    COMP=$(resolve "$PKG")
    # 桌面用 resolve 可能落到 VRPrepareActivity，直接指定主页更可靠
    [ "$PKG" = "com.huawei.vrlauncherx" ] && COMP="com.huawei.vrlauncherx/.MainActivity"
fi

if [ -z "$COMP" ]; then
    echo "[FAIL] $PKG 没有可启动的入口 Activity（用 list 查看）"
    exit 1
fi

echo "启动：$COMP"
"$ADB" -s "$SERIAL" shell "am start -W -n $COMP" 2>&1 | tail -8

sleep 3
echo
echo -n "当前栈顶："
"$ADB" -s "$SERIAL" shell 'dumpsys activity activities | grep -m1 mResumedActivity' 2>/dev/null | tr -d '\r'
echo
echo "注意：VR 桌面在 onPause 时可能触发 HVR 原厂的 ForceProcessExit（单应用独占，"
echo "      见 fix/README.md 11.6）；守护会在 15s 巡检内补发 vr_system_state 并重拉桌面。"
