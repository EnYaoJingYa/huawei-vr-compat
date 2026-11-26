#!/bin/sh
# =============================================================================
# 华为手柄「开机自动 BLE 扫描 + 自动连接」一键补丁
#
#   sh fix/patches/vrdesktop/apply_autoscan_patch.sh [serial]
#
# 背景（2026-11-07 实测）：
#   VRHandleService 只有「重连已入库设备」路径：VrSystemActor 每 20 秒发
#   ACTION_RECONNECT_MSG，但 mDeviceInfoList size = 0 时直接
#   `not connected to any device, skip`。Service 只认 4 个 action，
#   **没有任何扫描入口**；扫描逻辑全在配对页 ScanningFragment 里。
#   盒子 shared_prefs 空、Bonded devices 空 → 手柄从未入库 → 永远连不上。
#   实测发 ACTION_GLASS_AWAY_TO_NEAR 也不会触发扫描（Discovering: false）。
#
# 做法（最小差分，不改原业务逻辑）：
#   新增一个 AutoScanCompat 类，由 VRHandleService.onCreate /
#   onStartCommand 调用。它用 vrhandle 自带的 BLE 扫描管理器 t0/y0
#   （R() 自初始化单例，构造函数从 VrHandleApplication 拿 Context 和
#   BluetoothAdapter），把 Service 已有的 m 字段（VRHandleService$d
#   implements BluetoothDeviceDiscoverCallback）传给 N(Lp0/c) 启动扫描；
#   扫到设备后原有链路走 N2(BluetoothDevice) 入库并连接，不需要配对页 UI。
#   时序关键点：扫描必须延后到 startForeground() 之后。直接在 onCreate
#   里 startScan 会被蓝牙栈判成后台，日志
#     E BluetoothUtils: Permission denial: Need ACCESS_FINE_LOCATION ...
#   且 AppScanStats「42 次扫描 / Total number of results: 0」。
#   AutoScanCompat 用 Handler.postDelayed(3s) 等前台通知起来再扫。
#   60 秒节流 + 全程 try/catch：每次 RECONNECT 心跳都会检查，手柄晚开机、
#   休眠唤醒后会在下一轮被扫到，且绝不影响 Service 原有流程。
#
# Manifest 补丁（纯后台的关键，2026-11-07 决定性实验后加入）：
#   设备 Android 11（SDK 30）+ vrhandle targetSdk=31。后台 Service
#   扫描被「仅在使用期间允许」的定位授权拦截，UID 级 appops
#   COARSE_LOCATION 恒为 foreground，set/reset/--uid 都改不掉；
#   对照实验：可见 Activity 时拒绝 0 条，前台服务（延后 3s）仍全拒。
#   targetSdk=31 在 R 上的唯一纯后台解法是「始终允许」定位 =
#   Manifest 声明 ACCESS_BACKGROUND_LOCATION + root pm grant。
#   原包没声明，pm grant 直接 SecurityException。所以流程里用
#   apktool 重编 Manifest（只加一条 uses-permission，节点数 54→55），
#   编译产物只取 AndroidManifest.xml 塞回 APK，其余条目逐字节保留。
#   replace_manifest.py 会校验新串池里确有该权限（UTF-16LE）。
#
#   开机链路（无需额外守护）：hvrglass/service.sh 在 boot_completed 后
#   拉起 ArvrRuntimeService → VrSystemActor 20 秒心跳 → VRHandleService
#   onStartCommand → kick。service.sh 另补一条显式 start，让开机立即扫，
#   不用等首轮心跳。
#
# 权限前提（安装后自动补）：
#   E BluetoothUtils: Permission denial: Need ACCESS_FINE_LOCATION ...
#   appops fine/coarse_location 显式 allow + bluetooth_scan allow +
#   ACCESS_BACKGROUND_LOCATION（Manifest 已声明，见上）pm grant，
#   见 fix/tools/grant-vr-perms.sh。本脚本安装后会顺手补一遍。
#
# 依赖：python3、baksmali-fat.jar / smali-fat.jar、java（JRE 17）、
#       Android build-tools 的 zipalign/apksigner.jar、
#       fix/signing/hvr-compat-debug.jks（口令 android）。
#       可用 ADB / JAVA / BUILD_TOOLS 覆盖路径。
#
# 可回退：原 APK 存到 build/tmp/autoscan/base.apk，
#         adb install -r 该文件即可还原。
# =============================================================================
set -eu

SERIAL="${1:-192.168.43.133:5555}"
# 必须用盘符风格（pwd -W）：Windows 原生 python/java 不认 MSYS 的 /f/... 路径。
ROOT=$(cd "$(dirname "$0")/../../.." && (pwd -W 2>/dev/null || pwd))
OUT="$ROOT/build/tmp/autoscan"
PATCHDIR="$ROOT/fix/patches/vrdesktop"
KEYSTORE="$ROOT/fix/signing/hvr-compat-debug.jks"

find_adb() {
    [ -n "${ADB:-}" ] && [ -x "$ADB" ] && { printf '%s' "$ADB"; return 0; }
    command -v adb 2>/dev/null && return 0
    for c in "/d/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/f/Tools/AndroidSDK/platform-tools/adb.exe" \
             "/c/platform-tools/adb.exe"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
ADB=$(find_adb) || { echo "[FATAL] 找不到 adb，请设置 ADB 环境变量"; exit 1; }

find_java() {
    [ -n "${JAVA:-}" ] && [ -x "$JAVA" ] && { printf '%s' "$JAVA"; return 0; }
    command -v java 2>/dev/null && return 0
    for j in "$ROOT"/build/tmp/jre17/*/bin/java.exe /c/Program\ Files/Java/*/bin/java.exe; do
        [ -x "$j" ] && { printf '%s' "$j"; return 0; }
    done
    return 1
}
JAVA=$(find_java) || {
    echo "[FATAL] 找不到 java（baksmali/smali/apksigner 需要）。可下载 Temurin JRE 17"
    echo "        解压到 build/tmp/jre17/ 或设置 JAVA=/path/to/java.exe"; exit 1; }

# 同样用盘符风格：apksigner.jar 的路径要交给 Windows java.exe。
BT="${BUILD_TOOLS:-D:/Tools/AndroidSDK/build-tools/34.0.0}"
[ -x "$BT/zipalign.exe" ] || { echo "[FATAL] zipalign 不存在：$BT"; exit 1; }
[ -f "$BT/lib/apksigner.jar" ] || { echo "[FATAL] apksigner.jar 不存在：$BT"; exit 1; }
[ -f "$KEYSTORE" ] || { echo "[FATAL] 签名密钥不存在：$KEYSTORE"; exit 1; }
for j in baksmali-fat.jar smali-fat.jar apktool_2.10.0.jar; do
    [ -f "$ROOT/tools/$j" ] || { echo "[FATAL] 缺少 $ROOT/tools/$j"; exit 1; }
done

MSYS2_ARG_CONV_EXCL='*'; export MSYS2_ARG_CONV_EXCL
rm -rf "$OUT/smali"
mkdir -p "$OUT/smali"

step() { echo; echo "===== $* ====="; }

step "1/9 连接设备并确定原包（回退底本）"
"$ADB" connect "$SERIAL" >/dev/null 2>&1
P=$("$ADB" -s "$SERIAL" shell "pm path com.huawei.vrhandle" | tr -d '\r' | sed 's/^package://')
[ -n "$P" ] || { echo "[FATAL] 设备上没有 com.huawei.vrhandle"; exit 1; }
# 设备上可能已经是补丁版；要拿到「真原包」可用 BASE_APK 指定一份干净底本，
# 这样 build/tmp/autoscan/base.apk 才能作为可靠的回退镜像。
if [ -n "${BASE_APK:-}" ] && [ -f "$BASE_APK" ]; then
    cp "$BASE_APK" "$OUT/base.apk"
    echo "  使用指定原包: $BASE_APK"
else
    "$ADB" -s "$SERIAL" pull "$P" "$OUT/base.apk" 2>&1 | tail -1
    echo "  使用设备当前 APK（若已打过补丁，回退镜像也是补丁版）"
fi
echo "  原 APK: $(stat -c %s "$OUT/base.apk") B（回退底本）"

step "2/9 提取 dex 并定位含 VRHandleService 的那个"
python3 - "$OUT/base.apk" "$OUT" <<'PY'
import sys, zipfile
from pathlib import Path
apk, out = sys.argv[1], Path(sys.argv[2])
with zipfile.ZipFile(apk) as z:
    dexes = [n for n in z.namelist() if n.endswith('.dex')]
    for n in dexes:
        (out / n).write_bytes(z.read(n))
        print(f'  {n}: {len(z.read(n))} B')
(out / 'dexlist.txt').write_text('\n'.join(dexes) + '\n', encoding='utf-8')
PY
DEXCOUNT=$(wc -l < "$OUT/dexlist.txt" | tr -d ' ')
echo "  共 $DEXCOUNT 个 dex"

step "3/9 baksmali 反编译（逐 dex 独立目录）"
while IFS= read -r d; do
    [ -n "$d" ] || continue
    # 目录名直接用 dex 条目名（如 classes.dex），不再二次拼后缀，
    # 避免 basename 在不同 shell 下对 ".dex" 后缀处理不一致。
    "$JAVA" -jar "$ROOT/tools/baksmali-fat.jar" d "$OUT/$d" \
        -o "$OUT/smali/$d" 2>&1 | tail -2
done < "$OUT/dexlist.txt"

SMALIDIR=""
HITS=0
for dir in "$OUT/smali"/*; do
    if [ -f "$dir/com/huawei/vrhandle/service/VRHandleService.smali" ]; then
        SMALIDIR="$dir"
        HITS=$((HITS + 1))
    fi
done
[ "$HITS" -eq 1 ] || {
    echo "[FATAL] 含 VRHandleService.smali 的 dex 目录应为 1 个，实际 $HITS 个"; exit 1; }
[ -n "$SMALIDIR" ] || { echo "[FATAL] 反编译产物里找不到 VRHandleService.smali"; exit 1; }
DEXNAME="$(basename "$SMALIDIR")"
echo "  目标 smali 目录: $SMALIDIR"
echo "  对应 dex 条目  : $DEXNAME"

step "4/9 注入 AutoScanCompat + 两处 kick 调用"
python3 "$PATCHDIR/inject_autoscan.py" "$SMALIDIR" "$PATCHDIR/AutoScanCompat.smali"

step "5/9 smali 回编译 dex"
"$JAVA" -jar "$ROOT/tools/smali-fat.jar" a "$SMALIDIR" \
    -o "$OUT/$DEXNAME.new" 2>&1 | tail -5
echo "  新 dex: $(stat -c %s "$OUT/$DEXNAME.new") B"

step "6/9 替换 dex（其余 APK 条目逐字节保留）"
python3 "$PATCHDIR/replace_dex.py" "$OUT/base.apk" "$DEXNAME" \
    "$OUT/$DEXNAME.new" "$OUT/unsigned.apk"

step "7/9 Manifest 补丁：声明 ACCESS_BACKGROUND_LOCATION（纯后台扫描关键）"
rm -rf "$OUT/mnf"
"$JAVA" -jar "$ROOT/tools/apktool_2.10.0.jar" d -f -s -o "$OUT/mnf" \
    "$OUT/base.apk" 2>&1 | tail -1
python3 "$PATCHDIR/patch_manifest_bgloc.py" "$OUT/mnf"
"$JAVA" -jar "$ROOT/tools/apktool_2.10.0.jar" b "$OUT/mnf" \
    -o "$OUT/mnf/built.apk" 2>&1 | tail -1
# 只取编译产物里的二进制 AndroidManifest.xml（解到独立文件名，别覆盖
# mnf/AndroidManifest.xml 源文本，否则下次重编会把二进制当源）。
unzip -p "$OUT/mnf/built.apk" AndroidManifest.xml > "$OUT/manifest_bgloc.axml"
python3 "$PATCHDIR/replace_manifest.py" "$OUT/unsigned.apk" \
    "$OUT/manifest_bgloc.axml" "$OUT/unsigned2.apk"

step "8/9 zipalign + apksigner v1/v2 重签 + 证书一致性校验"
"$BT/zipalign.exe" -p -f 4 "$OUT/unsigned2.apk" "$OUT/aligned.apk"
"$JAVA" -jar "$BT/lib/apksigner.jar" sign \
    --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$OUT/autoscan-signed.apk" "$OUT/aligned.apk"
NEW=$("$JAVA" -jar "$BT/lib/apksigner.jar" verify --print-certs \
      "$OUT/autoscan-signed.apk" 2>/dev/null | grep "SHA-256 digest" | head -1)
OLD=$("$JAVA" -jar "$BT/lib/apksigner.jar" verify --print-certs \
      "$OUT/base.apk" 2>/dev/null | grep "SHA-256 digest" | head -1)
[ "$NEW" = "$OLD" ] || { echo "[FATAL] 签名证书与原包不一致，拒绝安装"; exit 1; }
echo "  [OK] 证书与原包一致，可 pm install -r 覆盖"
python3 - "$OUT/autoscan-signed.apk" "$DEXNAME" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    b = z.read(sys.argv[2])
print(f'  新 APK {sys.argv[2]}: {len(b)} B  '
      f'含 AutoScanCompat={b"AutoScanCompat" in b}')
assert b'AutoScanCompat' in b, '补丁类没进 dex'
PY

step "9/9 安装 + 补 BLE 扫描授权 + 冷启动触发扫描"
"$ADB" -s "$SERIAL" push "$OUT/autoscan-signed.apk" \
    /data/local/tmp/vrh-autoscan.apk 2>&1 | tail -1
"$ADB" -s "$SERIAL" shell "pm install -r /data/local/tmp/vrh-autoscan.apk" 2>&1 | tr -d '\r'
"$ADB" -s "$SERIAL" shell "su -c 'pm grant com.huawei.vrhandle android.permission.ACCESS_FINE_LOCATION; pm grant com.huawei.vrhandle android.permission.ACCESS_COARSE_LOCATION; pm grant com.huawei.vrhandle android.permission.ACCESS_BACKGROUND_LOCATION; appops set com.huawei.vrhandle android:fine_location allow; appops set com.huawei.vrhandle android:coarse_location allow; appops set com.huawei.vrhandle android:bluetooth_scan allow; cmd deviceidle whitelist +com.huawei.vrhandle'" >/dev/null 2>&1
# 清缓冲，避免把上一次扫描的历史日志当成本次验收结果。
"$ADB" -s "$SERIAL" shell "logcat -c; am force-stop com.huawei.vrhandle; sleep 2; am start-foreground-service -n com.huawei.vrhandle/.service.VRHandleService -a com.huawei.vrservice.ACTION_RECONNECT_MSG" >/dev/null 2>&1
sleep 22
"$ADB" connect "$SERIAL" >/dev/null 2>&1
echo "  -- 扫描日志（本次窗口）--"
"$ADB" -s "$SERIAL" shell "logcat -d 2>/dev/null | grep -E 'AutoScanCompat|VrDeviceManager: (enter discover|startScan|discover time)|ACCESS_FINE_LOCATION|onScanResult' | tail -12" 2>&1 | tr -d '\r'
"$ADB" -s "$SERIAL" shell "rm -f /data/local/tmp/vrh-autoscan.apk" >/dev/null 2>&1

echo
echo "[完成] 验收命令："
echo "  adb shell logcat -d | grep -E 'AutoScanCompat|mDeviceInfoList size|CF20'"
echo "  - 出现 kick: schedule BLE scan + run: auto BLE scan + startScan，"
echo "    且没有 ACCESS_FINE_LOCATION 权限拒绝 = 自动扫描链路打通"
echo "  - mDeviceInfoList size 由 0 变 1、出现 CF20 / connectGatt = 手柄已入库并连接"
echo "  - 若一直 size=0 且无权限拒绝日志，说明手柄当前没在 BLE 广播："
echo "    按一下手柄电源键唤醒 / 别让它连着别的设备，下一轮 60s 内会自动扫到"
echo
echo "[回退] adb install -r $OUT/base.apk"
