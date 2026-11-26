#!/bin/sh
# vr-input-check.sh —— 只读体检「VR 桌面能不能点图标」
#
# 用法：
#   sh fix/tools/vr-input-check.sh [serial]   # 默认 192.168.43.133:5555
#
# 重要：6DoF 与 3DoF 是两条完全独立的链路，别混为一谈
#   （2026-11-08 用户纠正，依据 docs/6DoF-为什么没起来.md 第五章）：
#   · 6DoF 设备 = 12d1:3a09「6DoF Gaming Kit Par-CG012」(Omnivision 双目 UVC)，
#     走 USB → VideoStreaming → /dev/video14/15 → HiVRAR HAL → VIO 位姿。
#     判定在 VrParamsRequester.isHW6DoFAvailable(index)：
#       mRuntimeInterface(ArvrRuntimeInternalInterface) 非 null
#       && getCurrentDevices().size() == 3   （0=头显 1=左手柄 2=右手柄）
#       && list.get(index).getDeviceState() == 1
#     **不是按 VID/PID 或蓝牙识别**，hvrsdkserverapp 里没有任何 BluetoothGatt。
#   · 3DoF 手柄 = HUAWEI CF20，走 BLE，由 com.huawei.vrhandle 按广播名
#     contains("CF20_3DOF") + 私有 GATT 622f5b2a / ffb4a651 识别并入库。
#   所以「Huawei 6Dof ... is false」只说明 6DoF 视觉链没起来，
#   **不能**用来判断 CF20 手柄是否掉线（它常年 false，属既有分支噪声，
#   见 fix/刷机后问题分析与恢复手册.md 8.3）。
#
# 本脚本只读，不改设备状态，也不发任何 USB 请求。
set -u

SERIAL="${1:-192.168.43.133:5555}"
ADB="${ADB:-D:/Tools/AndroidSDK/platform-tools/adb.exe}"

"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1 || {
    echo "[FATAL] 连不上 $SERIAL"; exit 1; }

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
"$ADB" -s "$SERIAL" logcat -d -v threadtime > "$TMP" 2>/dev/null

count() { n=$(grep -c "$1" "$TMP" 2>/dev/null); echo "${n:-0}"; }

echo "=== VR 输入链路体检  $SERIAL ==="
echo

# ---------- A. 6DoF 视觉定位链 ----------
echo "[A] 6DoF（12d1:3a09 双目模组 / 与 CF20 无关）"

# 一次 adb 往返同时取 VS 接口数和 6DoF video 节点；USB 重枚举瞬态会读到空，
# 间隔 3 秒复采一次（手册 11.7：等 3~10 秒重跑即可）。
probe_6dof() {
    "$ADB" -s "$SERIAL" shell 'n=0; for u in /sys/bus/usb/devices/*; do p=$(grep PRODUCT= "$u/uevent" 2>/dev/null); case "$p" in *3a09*) for i in "$u"/*:1.*; do [ -d "$i" ] || continue; c=$(cat "$i/bInterfaceClass" 2>/dev/null | tr -d " \n"); s=$(cat "$i/bInterfaceSubClass" 2>/dev/null | tr -d " \n"); [ "$c" = "0e" ] && [ "$s" = "02" ] && n=$((n+1)); done;; esac; done; echo "VS=$n"; echo -n "VID="; for v in /sys/class/video4linux/video*; do nm=$(cat "$v/name" 2>/dev/null); case "$nm" in *6DoF*) echo -n "$(basename $v) ";; esac; done; echo' </dev/null 2>/dev/null | tr -d '\r'
}
R=$(probe_6dof)
VS=$(echo "$R" | sed -n 's/^VS=//p')
VID=$(echo "$R" | sed -n 's/^VID=//p')
if [ "${VS:-0}" -eq 0 ] || [ -z "$VID" ]; then
    sleep 3
    R=$(probe_6dof)
    VS=$(echo "$R" | sed -n 's/^VS=//p')
    VID=$(echo "$R" | sed -n 's/^VID=//p')
fi
echo "    UVC VideoStreaming 接口(class 0e/02) 数量 = ${VS:-0}   （0 = 模组只报控制接口/重枚举瞬态）"
echo "    6DoF 视频节点 = ${VID:-（无）}"

NULLBIND=$(count 'mRuntimeInterface == null')
FH=$(count '6Dof Header is false')
FL=$(count '6Dof left controller is false')
echo "    mRuntimeInterface == null = $NULLBIND 次   ← 非 0 时 isHW6DoFAvailable 第一行就返回 false"
echo "    Huawei 6Dof Header/left false = $FH / $FL 次"

# --- 6DoF binder 链（2026-11-08 第五轮补）：把「绑定没发生」和「权限被拒」分开 ---
# 之前把断点笼统归到 RUNTIME_ALLOW 权限，实测证伪：设备上
#   com.huawei.android.permission.VR = granted=true，
#   com.huawei.hvrsdkserverapp.permission.RUNTIME_ALLOW = granted=true，
#   onBind 的 isVrMode 判断也已被 patch 成常量 true（死代码）。
# 真正链路：眼镜在位 → IVRSystemServiceManager.isVRMode()=true
#   → ArvrRuntimeService.onCreate 初始化 j(manager) → VrFramework$System.register()
#   → TemperatureReceiver.register() → VrParamsRequester.bindRuntimeService()
#   → ArvrRuntimeService.onBind(ACTION_GET_INTERNAL_INTERFACE) → binder
#   → onServiceConnected 赋 mRuntimeInterface → isHW6DoFAvailable() 才有机会 true
# 2026-11-08 第六轮修正：VrFramework$System.registerReceivers() 在全 SDK 里
#   **没有任何调用点**（死代码），而它内部的 TemperatureReceiver.register()
#   才是 bindRuntimeService 的唯一调用者。所以原版恒 bind=0。
#   补丁 fix_runtime_bind.py 在 HvrSdkBridge.offer 的 FRAMEWORK 分支补上这一步。
BIND=$(count 'bind RuntimeService')
BRIDGEOK=$(count 'bindRuntimeService OK on SetClass copy')
BRIDGEFAIL=$(count 'bindRuntimeService failed')
ONBIND=$(count 'ArvrRuntimeService: onBind')
PERMDENY=$(count 'not Internal permitted')
MGRNULL=$(count 'mManager == null')
CHKVR=$(count 'checkVRMode fail')
NOCTX=$(count 'no application context')
# 点亮链（同轮新增）：WalleDev 陷入 STATUS_FAULT 时会每 100ms 重开设备，
# 眼镜来不及激活；hwvr-activate 补发 HIDIOCSFEATURE(5) 才能打破循环。
FAULT=$(count 'STATUS_FAULT')
CLOSE=$(count 'closeDevice')
ACTSDK=$(count 'active device(2) OK')
ACTMOD=$(count 'active device(2) sent')
HYD=$("$ADB" -s "$SERIAL" shell 'ls /dev/hidraw* 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
VRSYS=$("$ADB" -s "$SERIAL" shell 'timeout 4 content call --uri content://com.huawei.vrlauncherx.registry --method getService --arg vr_system 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')
echo "    --- 绑定链判据 ---"
echo "    hidraw 节点数 = ${HYD:-0}          （0 = 眼镜 USB 未枚举，最上游）"
echo "    vr_system 注册表 = ${VRSYS:-（读不到）}"
echo "    checkVRMode fail / no application context = $CHKVR / $NOCTX 次"
echo "    bind RuntimeService / onBind / not Internal permitted = $BIND / $ONBIND / $PERMDENY 次"
echo "    HvrSdkBridge 补丁 OK / failed = $BRIDGEOK / $BRIDGEFAIL 次   （0/0 = 未装补丁或日志被刷掉）"
echo "    mManager == null = $MGRNULL 次   （RuntimeService 的 manager 没初始化）"
echo "    --- 点亮链判据 ---"
echo "    STATUS_FAULT / closeDevice = $FAULT / $CLOSE 次   （close 高频 = WalleDev 重开死循环）"
echo "    active device(2) OK(SDK) / sent(模块) = $ACTSDK / $ACTMOD 次"
echo "    ⚠ 本脚本读的是 logcat -d 环形缓冲，VRRender 每帧刷屏会把旧行冲掉，"
echo "      上面这些计数为 0 **不等于没发生**。要看实时链路用："
echo "      adb -s $SERIAL shell 'logcat -v threadtime -s DevHid:V VrParamsRequester:V HvrSdkBridge:V'"
if [ "${CLOSE:-0}" -gt 20 ]; then
    echo "    [结论] 眼镜激活链不稳：SDK 每 100ms close/open，眼镜来不及点亮；"
    echo "           用 fix/magisk-module/modules/hwvr-activate 或等模块 30s 冷却自动补发。"
fi
if [ "${BIND:-0}" -eq 0 ] && [ "${HYD:-0}" -eq 0 ]; then
    echo "    [结论] 眼镜 USB 物理离线 → isVRMode=false → manager 不初始化 → 绑定从未发起。"
    echo "           这不是 binder/权限缺口；软件侧 (vr_system / 权限 / onBind) 都已就位。"
elif [ "${BIND:-0}" -eq 0 ] && [ "${BRIDGEOK:-0}" -eq 0 ]; then
    echo "    [结论] 或 VrFramework\$System.register() 未触发绑定，或日志已被刷掉。"
    echo "           补丁装上后应出现 HvrSdkBridge: bindRuntimeService OK；"
    echo "           用上面的 tag 过滤实时抓复核，别只信 -d 的 0。"
elif [ "${PERMDENY:-0}" -gt 0 ]; then
    echo "    [结论] onBind 权限被拒，检查 com.huawei.android.permission.VR 授予状态。"
elif [ "${MGRNULL:-0}" -gt 0 ]; then
    echo "    [结论] RuntimeService manager 未初始化，查 isVRMode() / vr_system 可达性。"
fi

# ---------- B. 3DoF CF20 手柄 ----------
echo
echo "[B] 3DoF（HUAWEI CF20 / BLE / com.huawei.vrhandle）"
"$ADB" -s "$SERIAL" shell 'dumpsys bluetooth_manager 2>/dev/null | grep -E "CONNECTED|DISCONNECTED" | tail -4' 2>/dev/null | tr -d '\r' | sed 's/^/    /'
"$ADB" -s "$SERIAL" shell 'su -c "cat /data/data/com.huawei.vrhandle/shared_prefs/sp_device_storage.xml 2>/dev/null"' 2>/dev/null \
    | grep -o 'CF20[^"&]*\|mDeviceConnectState[^}]*' | head -4 | sed 's/^/    /'
echo "    注：入库字段 mDeviceConnectState 会滞后，以 bluetooth 的 CONNECTED 为准。"
echo "    Controller Disconnected = $(count 'Controller Disconnected') 次"

# ---------- C. Unity 射线输入 ----------
echo
echo "[C] Unity 射线指针 / 头盔数据"
echo "    HVRInputModule.UpdateAnchorPos 空引用 = $(count 'UpdateAnchorPos') 次"
echo "    WalleDev: No Glass data = $(count 'No Glass data') 次"
echo "    VrHelmetExt: mVRDeviceExt is null = $(count 'mVRDeviceExt is null') 次"

echo
echo "=== 判定（三项互相独立，不要交叉归因） ==="
if [ "${VS:-0}" -eq 0 ]; then
    echo "[A][FAIL] 6DoF 模组没有 VideoStreaming 接口 → 无位姿数据 → 6DoF 恒 false。"
else
    echo "[A][OK]   6DoF 模组硬件链已通（VS 接口 + video 节点）；若仍 false，按上面「绑定链判据」逐环定位。"
fi
if [ "${NULLBIND:-0}" -gt 0 ]; then
    echo "[A][WARN] mRuntimeInterface 为 null —— 这是 VrParamsRequester 判 6DoF false 的直接原因，"
    echo "          与 CF20 手柄无关；同时会影响 queryVrStartTime / requestThermalParams 等接口。"
    echo "          注意：当前多为「绑定从未发起」（眼镜离线 → isVRMode=false），不是权限/binder 缺口。"
fi
echo "[B] 看上面 bluetooth 最近记录：CONNECTED = CF20 已连；只有 DISCONNECTED 才需要"
echo "    手柄开机/唤醒/充电（AutoScanCompat 每 60s 自动扫，见 fix/README.md 第九章）。"
echo "[C] NRE / No Glass data 持续出现时，射线指针可能算不出锚点 → 点图标不命中；"
echo "    应急启动应用：sh fix/tools/open-vr-app.sh <serial> alvr"
echo
echo "本脚本只读。6DoF 识别机制详见 docs/6DoF-为什么没起来.md 与"
echo "fix/2026-11-08-眼镜黑屏排查分析.md 第十一章。"
