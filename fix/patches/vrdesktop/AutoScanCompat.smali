.class public Lcom/huawei/vrhandle/AutoScanCompat;
.super Ljava/lang/Object;
.source "AutoScanCompat.java"
.implements Ljava/lang/Runnable;


# static fields
.field private static sLastAddr:Ljava/lang/String;
.field private static sLastFoundMs:J
.field private static sLastKickMs:J

# instance fields
.field private mService:Lcom/huawei/vrhandle/service/VRHandleService;


# direct methods
.method public constructor <init>(Lcom/huawei/vrhandle/service/VRHandleService;)V
    .registers 2

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/huawei/vrhandle/AutoScanCompat;->mService:Lcom/huawei/vrhandle/service/VRHandleService;

    return-void
.end method


# 由 VRHandleService.onCreate / onStartCommand 调用。
#
# 关键时序（2026-11-07 实测钉死）：
#   直接在这里 startScan 会早于 Service 的 startForeground()，蓝牙栈把
#   调用者判成后台，日志 E BluetoothUtils: Permission denial: Need
#   ACCESS_FINE_LOCATION permission to get scan results，
#   dumpsys bluetooth_manager 里 AppScanStats 显示 42 次扫描、
#   Total number of results: 0 —— 扫了但一个结果都拿不到。
#   logcat 顺序：onScannerRegistered -> Permission denial ->
#                show common foreground notification（前台通知在后）。
#   所以这里只做「安排」：用主 Looper 的 Handler 延迟 3 秒，等
#   startForeground() 完成后再由 run() 真正启动扫描。
#
# 60 秒节流：onCreate 冷启动安排一次；之后 VrSystemActor 每 20 秒发
# ACTION_RECONNECT_MSG，onStartCommand 再次调用，但 60 秒内不重复安排。
# 手柄晚开机 / 休眠唤醒后会在下一轮自动被扫到。
#
# 全程 try/catch：任何环境异常都静默跳过，绝不影响 Service 原有流程。
.method public static kick(Lcom/huawei/vrhandle/service/VRHandleService;)V
    .registers 6

    :try_start_0
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    sget-wide v2, Lcom/huawei/vrhandle/AutoScanCompat;->sLastKickMs:J

    sub-long/2addr v0, v2

    const-wide/32 v2, 0xea60

    cmp-long v4, v0, v2

    if-gez v4, :do_scan

    return-void

    :do_scan
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v0

    sput-wide v0, Lcom/huawei/vrhandle/AutoScanCompat;->sLastKickMs:J

    const-string v0, "AutoScanCompat"

    const-string v1, "kick: schedule BLE scan after foreground +3s"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    new-instance v0, Landroid/os/Handler;

    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;

    move-result-object v1

    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V

    new-instance v1, Lcom/huawei/vrhandle/AutoScanCompat;

    invoke-direct {v1, p0}, Lcom/huawei/vrhandle/AutoScanCompat;-><init>(Lcom/huawei/vrhandle/service/VRHandleService;)V

    const-wide/16 v2, 0xbb8

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    return-void
.end method


# 延迟到 Service 前台通知之后才真正启动 BLE 扫描。
# t0/y0 是 vrhandle 自带的扫描管理器（R() 自初始化单例，构造函数从
# VrHandleApplication 取 Context 与 BluetoothAdapter）；N(Lp0/c) 即
# startScan；回调用 Service 已构造好的 m 字段（VRHandleService$d
# implements BluetoothDeviceDiscoverCallback）。
.method public run()V
    .registers 3

    :try_start_0
    const-string v0, "AutoScanCompat"

    const-string v1, "run: auto BLE scan (foreground ready)"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    invoke-static {}, Lt0/y0;->R()Lt0/y0;

    move-result-object v0

    iget-object v1, p0, Lcom/huawei/vrhandle/AutoScanCompat;->mService:Lcom/huawei/vrhandle/service/VRHandleService;

    iget-object v1, v1, Lcom/huawei/vrhandle/service/VRHandleService;->m:Lp0/c;

    invoke-virtual {v0, v1}, Lt0/y0;->N(Lp0/c;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    return-void
.end method


# 由 VRHandleService$d.a(BluetoothDevice) 调用（扫描回调）：
# 纯后台复刻「配对页点击连接」，并把手柄入库，之后每次开机由
# 20 秒 RECONNECT 心跳自动重连，不再依赖任何 UI。
#
# 原厂链路断点（2026-11-07 逆向确认）：
#   N2(BluetoothDevice) -> v.w(DeviceInfo) -> BluetoothManager.T0()
#   T0 要求回调 a$g 非空 —— 而它只在配对页 ScanningFragment 里经
#   t0/i.q() 注册，纯后台恒为 null，扫到的设备被静默丢弃。
#
# 补法（对应配对页行为）：
#   1. BluetoothManager.a1(DeviceInfo)  = 配对页点击设备后的连接入口
#      -> d1() -> e.f(mac) 让 vrservice 发起 GATT 连接；
#   2. VrSdkApi.h2(DeviceInfo) = 入库 + l2() 持久化到
#      shared_prefs/sp_device_storage，之后心跳 getUsedDeviceList
#      就能拿到设备、开机自动重连。
#      注意 h2 的异步落盘 r2() 只在 DeviceConnectState == 2 时持久化
#      （原厂语义：连接成功才入库），所以先 setDeviceConnectState(2)。
#      a1 连接成功后原厂 i2() -> h2() 会再次入库，幂等（H0 去重）。
#
# 60 秒同址节流：扫描期间同一手柄每 ~500ms 广播一次，不节流会反复
# 调 a1/h2。全程 try/catch，绝不影响 Service 原有流程。
.method public static onDeviceFound(Landroid/bluetooth/BluetoothDevice;)V
    .registers 7

    :try_start_0
    if-eqz p0, :ret

    invoke-virtual {p0}, Landroid/bluetooth/BluetoothDevice;->getAddress()Ljava/lang/String;

    move-result-object v0

    if-eqz v0, :ret

    invoke-virtual {p0}, Landroid/bluetooth/BluetoothDevice;->getName()Ljava/lang/String;

    move-result-object v1

    if-eqz v1, :ret

    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v2

    sget-wide v4, Lcom/huawei/vrhandle/AutoScanCompat;->sLastFoundMs:J

    sub-long/2addr v2, v4

    const-wide/32 v4, 0xea60

    cmp-long v6, v2, v4

    if-gez v6, :fresh

    sget-object v6, Lcom/huawei/vrhandle/AutoScanCompat;->sLastAddr:Ljava/lang/String;

    if-eqz v6, :fresh

    invoke-virtual {v6, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v6

    if-eqz v6, :fresh

    return-void

    :fresh
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v2

    sput-wide v2, Lcom/huawei/vrhandle/AutoScanCompat;->sLastFoundMs:J

    sput-object v0, Lcom/huawei/vrhandle/AutoScanCompat;->sLastAddr:Ljava/lang/String;

    const-string v2, "AutoScanCompat"

    new-instance v3, Ljava/lang/StringBuilder;

    invoke-direct {v3}, Ljava/lang/StringBuilder;-><init>()V

    const-string v4, "device found: "

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v3, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v4, " -> connect + persist"

    invoke-virtual {v3, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v3}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v3

    invoke-static {v2, v3}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    new-instance v2, Lcom/huawei/vrhandle/datatype/DeviceInfo;

    invoke-direct {v2}, Lcom/huawei/vrhandle/datatype/DeviceInfo;-><init>()V

    invoke-virtual {v2, v0}, Lcom/huawei/vrhandle/datatype/DeviceInfo;->setDeviceIdentify(Ljava/lang/String;)V

    invoke-virtual {v2, v1}, Lcom/huawei/vrhandle/datatype/DeviceInfo;->setDeviceName(Ljava/lang/String;)V

    const/4 v3, 0x2

    invoke-virtual {v2, v3}, Lcom/huawei/vrhandle/datatype/DeviceInfo;->setDeviceConnectState(I)V

    invoke-static {}, Lcom/huawei/vrhandle/a;->m1()Lcom/huawei/vrhandle/a;

    move-result-object v3

    invoke-virtual {v3, v2}, Lcom/huawei/vrhandle/a;->a1(Lcom/huawei/vrhandle/datatype/DeviceInfo;)V

    invoke-static {}, Lt0/l8;->N0()Lt0/l8;

    move-result-object v3

    invoke-virtual {v3, v2}, Lt0/l8;->h2(Lcom/huawei/vrhandle/datatype/DeviceInfo;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :ret
    return-void

    :catch_0
    move-exception v0

    return-void
.end method
