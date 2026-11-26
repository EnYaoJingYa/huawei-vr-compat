#!/bin/sh
# 无线 adb 辅助：每次调用先确保连上，再执行命令
# 用法：sh tools/wadb.sh "<shell 命令>"   或   sh tools/wadb.sh --raw <adb 子命令>
ADB="/d/Tools/AndroidSDK/platform-tools/adb.exe"
SERIAL="${WADB_SERIAL:-192.168.43.1:5555}"
"$ADB" connect "$SERIAL" >/dev/null 2>&1
"$ADB" -s "$SERIAL" wait-for-device
if [ "$1" = "--raw" ]; then
  shift
  exec "$ADB" -s "$SERIAL" "$@"
fi
exec "$ADB" -s "$SERIAL" shell "$@"
