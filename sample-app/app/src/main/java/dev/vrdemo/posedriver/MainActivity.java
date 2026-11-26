package dev.vrdemo.posedriver;

import android.Manifest;
import android.app.Activity;
import android.app.Presentation;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.hardware.display.DisplayManager;
import android.media.projection.MediaProjectionManager;
import android.opengl.GLSurfaceView;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Display;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import dev.vrdemo.posedriver.cast.DisplayFinder;
import dev.vrdemo.posedriver.cast.MirrorService;
import dev.vrdemo.posedriver.pose.AutoPoseSource;
import dev.vrdemo.posedriver.pose.PhoneSensorPoseSource;
import dev.vrdemo.posedriver.pose.Pose6DofSensorSource;
import dev.vrdemo.posedriver.pose.WalleHidPoseSource;
import dev.vrdemo.posedriver.render.LensProfile;
import dev.vrdemo.posedriver.render.StereoRenderer;

/**
 * 控制台。
 *
 * <p>手机屏显示按钮 + 单眼预览；眼镜副屏上是一个 {@link Presentation}，
 * 里面跑双目 {@link StereoRenderer}。</p>
 *
 * <p>启动后会自动做两件事：</p>
 * <ol>
 *   <li>{@link AutoPoseSource} 探测姿态源：真 6DOF（{@code TYPE_POSE_6DOF}）
 *       → 眼镜 HID 3DOF → 手机 IMU 3DOF；</li>
 *   <li>如果已经接着扩展屏/眼镜，自动创建 {@link Presentation} 开始双目输出；
 *       插拔时通过 {@link DisplayManager} 自动跟随。</li>
 * </ol>
 *
 * <p>MediaProjection 投屏无法全自动：Android 要求每次由用户点系统录屏授权，
 * 这是安全限制，不是本 App 的取舍。</p>
 *
 * <p>为什么用 Activity 持有 Presentation 而不是 Service：Activity 在前台时
 * 窗口生命周期最直观，也不需要前台服务类型；代价是 App 退到后台就停止输出。
 * 真要做常驻，把这一段挪进前台服务即可（见 {@link MirrorService}）。</p>
 */
public final class MainActivity extends Activity {

    private static final String TAG = "MainActivity";
    private static final int REQUEST_CAPTURE = 1001;
    private static final int REQUEST_NOTIFICATIONS = 1002;
    /** 自动启动的防抖，避免 display change 回调风暴导致反复 show/toast。 */
    private static final long AUTO_START_THROTTLE_MS = 1500L;

    private TextView status;
    private GLSurfaceView preview;

    private PhoneSensorPoseSource phoneSource;
    private WalleHidPoseSource hidSource;
    private Pose6DofSensorSource sixDofSource;
    private AutoPoseSource activeSource;

    private DisplayManager displayManager;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private boolean autoOutputEnabled = true;
    private long lastAutoStartAttemptMs;

    private MediaProjectionManager projectionManager;
    private Presentation presentation;
    private GLSurfaceView panelView;

    private final Runnable autoStartRunnable = new Runnable() {
        @Override
        public void run() {
            maybeAutoStart();
        }
    };

    private final DisplayManager.DisplayListener displayListener =
            new DisplayManager.DisplayListener() {
                @Override
                public void onDisplayAdded(int displayId) {
                    onDisplaysChanged();
                }

                @Override
                public void onDisplayChanged(int displayId) {
                    onDisplaysChanged();
                }

                @Override
                public void onDisplayRemoved(int displayId) {
                    onDisplaysChanged();
                }
            };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        projectionManager = (MediaProjectionManager)
                getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        displayManager = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);

        phoneSource = new PhoneSensorPoseSource(this);
        hidSource = new WalleHidPoseSource();
        sixDofSource = new Pose6DofSensorSource(this);
        // 6DOF -> 眼镜 HID -> 手机 IMU，全部自动，不需要 UI 开关。
        activeSource = new AutoPoseSource(sixDofSource, hidSource, phoneSource);

        buildUi();

        preview.setEGLContextClientVersion(2);
        preview.setPreserveEGLContextOnPause(true);
        preview.setRenderer(new StereoRenderer(activeSource, LensProfile.NONE,
                StereoRenderer.MODE_MONO));
        preview.setRenderMode(GLSurfaceView.RENDERMODE_CONTINUOUSLY);

        if (!activeSource.isAvailable()) {
            toast("没有可用的姿态传感器");
        }
        updateStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        activeSource.start();
        preview.onResume();

        if (panelView != null) {
            if (DisplayFinder.find(this) == null) {
                dismissPresentation();
            } else {
                panelView.onResume();
            }
        }

        if (displayManager != null) {
            displayManager.registerDisplayListener(displayListener, mainHandler);
        }
        preview.removeCallbacks(autoStartRunnable);
        preview.postDelayed(autoStartRunnable, 350L);
        updateStatus();
    }

    @Override
    protected void onPause() {
        preview.removeCallbacks(autoStartRunnable);
        if (displayManager != null) {
            displayManager.unregisterDisplayListener(displayListener);
        }
        if (panelView != null) {
            panelView.onPause();
        }
        preview.onPause();
        activeSource.stop();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        preview.removeCallbacks(autoStartRunnable);
        if (displayManager != null) {
            try {
                displayManager.unregisterDisplayListener(displayListener);
            } catch (Throwable ignored) {
                // 已经注销过
            }
        }
        dismissPresentation();
        activeSource.stop();
        stopService(new Intent(this, MirrorService.class));
        super.onDestroy();
    }

    // ---------------------------------------------------------------- UI

    private void buildUi() {
        int pad = dp(12);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xFF101014);
        root.setPadding(pad, pad, pad, pad);

        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(13f);
        status.setLineSpacing(0f, 1.15f);
        root.addView(status, matchWrap());

        LinearLayout first = new LinearLayout(this);
        first.setOrientation(LinearLayout.HORIZONTAL);
        first.setPadding(0, pad, 0, 0);
        Button stereo = makeButton("开始立体输出");
        stereo.setOnClickListener(view -> startStereo());
        Button recenter = makeButton("重定位");
        recenter.setOnClickListener(view -> {
            activeSource.recenter();
            toast(activeSource.isPositionTracked()
                    ? "已把当前朝向和位置记为零点"
                    : "已把当前朝向记为正前方");
        });
        first.addView(stereo, weight());
        first.addView(recenter, weight());
        root.addView(first, matchWrap());

        LinearLayout second = new LinearLayout(this);
        second.setOrientation(LinearLayout.HORIZONTAL);
        Button cast = makeButton("投屏到眼镜");
        cast.setOnClickListener(view -> startCast());
        Button stop = makeButton("停止输出");
        stop.setOnClickListener(view -> stopOutput());
        second.addView(cast, weight());
        second.addView(stop, weight());
        root.addView(second, matchWrap());

        preview = new GLSurfaceView(this);
        LinearLayout.LayoutParams previewParams =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        previewParams.topMargin = pad;
        root.addView(preview, previewParams);

        setContentView(root);
    }

    private Button makeButton(String text) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        return button;
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams weight() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    // ---------------------------------------------------------------- 自动输出

    private void onDisplaysChanged() {
        runOnUiThread(() -> {
            if (isFinishing() || isDestroyed()) {
                return;
            }
            // 眼镜插拔时 /dev/hwvr1 可能随之出现/消失，顺便重新选姿态源。
            activeSource.refresh();
            if (DisplayFinder.find(this) == null) {
                lastAutoStartAttemptMs = 0L;
                if (presentation != null) {
                    dismissPresentation();
                }
            } else if (autoOutputEnabled && panelView == null) {
                maybeAutoStart();
            }
            updateStatus();
        });
    }

    private void maybeAutoStart() {
        if (!autoOutputEnabled || panelView != null || isFinishing() || isDestroyed()) {
            return;
        }
        if (DisplayFinder.find(this) == null) {
            return;
        }
        long now = SystemClock.elapsedRealtime();
        if (now - lastAutoStartAttemptMs < AUTO_START_THROTTLE_MS) {
            return;
        }
        lastAutoStartAttemptMs = now;
        startStereo();
    }

    // ---------------------------------------------------------------- 动作

    private void startStereo() {
        autoOutputEnabled = true;
        Display display = DisplayFinder.find(this);
        if (display == null) {
            updateStatus();
            toast("未找到眼镜副屏");
            return;
        }

        dismissPresentation();

        Context displayContext = createDisplayContext(display);
        panelView = new GLSurfaceView(displayContext);
        panelView.setEGLContextClientVersion(2);
        panelView.setPreserveEGLContextOnPause(true);
        panelView.setRenderer(new StereoRenderer(activeSource, LensProfile.GENERIC_BARREL,
                StereoRenderer.MODE_STEREO));
        panelView.setRenderMode(GLSurfaceView.RENDERMODE_CONTINUOUSLY);

        final Presentation created = new Presentation(displayContext, display);
        created.setContentView(panelView);
        created.setOnDismissListener(dialog -> {
            if (presentation == created) {
                presentation = null;
                panelView = null;
                updateStatus();
            }
        });
        presentation = created;

        try {
            created.show();
            // 这块 GLSurfaceView 是在 Activity 已经 resume 之后才创建的，
            // 必须手动补一次 onResume() 才会进入正常的渲染循环。
            panelView.onResume();
            Log.i(TAG, "立体输出已显示到 " + DisplayFinder.describe(display));
        } catch (Throwable error) {
            Log.w(TAG, "Presentation.show 失败: " + error);
            dismissPresentation();
            toast("无法在副屏显示：" + error);
            return;
        }
        updateStatus();
    }

    private void stopOutput() {
        autoOutputEnabled = false;
        preview.removeCallbacks(autoStartRunnable);
        dismissPresentation();
        stopService(new Intent(this, MirrorService.class));
        updateStatus();
        toast("已停止自动输出");
    }

    private void dismissPresentation() {
        Presentation current = presentation;
        presentation = null;
        GLSurfaceView currentPanel = panelView;
        panelView = null;
        if (currentPanel != null) {
            try {
                currentPanel.onPause();
            } catch (Throwable error) {
                Log.w(TAG, "暂停副屏 GL 失败: " + error);
            }
        }
        if (current != null) {
            try {
                current.dismiss();
            } catch (Throwable error) {
                Log.w(TAG, "dismiss 失败: " + error);
            }
        }
    }

    private void startCast() {
        if (projectionManager == null) {
            toast("系统没有 MediaProjectionManager");
            return;
        }
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},
                    REQUEST_NOTIFICATIONS);
        }
        try {
            startActivityForResult(projectionManager.createScreenCaptureIntent(), REQUEST_CAPTURE);
        } catch (Throwable error) {
            toast("无法发起录屏授权：" + error);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_CAPTURE) {
            return;
        }
        if (resultCode != RESULT_OK || data == null) {
            toast("未授权录屏");
            return;
        }
        Intent service = new Intent(this, MirrorService.class)
                .putExtra(MirrorService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(MirrorService.EXTRA_RESULT_DATA, data);
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(service);
        } else {
            startService(service);
        }
        toast("开始投屏，请把眼镜作为扩展屏");
    }

    private void updateStatus() {
        Display display = DisplayFinder.find(this);
        StringBuilder text = new StringBuilder();
        text.append("姿态源：").append(activeSource.name()).append('\n');
        text.append("跟踪模式：")
                .append(activeSource.isPositionTracked()
                        ? "6DOF（位置 + 旋转）"
                        : "3DOF（仅旋转）")
                .append('\n');
        text.append("副屏：").append(DisplayFinder.describe(display)).append('\n');
        text.append("手机上的画面是单眼预览；眼镜里是双目 + 畸变。\n");

        if (display == null) {
            text.append("提示：接上眼镜扩展屏后会自动开始；也可点「开始立体输出」。\n");
            if (!activeSource.isPositionTracked()) {
                text.append("本机没有暴露 TYPE_POSE_6DOF，已自动使用 3DOF。");
            }
        } else if (panelView == null) {
            text.append("提示：已找到副屏，等待自动开始，或点「开始立体输出」。\n");
            text.append(activeSource.isPositionTracked()
                    ? "戴上后点「重定位」把当前朝向和位置清零。"
                    : "戴上后点「重定位」把当前朝向清零。");
        } else {
            text.append("状态：已输出到副屏。\n");
            text.append(activeSource.isPositionTracked()
                    ? "戴上后点「重定位」把当前朝向和位置清零。"
                    : "戴上后点「重定位」把当前朝向清零。");
        }
        status.setText(text);
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }
}
