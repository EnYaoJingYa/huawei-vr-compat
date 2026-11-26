package com.huawei.vrvirtualscreen.mirror;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
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
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/**
 * 把手机默认屏镜像到眼镜副屏（免 root）。
 *
 * 公开 API 链路：
 *
 *   MediaProjectionManager.createScreenCaptureIntent()  （用户在 Activity 里授权）
 *     -> MediaProjection.createVirtualDisplay(AUTO_MIRROR, 眼睛那一路 Surface)
 *     -> SurfaceView 在眼镜 display 上显示
 *
 * 华为 VR Glass 的面板是一块 3200x1600 的横屏，左右两半分别是左右眼。这里按
 * 「左右各一份手机画面」摆放，各自建一条 MediaProjection 虚拟屏，保持手机屏幕
 * 的比例居中，避免把竖屏画面横向拉满。
 *
 * 只依赖 `SYSTEM_ALERT_WINDOW`（安装脚本的 appops，或设置里手动给「显示在其他
 * 应用上层」）；不需要 root / LSPosed，也不需要华为 VR 系统服务。
 */
public final class HvrMirrorService extends Service {

    static final String EXTRA_RESULT_CODE = "hvr.resultCode";
    static final String EXTRA_RESULT_DATA = "hvr.resultData";

    private static final String TAG = "HvrMirrorService";
    private static final String CHANNEL_ID = "hvr_cast";
    private static final int NOTIFICATION_ID = 0x48565201;

    private MediaProjection projection;
    private final List<VirtualDisplay> virtualDisplays = new ArrayList<>();
    private WindowManager windowManager;
    private ViewGroup overlay;
    private Presentation presentation;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startInForeground();
        if (intent == null) {
            return START_NOT_STICKY;
        }
        int resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0);
        Intent data = intent.getParcelableExtra(EXTRA_RESULT_DATA);
        if (projection == null && resultCode != 0 && data != null) {
            MediaProjectionManager manager =
                    (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
            if (manager == null) {
                Log.w(TAG, "MediaProjectionManager unavailable");
                stopSelf();
                return START_NOT_STICKY;
            }
            try {
                projection = manager.getMediaProjection(resultCode, data);
                projection.registerCallback(new MediaProjection.Callback() {
                    @Override
                    public void onStop() {
                        Log.i(TAG, "projection stopped by the system");
                        stopSelf();
                    }
                }, new Handler(Looper.getMainLooper()));
            } catch (Throwable error) {
                Log.w(TAG, "getMediaProjection failed: " + error);
                stopSelf();
                return START_NOT_STICKY;
            }
        }
        if (projection == null) {
            Log.w(TAG, "no projection token");
            stopSelf();
            return START_NOT_STICKY;
        }
        showMirror();
        return START_NOT_STICKY;
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
        builder.setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentTitle("VR 投屏")
                .setContentText("正在把手机屏幕投射到眼镜")
                .setOngoing(true);
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
        final Display display = HvrPanelFinder.find(this);
        if (display == null) {
            Log.w(TAG, "no external display; " + HvrPanelFinder.describeAll(this));
            Toast.makeText(this, "未找到眼镜副屏，投屏停止", Toast.LENGTH_LONG).show();
            stopSelf();
            return;
        }
        final Context displayContext = createDisplayContext(display);
        final DisplayMetrics panelMetrics = new DisplayMetrics();
        display.getRealMetrics(panelMetrics);
        final int panelWidth = Math.max(1, panelMetrics.widthPixels);
        final int panelHeight = Math.max(1, panelMetrics.heightPixels);
        final int densityDpi = panelMetrics.densityDpi > 0
                ? panelMetrics.densityDpi : DisplayMetrics.DENSITY_DEFAULT;

        DisplayMetrics phoneMetrics = new DisplayMetrics();
        try {
            DisplayManager manager =
                    (DisplayManager) getSystemService(DISPLAY_SERVICE);
            Display phone = manager == null ? null
                    : manager.getDisplay(Display.DEFAULT_DISPLAY);
            if (phone != null) {
                phone.getRealMetrics(phoneMetrics);
            }
        } catch (Throwable error) {
            Log.w(TAG, "cannot read the phone display metrics: " + error);
        }
        int phoneWidth = Math.max(1, phoneMetrics.widthPixels);
        int phoneHeight = Math.max(1, phoneMetrics.heightPixels);
        if (phoneMetrics.widthPixels <= 0 || phoneMetrics.heightPixels <= 0) {
            phoneWidth = panelWidth;
            phoneHeight = panelHeight;
        }

        int eyeWidth = Math.max(1, panelWidth / 2);
        int eyeHeight = panelHeight;
        float scale = Math.min((float) eyeWidth / phoneWidth,
                (float) eyeHeight / phoneHeight);
        final int viewWidth = Math.max(1, Math.round(phoneWidth * scale));
        final int viewHeight = Math.max(1, Math.round(phoneHeight * scale));

        LinearLayout row = new LinearLayout(displayContext);
        row.setOrientation(LinearLayout.HORIZONTAL);
        for (int eye = 0; eye < 2; eye++) {
            FrameLayout cell = new FrameLayout(displayContext);
            LinearLayout.LayoutParams cellParams = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.MATCH_PARENT, 1f);
            SurfaceView view = new SurfaceView(displayContext);
            FrameLayout.LayoutParams viewParams = new FrameLayout.LayoutParams(
                    viewWidth, viewHeight, Gravity.CENTER);
            cell.addView(view, viewParams);
            row.addView(cell, cellParams);
            view.getHolder().addCallback(new SurfaceHolder.Callback() {
                @Override
                public void surfaceCreated(SurfaceHolder holder) {
                    createMirror(holder.getSurface(), viewWidth, viewHeight, densityDpi);
                }

                @Override
                public void surfaceChanged(SurfaceHolder holder, int format,
                                           int width, int height) {
                }

                @Override
                public void surfaceDestroyed(SurfaceHolder holder) {
                }
            });
        }

        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.FILL;
        try {
            windowManager = (WindowManager) displayContext.getSystemService(WINDOW_SERVICE);
            windowManager.addView(row, params);
            overlay = row;
            Log.i(TAG, "mirror overlay shown on display " + display.getDisplayId()
                    + " (" + display.getName() + ") " + panelWidth + "x" + panelHeight
                    + ", eye " + viewWidth + "x" + viewHeight);
            Toast.makeText(this, "投屏中：" + display.getName(),
                    Toast.LENGTH_SHORT).show();
        } catch (Throwable error) {
            Log.w(TAG, "overlay rejected (" + error + "), trying a Presentation");
            Toast.makeText(this, "悬浮窗被拒绝，尝试 Presentation",
                    Toast.LENGTH_SHORT).show();
            overlay = null;
            showPresentation(displayContext, display, row);
        }
    }

    private void showPresentation(Context displayContext, Display display, ViewGroup content) {
        try {
            Presentation window = new Presentation(displayContext, display);
            window.setContentView(content);
            window.setOnDismissListener(dialog -> {
                Log.i(TAG, "mirror presentation dismissed");
                presentation = null;
                stopSelf();
            });
            window.show();
            presentation = window;
            Log.i(TAG, "mirror presentation shown on display " + display.getDisplayId());
            Toast.makeText(this, "投屏中（Presentation）：" + display.getName(),
                    Toast.LENGTH_SHORT).show();
        } catch (Throwable error) {
            Log.w(TAG, "presentation failed, cannot mirror: " + error);
            Toast.makeText(this, "无法显示到眼镜：" + error, Toast.LENGTH_LONG).show();
            stopSelf();
        }
    }

    private void createMirror(Surface surface, int width, int height, int dpi) {
        if (projection == null || surface == null || !surface.isValid()) {
            return;
        }
        try {
            VirtualDisplay display = projection.createVirtualDisplay(
                    "HW-VR-Cast-" + virtualDisplays.size(), width, height, dpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    surface, null, null);
            virtualDisplays.add(display);
            Log.i(TAG, "mirror virtual display " + width + "x" + height + " created");
        } catch (Throwable error) {
            Log.w(TAG, "createVirtualDisplay failed: " + error);
        }
    }

    @Override
    public void onDestroy() {
        for (VirtualDisplay display : virtualDisplays) {
            try {
                display.release();
            } catch (Throwable error) {
                Log.w(TAG, "release virtual display failed: " + error);
            }
        }
        virtualDisplays.clear();
        if (presentation != null) {
            try {
                presentation.dismiss();
            } catch (Throwable error) {
                Log.w(TAG, "dismiss presentation failed: " + error);
            }
            presentation = null;
        }
        if (overlay != null && windowManager != null) {
            try {
                windowManager.removeView(overlay);
            } catch (Throwable error) {
                Log.w(TAG, "remove overlay failed: " + error);
            }
        }
        overlay = null;
        if (projection != null) {
            try {
                projection.stop();
            } catch (Throwable error) {
                Log.w(TAG, "stop projection failed: " + error);
            }
        }
        projection = null;
        stopForeground(true);
        super.onDestroy();
    }
}
