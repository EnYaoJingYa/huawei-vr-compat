#!/system/bin/sh
# Unity 桌面旁路启动：拔镜瞬间启动（门禁只盯"眼镜已连接"状态），插回后把任务挪到眼镜屏。
LOG=/data/local/tmp/vrmove.log
echo "=== start $(date +%T)" > $LOG

PKG=com.huawei.vrlauncherx
ACT=com.huawei.vrlauncherx/.activity.Vr2dStartUpActivity

# 1) 等待眼镜断开（display 消失 = 门禁旁路窗口）
echo "waiting for glasses detach..." >> $LOG
while dumpsys display | grep -q 'HUAWEI VR Display'; do
    sleep 0.2
done
echo "detached $(date +%T) -> launching" >> $LOG

# 2) 断开窗口内启动 Unity（带重试，直到不再报 Error）
i=0
while [ $i -lt 30 ]; do
    OUT=$(am start -n $PKG/$ACT 2>&1)
    echo "try $i: $OUT" >> $LOG
    case "$OUT" in
        *Error*) sleep 0.4; i=$((i+1));;
        *) break;;
    esac
done
sleep 3

# 3) 等眼镜重新枚举，拿到新 display id
echo "waiting for glasses attach..." >> $LOG
for i in $(seq 1 600); do
    ID=$(dumpsys display | grep -B6 'HUAWEI VR Display' | grep -oE 'mDisplayId=[0-9]+' | head -1 | cut -d= -f2)
    [ -z "$ID" ] && ID=$(dumpsys display | grep -B10 'HUAWEI VR Display' | grep -oE 'Display id=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$ID" ]; then
        echo "attached, displayId=$ID $(date +%T)" >> $LOG
        break
    fi
    sleep 0.3
done

# 4) 把 Unity 任务挪到眼镜屏
TASK=$(am stack list 2>/dev/null | grep -B1 'vrlauncherx' | grep -oE 'taskId=[0-9]+' | head -1 | cut -d= -f2)
if [ -z "$TASK" ]; then
    TASK=$(am stack list 2>/dev/null | grep 'vrlauncherx' | grep -oE '[0-9]+' | head -1)
fi
echo "taskId=$TASK displayId=$ID" >> $LOG
if [ -n "$TASK" ] && [ -n "$ID" ]; then
    am stack move-task $TASK $ID >> $LOG 2>&1
    echo "moved" >> $LOG
else
    echo "move failed (task=$TASK id=$ID)" >> $LOG
fi
echo "=== done $(date +%T)" >> $LOG
