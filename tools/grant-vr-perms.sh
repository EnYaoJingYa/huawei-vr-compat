#!/bin/sh
# grant-vr-perms.sh —— 七个华为 VR 包装完后，补齐 root 才能给的授权
#
# 口径来自 install-six.ps1（原版跑在 system UID 下，那部分权限是隐式持有的，
# 换成普通应用后必须显式授予），这里用 adb + su 复刻一遍，便于在非 Windows /
# 无 PowerShell 的场合复用。
#
# 用法：
#     sh tools/grant-vr-perms.sh 192.168.43.133:5555
#     sh tools/grant-vr-perms.sh            # 默认 192.168.43.133:5555
#
# 说明：
#   * 这台盒子是 Magisk 26.3，su -c 可用；授权动作走 root，避免 shell 身份
#     在部分 appops 上被 MANAGE_APP_OPS_MODES 挡住。
#   * 全部操作幂等，可反复执行。

set -u

ADB="${ADB:-/d/Tools/AndroidSDK/platform-tools/adb.exe}"
SERIAL="${1:-192.168.43.133:5555}"

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device

sh_() { "$ADB" -s "$SERIAL" shell "$@"; }
root_() { "$ADB" -s "$SERIAL" shell "su -c '$*'"; }

PKGS="com.huawei.appmarket.vr com.huawei.vrlauncherx com.huawei.himovie.vr \
com.huawei.vrvirtualscreen com.huawei.vrhandle com.huawei.hvrsdkserverapp \
com.huawei.vrservice"

echo "== 已安装检查 =="
installed=$(sh_ "pm list packages | grep -E 'com\.huawei\.(appmarket\.vr|vrlauncherx|himovie\.vr|vrvirtualscreen|vrhandle|hvrsdkserverapp|vrservice)'" | sed 's/package://' | tr -d '\r')
for p in $PKGS; do
    if echo "$installed" | grep -qx "$p"; then
        echo "  OK   $p"
    else
        echo "  MISS $p"
    fi
done

echo "== 复位显示方向冻结 =="
sh_ "wm set-ignore-orientation-request false" >/dev/null 2>&1
echo "  wm set-ignore-orientation-request false"

echo "== appops =="
set_op() {
    root_ "appops set $1 $2 allow" >/dev/null 2>&1
    state=$(sh_ "appops get $1 $2" | tr -d '\r' | grep -o 'allow\|deny\|ignore\|default' | head -1)
    printf "  %-30s %-22s %s\n" "$1" "$2" "${state:-?}"
}
for p in com.huawei.vrlauncherx com.huawei.himovie.vr com.huawei.vrvirtualscreen \
         com.huawei.hvrsdkserverapp com.huawei.vrservice; do
    set_op "$p" WRITE_SETTINGS
done
for p in com.huawei.vrlauncherx com.huawei.vrhandle com.huawei.vrvirtualscreen \
         com.huawei.vrservice com.huawei.hvrsdkserverapp; do
    set_op "$p" SYSTEM_ALERT_WINDOW
done
set_op com.huawei.vrlauncherx GET_USAGE_STATS

echo "== pm grant =="
grant() {
    root_ "pm grant $1 $2" >/dev/null 2>&1 && echo "  granted  $1  $2" || echo "  failed   $1  $2"
}
grant com.huawei.vrlauncherx android.permission.WRITE_SECURE_SETTINGS
grant com.huawei.vrlauncherx android.permission.READ_PHONE_STATE
grant com.huawei.vrlauncherx android.permission.ACCESS_FINE_LOCATION
grant com.huawei.vrlauncherx android.permission.ACCESS_COARSE_LOCATION
grant com.huawei.appmarket.vr android.permission.READ_PHONE_STATE
grant com.huawei.vrservice android.permission.WRITE_SECURE_SETTINGS

echo "== deviceidle whitelist =="
for p in com.huawei.hvrsdkserverapp com.huawei.vrservice com.huawei.vrlauncherx com.huawei.vrhandle; do
    root_ "cmd deviceidle whitelist +$p" >/dev/null 2>&1 && echo "  +$p"
done

echo "== 日志级别 =="
for tag in HvrFramework VrHelmetExt; do
    root_ "setprop log.tag.$tag ASSERT" >/dev/null 2>&1
    echo "  log.tag.$tag = $(sh_ "getprop log.tag.$tag" | tr -d '\r')"
done

echo "== 完成 =="
