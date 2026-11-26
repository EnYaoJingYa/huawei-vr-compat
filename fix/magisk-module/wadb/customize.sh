SKIPUNZIP=0

# service.sh 必须可执行
chmod 755 "$MODDIR/service.sh"

# 禁用开关目录（想临时关掉：touch /data/adb/wadb/disable）
mkdir -p /data/adb/wadb
