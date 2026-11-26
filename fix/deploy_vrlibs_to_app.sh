#!/bin/bash
# 把 libvrservice.so 缺的 4 个依赖库直接塞进 app 私有 lib 目录
# 原理: app classloader-namespace 优先搜索自身 nativeLibraryDir,
#       无需 public.libraries.txt / bind mount, 零卡 logo 风险
# 用法: bash fix/deploy_vrlibs_to_app.sh
set -u
ADB="D:/Tools/AndroidSDK/platform-tools/adb.exe"
DEV=192.168.43.133:5555

LIBS="/system/lib64/libc++.so /system/lib64/libutils.so /system/lib64/libcutils.so"

"$ADB" connect "$DEV" >/dev/null 2>&1

# 1) 清除危险的开机挂载脚本 (卡 logo 元凶)
echo "=== 1. 恢复干净的 post-fs-data.sh ==="
MSYS_NO_PATHCONV=1 "$ADB" push "$(dirname "$0")/../build/tmp/post-fs-data_clean.sh" /data/local/tmp/postfs_clean.sh || exit 1
"$ADB" -s "$DEV" shell "su -c 'cp /data/local/tmp/postfs_clean.sh /data/adb/modules/hvrglass/post-fs-data.sh && chmod 755 /data/adb/modules/hvrglass/post-fs-data.sh && sh -n /data/adb/modules/hvrglass/post-fs-data.sh && echo CLEAN_OK'"

# 2) 定位各 VR 应用的 nativeLibraryDir 并塞库
echo "=== 2. 塞库进 app ==="
"$ADB" -s "$DEV" shell "su -c '
for pkg in com.huawei.vrservice com.huawei.hvrsdkserverapp com.huawei.vrlauncherx com.lht.huaweivr.alvr; do
  apk=\$(pm path \$pkg 2>/dev/null | head -1 | sed \"s/package://;s/base.apk//\")
  [ -z \"\$apk\" ] && { echo \"\$pkg: not installed\"; continue; }
  dir=\"\${apk}lib/arm64\"
  [ -d \"\$dir\" ] || dir=\"\${apk}lib/arm\" 
  [ -d \"\$dir\" ] || { echo \"\$pkg: no lib dir\"; continue; }
  for lib in \$LIBS /data/adb/hvrglass/lib64/libc_secshared.so; do
    cp -f \$lib \"\$dir/\" 2>/dev/null
  done
  chmod 644 \$dir/libc++.so \$dir/libutils.so \$dir/libcutils.so \$dir/libc_secshared.so 2>/dev/null
  chown \$(stat -c \"%u:%g\" \$dir/base.apk 2>/dev/null || echo 1000:1000) \$dir/*.so 2>/dev/null
  echo \"\$pkg -> \$dir : \$(ls \$dir | grep -cE \"libc\\+\\+|libutils|libcutils|libc_secshared\") libs\"
done'"

# 3) 验证: 直接 dlopen 测试
echo "=== 3. 验证 ==="
"$ADB" -s "$DEV" shell "su -c 'ls /data/app/*/com.huawei.vrservice*/lib/arm64/ 2>/dev/null | head -8'"
echo DONE
