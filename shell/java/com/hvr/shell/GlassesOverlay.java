package com.hvr.shell;

import android.app.Presentation;
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Color;
import android.hardware.display.DisplayManager;
import android.opengl.GLSurfaceView;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.view.SurfaceView;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.hvr.shell.cast.DisplayFinder;
import com.hvr.shell.pose.PoseHub;
import com.hvr.shell.render.LensProfile;
import com.hvr.shell.render.StereoRenderer;

/**
 * 服务直驱的眼镜屏输出——<b>绕 EMUI 启动门禁的兜底路径</b>。
 *
 * <p>背景：华为的门禁 {@code HwVrServiceManager.isAbleToLaunchInVr} 只拦
 * <strong>Activity 启动</strong>（vr_system 未注册时，VR 模式下一切 Activity
 * 都被吞）。而 Presentation 是<strong>窗口</strong>，不是 Activity——它由应用
 * 直接 WindowManager.addView 到指定显示器，整个启动门禁代码路径根本不会执行。</p>
 *
 * <p>典型时序：眼镜插着但华为栈死锁（vrservice stopped、vr_system 没人注册）
 * 时，本类把双目 GL 桌面直接挂到眼镜屏；同时手机屏上若有 Activity，它的
 * 触控板照常工作（共享 {@link PoseHub} 的姿态与场景，两处画面实时同步）。</p>
 *
 * <p>窗口类型兜底：默认 Presentation 自带 TYPE_PRESENTATION；个别 ROM 对
 * 非 Activity 宿主拒绝该类型时，降级为 TYPE_APPLICATION_OVERLAY
 * （需 SYSTEM_ALERT_WINDOW，清单里已声明）。</p>
 */
public final class GlassesOverlay {

    private static volatile GlassesOverlay instance;

    /** 单例：同时最多一个眼镜输出窗口，Activity 与 Service 共享状态避免重复挂载。 */
    public static GlassesOverlay get() {
        if (instance == null) {
            synchronized (GlassesOverlay.class) {
                if (instance == null) {
                    instance = new GlassesOverlay();
                }
            }
        }
        return instance;
    }

    private Presentation presentation;
    private GLSurfaceView panelView;
    private int shownDisplayId = -1;

    private GlassesOverlay() {
    }

    /** 当前是否有服务级窗口挂在眼镜屏上（Activity 判断是否需要自己挂窗口用）。 */
    public synchronized boolean isShowing() {
        return presentation != null;
    }

    public synchronized boolean show(Context context, Display display, String reason) {
        if (display == null) {
            hide();
            return false;
        }
        if (presentation != null && shownDisplayId == display.getDisplayId()) {
            return true; // 已在同一块屏上，避免反复重建
        }
        hide();

        Context displayContext = context.createDisplayContext(display);
        panelView = new GLSurfaceView(displayContext);
        panelView.setEGLContextClientVersion(2);
        panelView.setPreserveEGLContextOnPause(true);
        com.hvr.shell.render.StereoRenderer renderer = new com.hvr.shell.render.StereoRenderer(
                PoseHub.get(context), LensProfile.GENERIC_BARREL,
                com.hvr.shell.render.StereoRenderer.MODE_STEREO, PoseHub.scene());
        // HUD 模式：面板永远锁在视线正前方（r12）。世界锁定在 3DOF + 插拔
        // 重锚定下会「面板丢在身后」（用户实测），等旋转校准稳定后再评估恢复。
        // 姿态源最差也有手机 IMU 兜底。
        renderer.setHeadLock(true);
        // 左右眼旋转/交换：套用上次校准保存的值（r10 起手机端可实时调）。
        EyeCalibration.apply(context, renderer);
        panelView.setRenderer(renderer);
        // 服务是姿态源的使用者之一：Activity 退后台不再会把传感器一起停掉。
        PoseHub.acquire(context);
        panelView.setRenderMode(GLSurfaceView.RENDERMODE_CONTINUOUSLY);

        // 注意：这里什么都不做 secure 处理。
        // 实测（对照 vrvirtualscreen 的 HvrMirrorService）：眼镜 HDMI 屏对普通
        // buffer 的 Presentation 直接就能显示；任何 setSecure / FLAG_SECURE
        // 反而让华为合成器输出全黑（r1/r2 的黑屏教训）。

        FrameLayout root = new FrameLayout(displayContext);
        root.addView(panelView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        TextView osd = new TextView(displayContext);
        osd.setText("HVR 桌面（服务直出）\n" + reason);
        osd.setTextColor(Color.WHITE);
        osd.setTextSize(24f);
        osd.setBackgroundColor(0x44000000);
        root.addView(osd, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        final Presentation created = new Presentation(displayContext, display);
        // 保持与 HvrMirrorService 完全一致的朴素写法，不加任何 flag。
        created.setContentView(root);
        created.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override
            public void onDismiss(DialogInterface dialog) {
                if (presentation == created) {
                    presentation = null;
                    panelView = null;
                    shownDisplayId = -1;
                }
            }
        });
        try {
            created.show();
        } catch (Throwable first) {
            // 非 Activity 宿主被拒：降级为系统叠加窗口再试一次。
            try {
                created.dismiss();
            } catch (Throwable ignored) {
                // 已关闭
            }
            try {
                created.getWindow().setType(
                        android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY);
                created.show();
                ShellState.event("overlay 降级为 APPLICATION_OVERLAY 成功");
            } catch (Throwable second) {
                ShellState.event("服务直出眼镜屏失败", second);
                presentation = null;
                panelView = null;
                shownDisplayId = -1;
                return false;
            }
        }
        presentation = created;
        panelView.onResume();
        shownDisplayId = display.getDisplayId();
        // 服务直出也要有桌面内容：加载已钉应用并发布一帧面板位图。
        // Activity 没跑时这里是唯一的内容来源；Activity 在跑时是同一份状态，幂等。
        try {
            DesktopPresenter.get().ensureLoaded(context);
        } catch (Throwable error) {
            ShellState.event("桌面内容发布失败", error);
        }
        ShellState.event("桌面已由服务直接挂到 " + DisplayFinder.describe(display));
        return true;
    }

    public synchronized void hide() {
        GLSurfaceView currentPanel = panelView;
        Presentation current = presentation;
        presentation = null;
        panelView = null;
        shownDisplayId = -1;
        PoseHub.release();
        if (currentPanel != null) {
            try {
                currentPanel.onPause();
            } catch (Throwable ignored) {
                // 上下文已销毁
            }
        }
        if (current != null) {
            try {
                current.dismiss();
            } catch (Throwable ignored) {
                // 已经关闭
            }
        }
    }

    /** 显示器被移除时 DisplayManager 可能已把 Presentation 自动 dismiss，这里兜底清理。 */
    public synchronized void onDisplayRemoved(int displayId) {
        if (shownDisplayId == displayId || displayId == -1) {
            hide();
        }
    }

    /** 供 Service 在显示器事件里查询（避免直接依赖 DisplayManager 实例）。 */
    public static Display findGlasses(Context context) {
        return DisplayFinder.find(context);
    }

    static boolean isPresentationDisplay(DisplayManager manager, Display display) {
        return display != null && display.isValid()
                && display.getDisplayId() != Display.DEFAULT_DISPLAY;
    }
}
