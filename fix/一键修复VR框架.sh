#!/bin/sh
# =============================================================================
# 一键修复 VR 框架 / 打通 VR 桌面链路（本地入口：Git Bash / Linux / macOS）
#
#   sh fix/一键修复VR框架.sh                          # 默认 install（四包 + 点亮链路）
#   sh fix/一键修复VR框架.sh <serial> check           # 只读验收
#   sh fix/一键修复VR框架.sh <serial> off             # 关掉模拟辅助显示
#   sh fix/一键修复VR框架.sh <serial> rollback        # 装回四个原版基线 APK
#   sh fix/一键修复VR框架.sh <serial> launcher        # 单独启动 3D Launcher
#
# 2026-11-05 更新：四个最终包，各自解决一段真实根因。
#
#   ① launcherx-full.apk
#      清单声明的 HvrContextProvider / VrSystemRegistryProvider 在 dex 里不存在
#      -> 注入现成 compat classes4.dex + 补 ctx1；
#      删除 classes.dex 里 6 个空壳桩类；恢复 LibUpdateClient.runUpdate()
#      （native SetClass 唯一入口）；
#      新增 HvrSdkBridge：接住 native SetClass 实际持有的 Class 副本，在**那一份**
#      上反射调用 VrFramework.init / VrHelmetExt.init，修掉两份 DexClassLoader
#      造成的 VrFramework.mAppActivity = null；
#      HVRActivity.getSystemService("vr_system") 返回同加载器动态代理，
#      其 isVRMode() 从 runtime 发布的 vr_system_state 读真实 SystemServiceBinder。
#   ② vrservice-full.apk
#      ctx0 provider 挂进 <application>；补定义 signature 级
#      com.huawei.android.permission.VR（EMUI 上由框架定义，通用安卓没有）。
#   ③ hvrsdkserverapp-full.apk
#      5 个补丁组件克隆进 <application>；27 个 64 位库固化进 lib/arm64-v8a/
#      （修 MyService dlopen 失败）；新增 HvrStatePublisher 把真实
#      SystemServiceBinder 发布到 vr_system_state。
#   ④ com.huawei.vrhandle-pose.apk  ★本次新增★
#      32 位 vrhandle 原本用 createPackageContext(runtime).nativeLibraryDir 拼
#      System.load 绝对路径加载 libMobileSensor/libWalleAlg/libWalleDev/libvrpose，
#      但 runtime 现在是 64 位（只解压 lib/arm64/，全是 ELF64），32 位进程加载
#      必然失败且被 catch 吞掉 -> helmetPoseStart() 无 native 实现 ->
#      VRHandleService 崩溃循环 -> 头盔姿态/pHelmetHandle 链断裂。
#      修法：4 个 ELF32 库打进本包 lib/armeabi-v7a/、manifest 改
#      extractNativeLibs=true 让系统解压到 lib/arm/、新增 HvrPoseLibPath.get()
#      优先返回自身 nativeLibraryDir。不动 runtime / 不动系统分区。
#      重签后 com.huawei.android.permission.VR 也自动 granted。
#
# 不改开机脚本、不重启、不动系统分区，随时可 rollback。
#
# 2026-11-05 真机验收（45s 冷启动）：
#   load libMobileSensor/WalleAlg/WalleDev/vrpose success 各 1；helmetPoseStart 执行；
#   getHelmetPose 返回四元数并被 launcherx 的 VrControllerManager 收到
#   （SetHelmetPoseOffset）；RenderModule "Init VR end" / mRenderInited 1；
#   UnsatisfiedLinkError / FATAL / ApplicationQuit / App activity is null /
#   VRPromptActivity 全部 0；栈顶保持 com.huawei.vrlauncherx/.MainActivity。
#
# 2026-11-06 追加（真机冷启动 + 重启复验，手册 8.4 已改写）：
#   ⑤ vrservice / launcherx 的 classes4.dex 补
#      WindowManagerEx$LayoutParamsEx.setDisplaySideMode(I)V 空实现
#      （fix_runtime_ondestroy.py 同目录的 add_set_display_side_mode.py）。
#   ⑥ vrservice 9 个二进制布局内联 103 处 EMUI androidhwext ?0x0201xxxx
#      属性引用（inline_hwext_attrs.py），修掉 ServiceTermActivity 的 InflateException。
#   ⑦ hvrsdkserverapp 的 classes.dex 三处最小补丁（fix_runtime_ondestroy.py）：
#      onDestroy 的 j.deinit() / unregisterReceiver(a) 判空，
#      onCreate 短路前补回原厂 b() = startForeground()。
#      根因：compat 早先把 onCreate 整个短路成 VrSystemActor.start()+return，
#      原厂 startForeground() 永不执行 → ANR 杀进程 → 桌面 Activity 被 force remove。
#   ⑧ com.youku.vr 占位包（make_youku_stub.py）：VRService.installVrApp() 的
#      checkCurrentComponentsExist() 遍历 6 个必需包，真机只缺这一个内容应用，
#      缺失就弹 ServiceTermActivity；占位包只声明包名，可随时 uninstall 回退。
#   ⑨ 用户协议 agreement=true 写入 vrinstaller 的 SharedPreferenceProvider
#      （content insert setBoolean/..._preferences --bind agreement:b:true）；
#      界面点「同意」在这套通用安卓上不落盘，否则 15 秒一轮重新弹授权页。
#   ⑩ 【已废弃、勿用】fix_prepare_msg.py 单包把 0x3ea 的 Message.obj 置 null，
#      只压住一个发送点，随后每 ~30 秒一轮 8 个 FATAL：接收端 Integer.intValue
#      NPE + handleEarphonePlugged 继续发 Boolean 触发 marshal 异常。
#   ⑪ fix_messenger_payload.py（双包通用修复，取代 ⑩）：
#      vrservice ServiceConnector.sendMessageToClient(I,Object) 把 Integer /
#      Boolean / CharSequence 编进 Message.data 的 hvr_compat_* Bundle、obj 置 null；
#      launcherx t0/c$b.handleMessage 在分发前按 key 还原 obj，原厂分支语义不变。
#      另含 HvrProximityCompat：/dev/ttyUSB* 缺失导致 proximity=-1 时按已佩戴置 1
#      （已装机，待物理 USB attach 事件触发后验证；--restore 可整体回退）。
#   验收（真机 180s + 255s 两轮）：FATAL / Can't marshal / Integer.intValue NPE /
#      ANR / startVrInstaller / ServiceTermActivity / PrepareQuit / CheckVRModeFail
#      全部 0，System prepare done, start vr. 正常出现。
#      ⚠️ 这不等于「已进 VR 桌面」：早先第 5 轮的 .MainActivity + UnityMain 是
#      obj=null 误导 proximity 判断的短时假象，已作废（手册 8.4.2）。
#
# ⚠️ 仍未解（手册 8.4.3）：
#   1) 【已有运行时解法，本脚本第 6 步自动执行】/dev/ttyUSB* 不存在 → vcom
#      打不开 → proximity=-1 → t0/c.P(I) 不启动 3D 桌面。fix/ttyusb-compat.sh on
#      绑定 usbserial_generic (12d1:107e) + chmod 666 已实测消除
#      Permission denied / can not open vcom；off 可立即回退。
#      但眼镜 USB 会反复重连、重启后绑定丢失（service.sh 守护默认关闭，
#      用 sh fix/install.sh <serial> --ttyusb-compat 打开），且内核仍报
#      "hidraw: passed too short report"，华为私有激活帧发不出，激活链未闭环。
#   2) 冷启动缺真实 USB_DEVICE_ATTACHED 事件，doHelmetPrepare() 不被调用，
#      heartbeat not init, wait. 可持续 500+ 次；需物理拔插眼镜 USB / 电源验证。
#   3) 眼镜物理输出仍是 1920x1080p60 / clk[148500]，未点亮 3200x1600p70；
#      点亮配方有效但 stop/start SF 后约 100 秒整机重启回落，属另一条线。
#   4) VrSystemActor 只在 start()/display 事件 refresh()，冷启动若 USB 判据
#      未就绪就不再重查（重插辅助屏可让 0x3e9 → 0x1/0xf/0x3eb 握手跑通，
#      但会改变 displayId，不能当正式修法）。
# =============================================================================
set -u

SERIAL="${1:-192.168.43.133:5555}"
ACTION="${2:-install}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
    *MINGW*|*MSYS*|*CYGWIN*)
        command -v cygpath >/dev/null 2>&1 && HERE="$(cygpath -m "$HERE")" ;;
esac
PATCH="$HERE/patches/vrdesktop"
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
ADB="$(find_adb)" || { echo "[FATAL] 找不到 adb"; exit 1; }

L="$PATCH/com.huawei.vrlauncherx-full.apk"
V="$PATCH/com.huawei.vrservice-full.apk"
R="$PATCH/com.huawei.hvrsdkserverapp-full.apk"
H="$PATCH/com.huawei.vrhandle-pose.apk"
# VRService 组件完整性检查只缺这个内容应用；占位包可 adb uninstall 完整回退
Y="$HERE/apks/com.youku.vr-stub.apk"
LB="$PATCH/rollback-launcherx.apk"
VB="$PATCH/rollback-vrservice.apk"
RB="$HERE/apks/com.huawei.hvrsdkserverapp.apk"
HB="$HERE/apks/com.huawei.vrhandle.apk"

echo "[i] adb    = $ADB"
echo "[i] 设备   = $SERIAL"
echo "[i] 动作   = $ACTION"
"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device >/dev/null 2>&1 || {
    echo "[FATAL] 设备连不上（检查开机 / 无线 adb）"; exit 1; }

# vrhandle 补丁包是 hvr-compat 签名，设备基线可能是华为原签；
# 只有明确报「签名冲突」才卸载重装。无线 adb 常掉线，绝不能把连接失败
# 误判成签名冲突而卸载包，否则会留下缺包状态。回退时同理。
install_apk() {
    pkg="$1"; apk="$2"
    "$ADB" connect "$SERIAL" >/dev/null 2>&1
    out="$("$ADB" -s "$SERIAL" install -r "$apk" 2>&1)"
    if printf '%s' "$out" | grep -q Success; then
        echo "      覆盖安装成功"; return 0
    fi
    if ! printf '%s' "$out" | grep -qiE "INSTALL_FAILED_UPDATE_INCOMPATIBLE|signature"; then
        echo "[FATAL] $pkg 安装失败且不是签名冲突，不卸载以免留下缺包："
        printf '%s\n' "$out" | tail -4
        return 1
    fi
    echo "      签名不一致，卸载后重装 ..."
    "$ADB" connect "$SERIAL" >/dev/null 2>&1
    "$ADB" -s "$SERIAL" uninstall "$pkg" >/dev/null 2>&1
    if "$ADB" -s "$SERIAL" install -r "$apk" 2>&1 | grep -q Success; then
        echo "      卸载重装成功"; return 0
    fi
    echo "[FATAL] $pkg 卸载后重装失败"; return 1
}

uid_of() {
    "$ADB" -s "$SERIAL" shell "pm list packages -U $1" 2>/dev/null \
        | tr -d '\r' | sed -n 's/.*uid://p' | head -1
}

verify() {
    echo
    echo "===== 验收 ====="
    echo "-- 各包 hvrcompat provider --"
    for p in com.huawei.vrlauncherx com.huawei.vrservice com.huawei.hvrsdkserverapp; do
        echo "  [$p]"
        "$ADB" -s "$SERIAL" shell "dumpsys package $p | grep hvrcompat" | head -5
    done
    echo "-- runtime 64 位原生库数量（应为 30）--"
    RDIR="$("$ADB" -s "$SERIAL" shell "pm path com.huawei.hvrsdkserverapp" | tr -d '\r' | sed 's/package://;s|/base.apk||')"
    "$ADB" -s "$SERIAL" shell "ls $RDIR/lib/arm64/*.so 2>/dev/null | wc -l"
    echo "-- vrhandle 32 位姿态库（应为 5 个，全部 ELF32）--"
    HDIR="$("$ADB" -s "$SERIAL" shell "pm path com.huawei.vrhandle" | tr -d '\r' | sed 's/package://;s|/base.apk||')"
    "$ADB" -s "$SERIAL" shell "ls -l $HDIR/lib/arm/*.so 2>/dev/null"
    echo "-- VR 权限是否已定义 --"
    "$ADB" -s "$SERIAL" shell "dumpsys package permissions | grep -m1 'com.huawei.android.permission.VR]'"
    echo "-- 模拟辅助显示（null=未开）--"
    "$ADB" -s "$SERIAL" shell "settings get global overlay_display_devices"
    echo "-- 最近日志关键指标（计数）--"
    "$ADB" -s "$SERIAL" logcat -d -v threadtime 2>/dev/null | awk '
        /load libvrpose success/    { ok1++ }
        /helmetPoseStart/           { ok2++ }
        /getHelmetPose/             { ok3++ }
        /No valid frame to display/ { warn++ }
        /UnsatisfiedLinkError/      { e1++ }
        /ApplicationQuit/           { e2++ }
        /App activity is null/      { e3++ }
        /FATAL EXCEPTION/           { e4++ }
        END {
            printf "  %-34s %d\n", "load libvrpose success",    ok1+0
            printf "  %-34s %d\n", "helmetPoseStart",            ok2+0
            printf "  %-34s %d\n", "getHelmetPose",              ok3+0
            printf "  %-34s %d\n", "No valid frame to display",  warn+0
            printf "  %-34s %d\n", "UnsatisfiedLinkError",       e1+0
            printf "  %-34s %d\n", "ApplicationQuit",            e2+0
            printf "  %-34s %d\n", "App activity is null",       e3+0
            printf "  %-34s %d\n", "FATAL EXCEPTION",            e4+0
        }'
    echo "-- VR 进程 --"
    "$ADB" -s "$SERIAL" shell "ps -A | grep -E 'vrservice|vrlauncherx|hvrsdk|vrhandle'"
    echo "-- 栈顶 --"
    "$ADB" -s "$SERIAL" shell "dumpsys activity activities | grep mResumedActivity"
    echo
    echo "[i] 期望：provider 齐全、runtime 30 个库、vrhandle lib/arm 5 个 32 位库、"
    echo "    overlay 有值、helmetPoseStart 成功、无 UnsatisfiedLinkError / ApplicationQuit。"
    echo "[i] 上面的计数是 logcat 缓冲区的历史值：成功项为 0 通常只是已滚出缓冲区；"
    echo "    若 FATAL EXCEPTION 非 0，先看时间戳是否早于本次冷启动，可先 logcat -c 再重跑。"
    echo "[i] 2026-11-06 已确证清零（180s + 255s 两轮）：FATAL / Can't marshal /"
    echo "    Integer.intValue NPE / ANR / startVrInstaller / ServiceTermActivity /"
    echo "    PrepareQuit / CheckVRModeFail；System prepare done, start vr. 正常出现。"
    echo "[i] 注意：这不等于已进 3D 桌面。早先栈顶 .MainActivity + UnityMain 是"
    echo "    单包置 null 补丁误导 proximity 的短时假象，已作废（手册 8.4.2）。"
    echo "[i] 仍剩（手册 8.4.3）：/dev/ttyUSB* 缺失 → proximity=-1 → t0/c.P(1) 门不放行；"
    echo "    冷启动缺 USB_DEVICE_ATTACHED，需物理拔插眼镜验证 HvrProximityCompat；"
    echo "    眼镜仍 1920x1080p60 未点亮 3200x1600p70。"
}

case "$ACTION" in
    check)
        verify
        ;;
    off)
        echo "[i] 关闭模拟辅助显示 ..."
        "$ADB" -s "$SERIAL" shell "settings delete global overlay_display_devices"
        verify
        ;;
    rollback)
        for f in "$LB" "$VB" "$RB" "$HB"; do
            [ -f "$f" ] || { echo "[FATAL] 缺回退基线 APK: $f"; exit 1; }
        done
        echo "[1/6] 卸载 com.youku.vr 占位包 ..."
        "$ADB" -s "$SERIAL" uninstall com.youku.vr >/dev/null 2>&1
        echo "[2/6] 回退 vrservice ...";       install_apk com.huawei.vrservice "$VB" || exit 1
        echo "[3/6] 回退 hvrsdkserverapp ..."; install_apk com.huawei.hvrsdkserverapp "$RB" || exit 1
        echo "[4/6] 回退 launcherx ...";       install_apk com.huawei.vrlauncherx "$LB" || exit 1
        echo "[5/6] 回退 vrhandle（华为原签）..."; install_apk com.huawei.vrhandle "$HB" || exit 1
        echo "[6/6] 关闭模拟辅助显示 ..."
        "$ADB" -s "$SERIAL" shell "settings delete global overlay_display_devices"
        verify
        ;;
    launcher)
        "$ADB" -s "$SERIAL" shell "am start -n com.huawei.vrlauncherx/.MainActivity"
        sleep 3
        verify
        ;;
    install|*)
        for f in "$L" "$V" "$R" "$H" "$Y"; do
            [ -f "$f" ] || { echo "[FATAL] 缺少补丁 APK: $f"; exit 1; }
        done
        echo "[1/11] 安装 vrservice（ctx0 + VR 权限 + sidemode + hwext 内联 + Messenger 载荷 + proximity compat）..."
        install_apk com.huawei.vrservice "$V" || exit 1
        echo "[2/11] 安装 hvrsdkserverapp（前台服务 + onDestroy 判空，161MB 稍慢）..."
        install_apk com.huawei.hvrsdkserverapp "$R" || exit 1
        echo "[3/11] 安装 launcherx（compat + 去桩 + runUpdate + HvrSdkBridge + sidemode + obj 还原）..."
        install_apk com.huawei.vrlauncherx "$L" || exit 1
        echo "[4/11] 安装 vrhandle（32 位姿态库 + HvrPoseLibPath）★ ..."
        install_apk com.huawei.vrhandle "$H" || exit 1
        echo "[5/11] 安装 com.youku.vr 占位包（补齐第 6 个必需组件，消掉安装向导门）..."
        install_apk com.youku.vr "$Y" || exit 1
        sleep 4
        echo "[6/11] 打开模拟辅助显示 + 恢复 vcom（头盔在位判定前提）..."
        "$ADB" -s "$SERIAL" shell "settings put global overlay_display_devices 1920x1080/320"
        # /dev/ttyUSB* 缺失 → UpgradeGlass 打不开 vcom → proximity=-1 →
        # t0/c.P(I) 不启动 3D 桌面。运行时绑定 usbserial_generic + chmod 666，
        # 重启即失效、off 可立即回退（fix/ttyusb-compat.sh，2026-11-06 实测）。
        if [ -f "$HERE/ttyusb-compat.sh" ]; then
            sh "$HERE/ttyusb-compat.sh" "$SERIAL" on 2>/dev/null | sed 's/^/      /' || \
                echo "      [WARN] vcom 绑定未成功，跑 sh fix/ttyusb-compat.sh $SERIAL check 看细节"
        else
            echo "      [WARN] 缺 fix/ttyusb-compat.sh，跳过 vcom 恢复"
        fi
        echo "[7/11] 持久化用户协议同意状态（消掉反复弹授权页 / 安装向导）..."
        # VRUtils.isInstallAgreementAccepted() 查这个 provider；界面点「同意」在这套
        # 通用安卓上不落盘，会 15 秒一轮 Need to reapply for user agreement authorization。
        "$ADB" -s "$SERIAL" shell "content insert --uri content://com.huawei.vrinstaller.provider.sharedpreferenceprovider/setBoolean/com.huawei.vrinstaller_preferences --bind agreement:b:true" >/dev/null 2>&1
        "$ADB" -s "$SERIAL" shell "content query --uri content://com.huawei.vrinstaller.provider.sharedpreferenceprovider/getBoolean/com.huawei.vrinstaller_preferences --projection agreement" 2>/dev/null | tr -d '\r' | sed 's/^/      /'
        echo "[8/11] 拉起 VRService（用动态 uid，不再写死 10073）..."
        U="$(uid_of com.huawei.vrservice)"
        [ -n "$U" ] && "$ADB" -s "$SERIAL" shell "su $U -c 'am start-service --user 0 -n com.huawei.vrservice/com.huawei.vrservice.VRService'" >/dev/null 2>&1
        echo "[9/11] 拉起 VrGlassWatchService -> MyService / VrSystemActor ..."
        U="$(uid_of com.huawei.hvrsdkserverapp)"
        [ -n "$U" ] && "$ADB" -s "$SERIAL" shell "su $U -c 'am start-service --user 0 -n com.huawei.hvrsdkserverapp/.compat.VrGlassWatchService'" >/dev/null 2>&1
        sleep 5
        echo "[10/11] 启动 VR 桌面入口（已验证为 .MainActivity）..."
        "$ADB" -s "$SERIAL" shell "am start -W -n com.huawei.vrlauncherx/.MainActivity" 2>&1 | tail -6
        echo "[11/11] 验收 ..."
        verify
        ;;
esac
