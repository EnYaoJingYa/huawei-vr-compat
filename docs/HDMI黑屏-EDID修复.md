# HDMI 黑屏：不是线坏，是 EDID 被改成 3200×1600@70 了

> 2026-11-02 / 设备 `192.168.43.133`（RK3566 盒子，Android 11，Magisk 26.3）

## 症状

接便携屏无信号、无背光，盒子端一切正常（能 adb、能截屏、应用在跑）。

## 定位

两个命令一对比，矛盾就出来了：

```
# 显示服务认为自己是 1080p
$ adb shell dumpsys display | grep DisplayDeviceInfo
DisplayDeviceInfo{"内置屏幕", 1920 x 1080, modeId 1 ...}

# 内核实际输出的却是 3200x1600
$ adb shell su -c 'cat /sys/kernel/debug/dri/0/summary'
Video Port0: ACTIVE
    Connector: HDMI-A-1
    Display mode: 3200x1600p70
	clk[412180] ...
	H: 3200 3260 3268 3308
	V: 1600 1613 1614 1780
    Cluster0-win0: src 1920x1080 -> dst 3200x1600
```

`dumpsys display` 报 1080p 是**应用层**的分辨率；HWC 把它当纹理再硬件放大到 3200×1600 送出去。所以系统内部一切"正常"，屏上却什么都没有 —— 一块 1080p 的便携屏锁不住 1600p70 的像素时钟（412.18MHz），只能黑屏。

## 根因

`/data/adb/modules/hvrglass` 的 `post-fs-data.sh` 每次开机都往 debugfs 写一份**只声明 3200×1600@70** 的假 EDID：

```
/sys/kernel/debug/dri/0/HDMI-A-1/edid_override   ← 256 字节，全是 VR Glass 时序
```

这是为 VR Glass 准备的：那副眼镜是固定时序面板，DDC/EDID 读不出来（`dwhdmi-rockchip: failed to get edid`），不注入就永远是 1080p 黑屏。但反过来，**只要注入，任何显示器都会被骗成"只支持 3200×1600@70"**，普通屏必然黑。

所以之前接眼镜没问题，换便携屏就黑 —— 模块没区分对象。

## 现场修复（不重启）

写入一份 1920×1080@60 的 EDID，再让 HWC 重新读：

```sh
# 1. 造 EDID（本地）
python tools/make-edid.py edid_1080p.bin

# 2. 推上去并覆盖
adb push edid_1080p.bin /data/local/tmp/
adb shell su -c 'cat /data/local/tmp/edid_1080p.bin > /sys/kernel/debug/dri/0/HDMI-A-1/edid_override'

# 3. 重读 EDID（关键，光写不生效）
adb shell su -c 'setprop ctl.restart surfaceflinger'
```

验证：

```
Display mode: 1920x1080p60
clk[148500] H: 1920 2008 2052 2200  V: 1080 1084 1089 1125
```

画面即恢复（截屏可见桌面正常渲染）。

> 注：`edid_override` **没法清空回直通**——写 0 字节无效，写入即常驻内核。要恢复"用屏幕自己的 EDID"只能重启。

## 永久修复：模块按需注入

`post-fs-data.sh` 改成先判断再注入，默认 `auto`：

| 情形 | 行为 |
|---|---|
| 已接屏，能读到真实 EDID（普通显示器/便携屏） | **不注入**，用屏自己的时序 |
| 已接屏，但 EDID 为空（VR Glass 的特征） | 注入 3200×1600@70 |
| 开机时根本没接屏 | 不注入，让后插的屏用自己的 EDID |

模式文件 `/data/adb/hvrglass/mode`：

- `auto`（默认，可不存在）
- `force-vr` 无条件注入
- `force-off` 永不注入，等同停用本模块的 EDID 部分

### 运行时切换

```sh
adb shell su -c 'sh /data/adb/hvrglass/edid-mode.sh show'    # 看状态
adb shell su -c 'sh /data/adb/hvrglass/edid-mode.sh vr'      # 切回眼镜时序
adb shell su -c 'sh /data/adb/hvrglass/edid-mode.sh 1080p'   # 切回通用 1080p
```

`show` 会一并打印当前内核输出时序，避免再被 `dumpsys display` 误导。

### 相关文件

| 路径 | 说明 |
|---|---|
| `/data/adb/modules/hvrglass/post-fs-data.sh` | 已改为按需注入（原版备份在 `/data/local/tmp/post-fs-data.bak.sh`） |
| `/data/adb/hvrglass/edid-mode.sh` | 运行时切换 |
| `/data/adb/hvrglass/edid_1080p.bin` | 通用 1080p EDID |
| `/data/adb/modules/hvrglass/common/edid_only.bin` | VR Glass 的 3200×1600 EDID（未改） |
| `tools/make-edid.py` | EDID 生成器，可改分辨率重新生成 |

## 一条经验

排查外接屏不看 `dumpsys display`，看内核：

```sh
su -c 'cat /sys/kernel/debug/dri/0/summary'        # 真实时序
su -c 'wc -c /sys/class/drm/card0-HDMI-A-1/edid'   # 有效 EDID 长度
cat /sys/class/drm/card0-HDMI-A-1/status           # connected / disconnected
```

`status=connected` + `enabled` + 屏不亮，九成是模式不匹配（EDID 被改、或 HWC 挑了屏不支持的时序）。
