package com.hvr.shell.cast;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Presentation;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Toast;

/**
 * 免 root 投屏：把手机默认屏镜像到眼镜副屏。
 *
 * <p>这是文档 §6.4 的「平面镜像」方案，不是原版立体合成：</p>
 *
 * <pre>
 *   用户在 Activity 里授权 MediaProjection
 *     → Service.startForeground(MEDIA_PROJECTION)
 *     → MediaProjection.createVirtualDisplay(AUTO_MIRROR, SurfaceTexture 的 Surface)
 *     → GL 里左右眼各采样同一帧（只建一个 VirtualDisplay）
 * </pre>
 *
 * <p>为什么只建一个 VirtualDisplay：Android 13 起同一个 MediaProjection
 * 创建多个 VirtualDisplay 时只有最后一个能出图，Android 14 进一步限制 token
 * 复用。左右两份画面必须在应用内复制，见 {@link MirrorGlView}。</p>
 *
 * <p>优先用副屏 Context 上的 {@code TYPE_APPLICATION_OVERLAY}；没有悬浮窗权限时
 * 回退到 {@link Presentation}。</p>
 */
public final class MirrorService extends Service {

    public static final String EXTRA_RESULT_CODE = "mirror.resultCode";
    public static final String EXTRA_RESULT_DATA = "mirror.resultData";
    public static final String ACTION_STOP = "com.hvr.shell.STOP_MIRROR";

    private static final String TAG = "MirrorService";
    private static final String CHANNEL_ID = "vr_cast";
    private static final int NOTIFICATION_ID = 0x56520001;

    private MediaProjection projection;
    private VirtualDisplay virtualDisplay;
    private int castDensityDpi = DisplayMetrics.DENSITY_DEFAULT;
    private WindowManager windowManager;
    private View overlay;
    private Presentation presentation;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 通知栏「停止」可能是冷启动，此时没有 MediaProjection token，
        // 不能带 mediaProjection 类型进前台（Android 14 会抛 SecurityException）。
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (intent == null) {
            stopSelf();
            return START_NOT_STICKY;
        }

        int resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0);
        Intent data = getParcelableIntent(intent, EXTRA_RESULT_DATA);
        if (projection == null && (resultCode == 0 || data == null)) {
            Log.w(TAG, "没有录屏 token");
            stopSelf();
            return START_NOT_STICKY;
        }

        // Android 10+ 要求先 startForeground，再 getMediaProjection。
        startInForeground();

        if (projection == null) {
            MediaProjectionManager manager =
                    (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
            if (manager == null) {
                Log.w(TAG, "MediaProjectionManager 不可用");
                stopSelf();
                return START_NOT_STICKY;
            }
            try {
                projection = manager.getMediaProjection(resultCode, data);
                projection.registerCallback(new MediaProjection.Callback() {
                    @Override
                    public void onStop() {
                        Log.i(TAG, "系统停止了录屏");
                        stopSelf();
                    }
                }, new Handler(Looper.getMainLooper()));
            } catch (Throwable error) {
                Log.w(TAG, "getMediaProjection 失败: " + error);
                stopSelf();
                return START_NOT_STICKY;
            }
        }

        showMirror();
        return START_NOT_STICKY;
    }

    /**
     * 取 Intent 里的 Parcelable。
     *
     * 示例工程原来用 Android 13 的 {@code getParcelableExtra(key, Intent.class)}，
     * 但本应用编译用的是 platform android-30（复刻机只有这一份 platform），
     * 那个重载在 30 的 android.jar 里不存在，直接编译不过。旧重载在所有版本上
     * 都还能用，所以退回旧写法 —— 只是编译期过时警告，运行行为一致。
     */
    @SuppressWarnings("deprecation")
    private static Intent getParcelableIntent(Intent source, String key) {
        return source.getParcelableExtra(key);
    }

    private void startInForeground() {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager =
                    (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (manager != null) {
                NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                        "VR 投屏", NotificationManager.IMPORTANCE_LOW);
                manager.createNotificationChannel(channel);
            }
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }

        Intent stop = new Intent(this, MirrorService.class).setAction(ACTION_STOP);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent stopIntent = PendingIntent.getService(this, 0, stop, flags);

        builder.setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentTitle("VR 投屏")
                .setContentText("正在把手机画面镜像到眼镜")
                .setOngoing(true)
                .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopIntent);

        Notification notification = builder.build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    private void showMirror() {
        if (overlay != null || presentation != null) {
            return;
        }
        Display display = DisplayFinder.find(this);
        if (display == null) {
            Log.w(TAG, "没有副屏\n" + DisplayFinder.describeAll(this));
            toast("未找到眼镜副屏，投屏停止");
            stopSelf();
            return;
        }

        Context displayContext = createDisplayContext(display);
        DisplayMetrics panelMetrics = new DisplayMetrics();
        display.getRealMetrics(panelMetrics);
        int panelWidth = Math.max(1, panelMetrics.widthPixels);
        int panelHeight = Math.max(1, panelMetrics.heightPixels);
        int densityDpi = panelMetrics.densityDpi > 0
                ? panelMetrics.densityDpi : DisplayMetrics.DENSITY_DEFAULT;

        DisplayMetrics phoneMetrics = new DisplayMetrics();
        try {
            DisplayManager manager = (DisplayManager) getSystemService(DISPLAY_SERVICE);
            Display phone = manager == null ? null
                    : manager.getDisplay(Display.DEFAULT_DISPLAY);
            if (phone != null) {
                phone.getRealMetrics(phoneMetrics);
            }
        } catch (Throwable error) {
            Log.w(TAG, "读取主屏尺寸失败: " + error);
        }
        int phoneWidth = phoneMetrics.widthPixels > 0 ? phoneMetrics.widthPixels : panelWidth;
        int phoneHeight = phoneMetrics.heightPixels > 0 ? phoneMetrics.heightPixels : panelHeight;

        int eyeWidth = Math.max(1, panelWidth / 2);
        float scale = Math.min(1f, Math.min((float) eyeWidth / phoneWidth,
                (float) panelHeight / phoneHeight));
        int viewWidth = Math.max(1, Math.round(phoneWidth * scale));
        int viewHeight = Math.max(1, Math.round(phoneHeight * scale));
        castDensityDpi = phoneMetrics.densityDpi > 0
                ? phoneMetrics.densityDpi : densityDpi;

        MirrorGlView view = new MirrorGlView(displayContext);
        view.mirror(viewWidth, viewHeight, this::attachProjection);

        int type = Build.VERSION.SDK_INT >= 26
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.FILL;

        try {
            windowManager = (WindowManager) displayContext.getSystemService(WINDOW_SERVICE);
            windowManager.addView(view, params);
            overlay = view;
            Log.i(TAG, "已显示到 " + DisplayFinder.describe(display));
            toast("投屏中：" + display.getName());
        } catch (Throwable error) {
            Log.w(TAG, "悬浮窗失败（" + error + "），改用 Presentation");
            overlay = null;
            showPresentation(displayContext, display, view);
        }
    }

    private void showPresentation(Context displayContext, Display display, View content) {
        try {
            Presentation window = new Presentation(displayContext, display);
            window.setContentView(content);
            window.setOnDismissListener(dialog -> {
                presentation = null;
                stopSelf();
            });
            window.show();
            presentation = window;
            Log.i(TAG, "Presentation 已显示到 " + DisplayFinder.describe(display));
            toast("投屏中（Presentation）：" + display.getName());
        } catch (Throwable error) {
            Log.w(TAG, "Presentation 也失败: " + error);
            toast("无法显示到眼镜：" + error);
            stopSelf();
        }
    }

    /**
     * GL 的 SurfaceTexture 就绪后回调（主线程）。只在这里建一个
     * VirtualDisplay；GL 上下文重建时会先释放旧的再建新的。
     */
    private void attachProjection(Surface surface, int width, int height) {
        if (projection == null || surface == null || !surface.isValid()) {
            return;
        }
        releaseVirtualDisplay();
        try {
            VirtualDisplay created = projection.createVirtualDisplay(
                    "VR-Cast", width, height, castDensityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    surface, null, null);
            if (created == null) {
                Log.w(TAG, "createVirtualDisplay 返回 null");
                toast("眼镜画面创建失败");
                stopSelf();
                return;
            }
            virtualDisplay = created;
            Log.i(TAG, "镜像 VirtualDisplay " + width + "x" + height + " 已创建");
        } catch (Throwable error) {
            Log.w(TAG, "createVirtualDisplay 失败: " + error);
            toast("眼镜画面创建失败：" + error);
            stopSelf();
        }
    }

    private void releaseVirtualDisplay() {
        if (virtualDisplay == null) {
            return;
        }
        try {
            virtualDisplay.release();
        } catch (Throwable error) {
            Log.w(TAG, "释放 VirtualDisplay 失败: " + error);
        }
        virtualDisplay = null;
    }

    @Override
    public void onDestroy() {
        // 先断开捕获，再销毁承载 Surface 的窗口。
        releaseVirtualDisplay();

        if (presentation != null) {
            try {
                presentation.dismiss();
            } catch (Throwable error) {
                Log.w(TAG, "dismiss Presentation 失败: " + error);
            }
            presentation = null;
        }
        if (overlay != null && windowManager != null) {
            try {
                windowManager.removeView(overlay);
            } catch (Throwable error) {
                Log.w(TAG, "移除悬浮窗失败: " + error);
            }
        }
        overlay = null;

        if (projection != null) {
            try {
                projection.stop();
            } catch (Throwable error) {
                Log.w(TAG, "停止 projection 失败: " + error);
            }
        }
        projection = null;

        stopForeground(true);
        super.onDestroy();
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }
}
