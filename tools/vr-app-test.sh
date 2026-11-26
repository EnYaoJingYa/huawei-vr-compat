#!/usr/bin/env bash
# 逐个拉起华为 VR 各包，记录前台 Activity / 进程 / 崩溃类型。
# 用法：sh tools/vr-app-test.sh [序列号]
set -u

S="${1:-192.168.43.133:5555}"
ADB="adb"
command -v adb >/dev/null 2>&1 || ADB="/d/Tools/AndroidSDK/platform-tools/adb.exe"

run() { MSYS_NO_PATHCONV=1 "$ADB" -s "$S" shell "$@" 2>&1; }

connect() { MSYS_NO_PATHCONV=1 "$ADB" connect "$S" >/dev/null 2>&1; }

test_one() {
    name="$1"; shift
    pkg="$1"; shift
    act="$1"; shift

    connect
    run "logcat -c" >/dev/null 2>&1
    printf '\n===== %-22s %s\n' "$name" "$act"
    run "am start -n $act" | head -2
    sleep 7

    alive=$(run "pidof $pkg" | tr -d '\r')
    front=$(run "dumpsys activity activities | grep mResumedActivity" | tr -d '\r' | head -1)
    err=$(run "logcat -d -s AndroidRuntime:E" | grep -m1 -E "Process: $pkg|InflateException|NoClassDefFoundError|IllegalArgumentException|SecurityException" | tr -d '\r')

    if [ -n "$alive" ]; then
        echo "  进程: 在跑 (pid $alive)"
    else
        echo "  进程: 已退出"
    fi
    echo "  前台: ${front#*mResumedActivity: }"
    [ -n "$err" ] && echo "  异常: $err"
}

test_one "应用市场"   com.huawei.appmarket.vr     com.huawei.appmarket.vr/com.huawei.hwmarket.vr.MainActivity
test_one "VR 桌面"    com.huawei.vrlauncherx      com.huawei.vrlauncherx/.activity.Vr2dStartUpActivity
test_one "VR 桌面(主)" com.huawei.vrlauncherx     com.huawei.vrlauncherx/.MainActivity
test_one "虚拟屏"     com.huawei.vrvirtualscreen  com.huawei.vrvirtualscreen/.main.view.Vr2dStartUpActivity
test_one "VR 视频"    com.huawei.himovie.vr       com.huawei.himovie.vr/com.huawei.vrlab.twodimensional.login.TermsLoginActivity
test_one "手柄"       com.huawei.vrhandle         com.huawei.vrhandle/.activity.SplashActivity

echo
echo "===== 常驻服务"
connect
run "ps -A" | grep -E "com\.huawei" | tr -d '\r'
echo "----- binder"
run "service list" | grep -iE "vr_system|hvr" | tr -d '\r'
echo "（无输出 = vr_system 未注册）"
