#!/system/bin/sh
# 常驻流水线 v3：插回瞬间极速连发 am start（抢在门禁上膛前）→ 自动点隐私 → 挪上眼镜屏
LOG=/data/local/tmp/vrwatch.log
PKG=com.huawei.vrlauncherx
ACT=com.huawei.vrlauncherx/.activity.Vr2dStartUpActivity
echo "=== watch start $(date +%T)" > $LOG

get_vr_id() { dumpsys display | grep -oE 'HUAWEI VR Display, displayId [0-9]+' | head -1 | grep -oE '[0-9]+$'; }
fg() { dumpsys activity activities | grep mResumedActivity; }

while true; do
    # 等待眼镜在位
    while ! dumpsys display | grep -q 'HUAWEI VR Display'; do
        sleep 0.3
    done
    echo "attached $(date +%T)" >> $LOG

    # 插回瞬间：极速连发，任何一个穿门即停
    n=0; OK=0
    while [ $n -lt 60 ]; do
        am start -n $PKG/$ACT >/dev/null 2>&1
        case "$(fg)" in
            *vrlauncherx*) OK=1; break;;
        esac
        n=$((n+1))
        sleep 0.2
    done
    echo "spam done ok=$OK $(date +%T)" >> $LOG

    # 隐私声明页 → 自动点同意（最多 5 页）
    k=0
    while [ $k -lt 5 ]; do
        case "$(fg)" in
            *PrivacyStatementActivity*)
                input tap 810 2230
                sleep 4
                k=$((k+1));;
            *) break;;
        esac
    done
    echo "after privacy: $(fg)" >> $LOG

    # v11 前台 → 任务挪上眼镜屏
    case "$(fg)" in
        *vrlauncherx*)
            sleep 3
            ID=$(get_vr_id)
            TASK=$(am stack list 2>/dev/null | grep -B1 'vrlauncherx' | grep -oE 'taskId=[0-9]+' | head -1 | cut -d= -f2)
            echo "move task=$TASK display=$ID" >> $LOG
            if [ -n "$TASK" ] && [ -n "$ID" ]; then
                am stack move-task $TASK $ID true >> $LOG 2>&1
                echo "moved $(date +%T)" >> $LOG
            fi
            ;;
    esac

    # 等待拔出
    while dumpsys display | grep -q 'HUAWEI VR Display'; do
        sleep 0.3
    done
    echo "detached $(date +%T)" >> $LOG

    # 拔出后也刷 15 次（门禁若已复位则直接成功）
    n=0
    while [ $n -lt 15 ]; do
        am start -n $PKG/$ACT >/dev/null 2>&1
        case "$(fg)" in *vrlauncherx*) break;; esac
        n=$((n+1))
        sleep 0.3
    done
done
