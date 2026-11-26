#!/system/bin/sh
#
# HUAWEI VR Glass EDID 注入（Magisk 模块 hvrglass）
#
# 背景：
#   VR Glass 是固定时序面板，只认 3200x1600@70，但它的 DDC/EDID 在这台
#   RK3566 盒子上读不到（dmesg: "dwhdmi-rockchip: failed to get edid"）。
#   没有 EDID 时内核只会给 1080p/720p，眼镜必然黑屏 —— 所以要注入。
#
# 但反过来说：一旦注入，**任何**接在 HDMI 上的屏幕都会被告知「我只支持
#   3200x1600@70」，普通显示器/便携屏锁不上这个时序 → 黑屏。
#   2026-11-02 就是这么把便携屏搞黑的。
#
# 所以这里改成按需注入：
#   mode=auto（默认）  接屏且能读到真实 EDID → 不动；读不到 EDID（眼镜）→ 注入
#   mode=force-vr      无条件注入（确定接的是 VR Glass）
#   mode=force-off     永不注入（纯直通，等于停用本模块的 EDID 部分）
#
# 切换：echo force-off > /data/adb/hvrglass/mode 然后重启。
# 运行时手动切换见同目录 edid-mode.sh（无需重启，但要重启 SurfaceFlinger）。

MODDIR=${0%/*}
BIN="$MODDIR/common/edid_only.bin"
[ -f "$BIN" ] || BIN=/data/adb/hvrglass/edid_only.bin

OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
CONN=/sys/class/drm/card0-HDMI-A-1
LOG=/data/local/tmp/edid_boot.log

[ -f "$BIN" ] || exit 0

mount | grep -q " /sys/kernel/debug " || mount -t debugfs none /sys/kernel/debug 2>/dev/null

MODE=$(cat /data/adb/hvrglass/mode 2>/dev/null | tr -d ' \r\n')
[ -z "$MODE" ] && MODE=auto
echo "$(date) 启动，mode=$MODE" >> "$LOG"

# --- ALVR/华为运行时平台伪装（必须在 zygote 之前，Build.MANUFACTURER 开机即固化） ---
# 注意：这一段必须无条件先执行，不能放在任何 exit 之后（历史 bug：force-vr 分支提前 exit 导致伪装丢失）
resetprop ro.product.manufacturer HUAWEI 2>/dev/null
# 华为「本机是否支持 VR」的只读断言（拼写就是 surport）。SystemPropertiesEx.getBoolean 只认
# "true"（"1" 会被 Boolean.parseBoolean 判成 false），缺了它 Vr2dStartUpActivity 会弹
# 「当前系统版本或机型不支持打开该应用」。
resetprop ro.vr.surport true 2>/dev/null
# /dev/hwvr1 不在这里 touch：假文件会让 vrservice 打开成功但协议全废。
# 由 service.sh 的守护循环在眼镜枚举出 hidraw 后建 symlink（真机是华为内核
# misc 设备，通用内核没有；symlink 到 hidraw 后 Feature Report 激活走通）。

# --- 3200x1600 分辨率白名单（systemless bind mount，2026-11-04 眼镜点亮的关键）---
# HWC (hwcomposer.rk30board.so) 的 mode_verify 只放行 /system/usr/share/resolution_white.xml
# 里列出的模式，原厂白名单没有 3200x1600 → 永远回落 1080p60，眼镜（无 scaler）黑屏。
# /system 剩余空间不足 5MB 改不动文件，故白名单放 /data 再 bind mount 上去。
# 注意：白名单条目必须用内核解析值（用 tools/modeinfo.c 读），vsync 字段手算必错。
WL_SRC=/data/adb/hvrglass/resolution_white.xml
WL_DST=/system/usr/share/resolution_white.xml
if [ -f "$WL_SRC" ] && [ -f "$WL_DST" ]; then
    if mount -o bind "$WL_SRC" "$WL_DST" 2>/dev/null; then
        echo "$(date) 白名单 bind mount 成功" >> "$LOG"
    else
        echo "$(date) 白名单 bind mount 失败（HWC 将回落 1080p）" >> "$LOG"
    fi
fi


# 等 debugfs 节点出现（HWC 首次 probe 之前必须写好）
i=0
while [ ! -e "$OVR" ] && [ $i -lt 15 ]; do
    i=$((i + 1))
    sleep 1
done
if [ ! -e "$OVR" ]; then
    echo "$(date) 超时：$OVR 未出现（不影响伪装）" >> "$LOG"
    exit 0
fi

apply=0
case "$MODE" in
    force-vr)
        apply=1
        ;;
    force-off|off|passthrough)
        apply=0
        ;;
    *)
        status=$(cat "$CONN/status" 2>/dev/null | tr -d ' \r\n')
        if [ "$status" = "connected" ]; then
            # 给内核留点时间把真实 EDID 读上来
            sleep 2
            size=$(wc -c < "$CONN/edid" 2>/dev/null | tr -d ' \r\n')
            [ -z "$size" ] && size=0
            if [ "$size" -gt 0 ]; then
                # 回到手册 6.3 的最小集：能读到真实 EDID 就直通。
                # 眼镜醒着时交出的是 HWV 真实 EDID（内含 3200x1600@70/90 两条
                # DTD），白名单放行后 HWC 自然选到 3200 —— 不需要也不应覆盖。
                # 2026-11-04 晚曾改成「认 22f6 指纹也强制注入」，把真实 EDID
                # 覆盖掉并逼出一连串强扭逻辑（detect/强制属性/重启 HWC），
                # 实测导致崩循环，已回滚。
                hdr=$(dd if="$CONN/edid" bs=1 skip=8 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
                apply=0
                echo "$(date) auto: 读到真实 EDID ${size}B (厂商=$hdr)，直通不注入" >> "$LOG"
            else
                apply=1
                echo "$(date) auto: 已接屏但 EDID 为空，判定为 VR Glass，注入" >> "$LOG"
            fi
        else
            # 开机时没接屏：不注入，让后来插上的任何屏幕用自己的 EDID
            apply=0
            echo "$(date) auto: 未接屏（$status），跳过注入" >> "$LOG"
        fi
        ;;
esac

if [ "$apply" = "1" ]; then
    # 只写 override，不做任何额外动作。
    # 2026-11-04 晚这里曾加过 setprop persist.vendor.framebuffer.main=3200x1600@70
    # 和 `echo detect > status` 开机重探：两者都是「上午成功之后」新增的变量，
    # 手册第六章的原始成功流程里根本没有。强制属性会让 HWC 在没有可用 3200
    # 模式时硬选，重探又与内核 DDC 抢 EDID —— 配合 service.sh 自愈重启 HWC，
    # 实测造成开机后崩循环。已全部移除。
    if cat "$BIN" > "$OVR" 2>/dev/null; then
        echo "$(date) 已写入 VR EDID（$(wc -c < "$OVR") 字节）" >> "$LOG"
    else
        echo "$(date) 写入失败：$OVR" >> "$LOG"
    fi
fi

exit 0
