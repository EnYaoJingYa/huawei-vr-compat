#!/bin/bash
# 盒子恢复 + VR 库 magic mount 部署（盒子重启卡死后的恢复方案）
# 前提: adb 可连（无线或 USB）。若模块导致卡死，先让用户按音量+进 Magisk 安全模式
#       或直接电源重启几次 —— 本脚本会替换回干净脚本并部署 magic mount 版库文件。
set -e
ADB="D:/Tools/AndroidSDK/platform-tools/adb.exe"
DEV=192.168.43.133:5555
HERE=$(cygpath -m "$(cd "$(dirname "$0")" && pwd)")

"$ADB" connect $DEV || true

echo "== 1) 恢复干净版 post-fs-data.sh（剔除 rw remount 手动挂载段）=="
MSYS_NO_PATHCONV=1 "$ADB" push "$HERE/../../build/tmp/post-fs-data_clean.sh" /data/local/tmp/pfd_clean.sh
"$ADB" -s $DEV shell "su -c 'cp /data/local/tmp/pfd_clean.sh /data/adb/modules/hvrglass/post-fs-data.sh && chmod 755 /data/adb/modules/hvrglass/post-fs-data.sh && sh -n /data/adb/modules/hvrglass/post-fs-data.sh && echo CLEAN_OK'"

echo "== 2) 部署 magic mount 版库树（system/etc + system/lib64）=="
MSYS_NO_PATHCONV=1 "$ADB" push "$HERE/system" /data/local/tmp/mod_system
"$ADB" -s $DEV shell "su -c 'rm -rf /data/adb/modules/hvrglass/system; mkdir -p /data/adb/modules/hvrglass/system; cp -a /data/local/tmp/mod_system/. /data/adb/modules/hvrglass/system/ && find /data/adb/modules/hvrglass/system -type f && echo SYSTEM_TREE_OK'"

echo "== 3) 清理 /data 下不再需要的 bind 源（保留白名单/hwvr 相关）=="
"$ADB" -s $DEV shell "su -c 'rm -f /data/adb/hvrglass/public_libraries.txt; rm -rf /data/adb/hvrglass/lib64; echo data-cleaned'"

echo "== 4) 同步本地模块源码 =="
cp "$HERE/../../build/tmp/post-fs-data_clean.sh" "$HERE/post-fs-data.sh" 2>/dev/null || true

echo "== 5) 重启 =="
"$ADB" -s $DEV shell "su -c 'reboot'" || true
echo "REBOOT_ISSUED — 等待开机后验证:"
echo "  ls -l /system/lib64/libc_secshared.so   (应为 75072 字节, magic mount)"
echo "  tail -5 /system/etc/public.libraries.txt (应含 libc++.so 等 4 行)"
echo "  zygote namespace 验证: grep libc++ /proc/\$(pidof zygote64)/root/system/etc/public.libraries.txt"
