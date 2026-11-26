package com.hvr.shell;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.view.Display;

/**
 * 常驻服务：盯着眼镜，在位就把 VR 主界面拉起来。
 *
 * 与旧方案的区别只有一句话：<b>不再拉起任何华为组件</b>。
 * 以前这里要跨应用启动 hvrsdkserverapp 的监督服务、唤醒 vrservice、让原版桌面
 * 走握手；现在这些包都不装了，VR 主界面就是本应用的 {@link ShellActivity}，
 * 它自己创建 Presentation 输出到眼镜、自己用姿态数据渲染双目。
 *
 * 于是「插上眼镜 → 直接进 VR 桌面」这条链上不再有第三方依赖：
 * 开机广播 → 本服务 → 检测到眼镜 → 启动本应用的主界面。
 */
public final class ShellService extends Service implements DisplayManager.DisplayListener {

    static final String ACTION_RECHECK = "com.hvr.shell.action.RECHECK";
    /** 远程校准：adb 发 am broadcast 改左右眼旋转/翻转，画面歪了不用找按钮。 */
    static final String ACTION_CALIB = "com.hvr.shell.action.CALIB";
    /** 远程启动桌面里的应用（与点格子同一条路径，用于验证启动链路）。 */
    static final String ACTION_LAUNCH = "com.hvr.shell.action.LAUNCH";

    private static final long POLL_MS = 2000L;
    /**
     * 在位期间每 15 秒确认一次主界面还在。用户戴上眼镜后可能把界面滑掉了
     * （或者被系统回收），这里能把它重新拉回来，而不需要用户再插一次。
     */
    private static final long ENSURE_MS = 15000L;

    private static final String CHANNEL_ID = "shell";
    private static final int FOOTFULL_SCREEN_ID = 42;
    private static final int NOTIFICATION_ID = 2001;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private DisplayManager displayManager;
    private boolean displayListenerRegistered;
    /** 最近一次请求启动桌面的时刻：给系统一点时间把 Activity 搬到眼镜屏，避免先挂 overlay 又拆。 */
    private long lastLaunchAt;
    /**
     * 启动桌面失败次数：EMUI 门禁（vr_system 未注册）拦截时 startActivity 不抛异常、
     * Activity 也不会起来，若不计数就会陷入「每次轮询重试启动→刷新等待窗口→
     * overlay 永远挂不上」的死循环。尝试 2 次后放弃 Activity 路线，直接服务直出。
     */
    private int launchFailures;

    private final GlassesOverlay overlay = GlassesOverlay.get();
    /** r21：手机屏悬浮触控板（不依赖 Activity，与手柄可同时用）。 */
    private final TouchpadOverlay touchpad = new TouchpadOverlay(this);

    private static ShellService instance;

    /**
     * r23：桌面 Activity 在前台时收掉悬浮触控板。
     *
     * <p>两者都在手机屏上：Activity 自带触控板和校准按钮，悬浮层压在上面会把点击全吃掉，
     * 用户看到的就是「点按钮没反应」。Activity 起来就收起，退到后台（眼镜里还在显示）
     * 再挂回来，这样两种控制方式都可用且不打架。</p>
     */
    static void setTouchpadSuppressed(boolean suppressed) {
        ShellService service = instance;
        if (service != null) {
            service.touchpad.setSuppressed(suppressed);
        }
    }

    private final BroadcastReceiver usbReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent == null ? null : intent.getAction();
            ShellState.event("USB 事件 " + action);
            evaluate("usb");
        }
    };

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            try {
                evaluate("poll");
            } catch (Throwable error) {
                ShellState.event("轮询异常（已恢复循环）", error);
            }
            handler.postDelayed(this, POLL_MS);
        }
    };

    private final Runnable ensure = new Runnable() {
        @Override
        public void run() {
            if (ShellState.glassPresent && !ShellActivity.isForeground()) {
                launchDesktop("keep-alive");
            }
            handler.postDelayed(this, ENSURE_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        ShellState.serviceStartedAt = System.currentTimeMillis();
        startForeground(NOTIFICATION_ID, buildNotification());
        registerDisplayListener();
        registerUsbReceiver();
        handler.post(poll);
        handler.post(ensure);
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                touchpad.show(); // r22：服务起来就挂触控板，不等眼镜
            }
        }, 800L);
        ShellState.event("VR 服务已启动");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if (ACTION_RECHECK.equals(action)) {
            ShellState.event("收到手动检测");
            evaluate("manual");
        } else if (ACTION_CALIB.equals(action)) {
            applyCalibration(intent.getStringExtra("op"), intent.getIntExtra("steps", 1));
        } else if (ACTION_LAUNCH.equals(action)) {
            // 与桌面里点格子走同一条 AppCatalog.launch，用来验证启动链路。
            String pkg = intent.getStringExtra("pkg");
            if (pkg != null && !pkg.isEmpty()) {
                boolean launched = AppCatalog.launch(this, pkg);
                ShellState.event("远程启动 " + pkg + (launched ? " 已发出" : " 失败"));
            }
        }
        return START_STICKY;
    }

    /** 远程校准入口（adb / 手机按钮共用底层）。op: rotl/rotr/swap/fliph/flipv/reset/空=查状态。 */
    private void applyCalibration(String op, int steps) {
        String note;
        if ("rotl".equals(op)) {
            note = EyeCalibration.nudge(this, true, steps);
        } else if ("rotr".equals(op)) {
            note = EyeCalibration.nudge(this, false, steps);
        } else if ("swap".equals(op)) {
            note = EyeCalibration.toggleSwap(this);
        } else if ("fliph".equals(op)) {
            note = EyeCalibration.toggleFlipH(this);
        } else if ("flipv".equals(op)) {
            note = EyeCalibration.toggleFlipV(this);
        } else if ("fliphl".equals(op)) {
            note = EyeCalibration.toggleEyeFlip(this, true, true);
        } else if ("flipvl".equals(op)) {
            note = EyeCalibration.toggleEyeFlip(this, true, false);
        } else if ("fliphr".equals(op)) {
            note = EyeCalibration.toggleEyeFlip(this, false, true);
        } else if ("flipvr".equals(op)) {
            note = EyeCalibration.toggleEyeFlip(this, false, false);
        } else if ("reset".equals(op)) {
            note = EyeCalibration.reset(this);
        } else {
            note = EyeCalibration.describe(this);
        }
        DesktopPresenter.get().publish(this);
        ShellState.event("远程校准[" + op + "]：" + note);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (displayListenerRegistered && displayManager != null) {
            try {
                displayManager.unregisterDisplayListener(this);
            } catch (Throwable error) {
                ShellState.event("注销显示监听失败", error);
            }
        }
        try {
            unregisterReceiver(usbReceiver);
        } catch (Throwable error) {
            ShellState.event("注销 USB 监听失败", error);
        }
        ControllerLink.stop();
        touchpad.hide();
        instance = null;
        ShellState.event("VR 服务已停止");
        super.onDestroy();
    }

    private void evaluate(String reason) {
        try {
            evaluateInner(reason);
        } catch (Throwable error) {
            ShellState.event("evaluate(" + reason + ") 异常", error);
        }
    }

    private long lastWakeAt;

    /**
     * 插上眼镜后系统会按 VR 使用场景自动熄掉手机屏，于是手机一片黑、触控板也点不动，
     * 用户以为「根本没有触控模式」。这里在眼镜在位时检测屏幕状态，熄了就拉起桌面
     * Activity（它带 setTurnScreenOn(true)），把屏点亮。
     */
    private void ensurePhoneAwake(String reason) {
        try {
            PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
            if (power == null || power.isInteractive()) {
                return;
            }
            long now = SystemClock.elapsedRealtime();
            if (now - lastWakeAt < 5000L) {
                return;
            }
            lastWakeAt = now;
            Intent wake = new Intent(this, ShellActivity.class);
            wake.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(wake);
            ShellState.event("手机屏已熄灭（" + reason + "），已请求点亮");
        } catch (Throwable error) {
            ShellState.event("点亮手机屏失败", error);
        }
    }

    private void evaluateInner(String reason) {
        boolean present = GlassPresence.sample(this);
        if (present) {
            if (!"poll".equals(reason)) {
                ShellState.event("眼镜在位（" + reason + "）：" + GlassPresence.describe());
            }
            // v11/华为栈路线已放弃：不再唤醒任何华为组件（vrservice 已被 EMUI 卸载）。
            if (ShellActivity.isForeground()) {
                launchFailures = 0;
            } else if (launchFailures < 2) {
                launchFailures++;
                launchDesktop(reason);
            } // 已失败 2 次以上：不再尝试启动，让 updateOverlay 直接服务直出
            try {
                ControllerLink.start(this);
            } catch (Throwable error) {
                ShellState.event("手柄链路启动失败（不影响眼镜输出）", error);
            }
            updateOverlay(reason);
            touchpad.show();
            ensurePhoneAwake(reason);
        } else {
            overlay.hide();
            // 触控板常驻：眼镜拔了也能先在手机上操作（用户点「隐藏」才收起）。
            if ("poll".equals(reason)) {
                return;
            }
            ShellState.event("眼镜不在位（" + reason + "）：" + GlassPresence.describe());
            try {
                ControllerLink.stop();
            } catch (Throwable error) {
                ShellState.event("手柄链路停止失败", error);
            }
        }
    }

    /**
     * 兜底输出：门禁拦 Activity 时直接把桌面窗口挂到眼镜屏。
     *
     * <p>顺序策略：</p>
     * <ol>
     *   <li>Activity 已被系统放到眼镜屏（vr_only 直出，最理想）→ 什么都不做；</li>
     *   <li>Activity 自己挂了 Presentation → 什么都不做；</li>
     *   <li>刚请求过启动（4 秒内）→ 再等等，先不挂；</li>
     *   <li>否则 → {@link GlassesOverlay} 服务直出，门禁管不到窗口。</li>
     * </ol>
     */
    private void updateOverlay(String reason) {
        Display glasses = overlay.findGlasses(this);
        if (glasses == null || ShellActivity.coversGlasses()) {
            if (overlay.isShowing()) {
                ShellState.event("眼镜输出交还：" + (glasses == null ? "屏已移除" : "Activity 已接管"));
            }
            overlay.hide();
            return;
        }
        long sinceLaunch = System.currentTimeMillis() - lastLaunchAt;
        if (launchFailures == 0 && sinceLaunch < 4000L) {
            ShellState.event("等待系统搬移 Activity 到眼镜屏（" + (4000L - sinceLaunch) + "ms 后挂服务直出）");
            return; // 首次启动尝试后等系统把 Activity 搬到眼镜屏
        }
        if (!overlay.isShowing()) {
            overlay.show(this, glasses, reason);
        }
    }

    private void launchDesktop(String reason) {
        Intent intent = new Intent(this, ShellActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        intent.putExtra(ShellActivity.EXTRA_TRIGGER, reason);
        try {
            startActivity(intent);
            lastLaunchAt = System.currentTimeMillis();
            ShellState.environmentNote = "已请求启动 VR 主界面（" + reason + "）";
        } catch (Throwable error) {
            // 后台启动 Activity 被拒：改走全屏意图通知（锁屏/黑屏下也能拉起 Activity），
            // 这正是原厂流程里「等用户解锁」那一环的替代品。
            ShellState.environmentNote = "直接启动被拒，改用全屏意图（" + reason + "）";
            ShellState.event("直接启动被拒，改用全屏意图", error);
            launchViaFullScreenIntent(intent);
        }
    }

    /** 全屏意图：USE_FULL_SCREEN_INTENT 允许在锁屏/灭屏时直接打开 Activity。 */
    private void launchViaFullScreenIntent(Intent intent) {
        try {
            NotificationManager manager =
                    (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            String fsiChannel = "shell_fsi";
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
                NotificationChannel channel = new NotificationChannel(fsiChannel,
                        "眼镜接入提醒", NotificationManager.IMPORTANCE_HIGH);
                manager.createNotificationChannel(channel);
            }
            PendingIntent fullScreen = PendingIntent.getActivity(this, 1, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    ? new Notification.Builder(this, fsiChannel)
                    : new Notification.Builder(this);
            builder.setContentTitle("VR 桌面待进入")
                    .setContentText("眼镜已连接，点击进入 VR 桌面")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .setPriority(Notification.PRIORITY_MAX)
                    .setCategory(Notification.CATEGORY_CALL)
                    .setFullScreenIntent(fullScreen, true);
            if (manager != null) {
                manager.notify(FOOTFULL_SCREEN_ID, builder.build());
            }
        } catch (Throwable error) {
            ShellState.event("全屏意图启动失败", error);
        }
    }

    private void registerDisplayListener() {
        displayManager = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
        if (displayManager == null) {
            ShellState.event("没有 DisplayManager，退化为轮询");
            return;
        }
        try {
            displayManager.registerDisplayListener(this, handler);
            displayListenerRegistered = true;
        } catch (Throwable error) {
            ShellState.event("注册显示监听失败", error);
        }
    }

    private void registerUsbReceiver() {
        try {
            IntentFilter filter = new IntentFilter();
            filter.addAction("android.hardware.usb.action.USB_DEVICE_ATTACHED");
            filter.addAction("android.hardware.usb.action.USB_DEVICE_DETACHED");
            registerReceiver(usbReceiver, filter);
        } catch (Throwable error) {
            ShellState.event("注册 USB 监听失败", error);
        }
    }

    @Override
    public void onDisplayAdded(int displayId) {
        evaluate("displayAdded:" + displayId);
    }

    @Override
    public void onDisplayRemoved(int displayId) {
        overlay.onDisplayRemoved(displayId);
        evaluate("displayRemoved:" + displayId);
    }

    @Override
    public void onDisplayChanged(int displayId) {
        Display display = displayManager == null ? null : displayManager.getDisplay(displayId);
        if (display != null && display.getDisplayId() == Display.DEFAULT_DISPLAY) {
            return;
        }
        evaluate("displayChanged:" + displayId);
    }

    private Notification buildNotification() {
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "VR 环境", NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        }
        PendingIntent open = PendingIntent.getActivity(
                this, 0, new Intent(this, ShellActivity.class),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return builder
                .setContentTitle("VR 运行中")
                .setContentText("插上眼镜即进入 VR 桌面")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentIntent(open)
                .setOngoing(true)
                .build();
    }

    static void ensureRunning(Context context) {
        Intent intent = new Intent(context, ShellService.class);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (Throwable error) {
            ShellState.event("启动 VR 服务失败", error);
        }
    }
}
