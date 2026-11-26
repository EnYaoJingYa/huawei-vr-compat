package com.hvr.shell.pose;

import android.content.Context;

import com.hvr.shell.render.HomeScene;

/**
 * 姿态源与桌面场景的全局单例。
 *
 * <p>为什么共享：桌面画面可能同时出现在三个地方——手机上的 Activity 预览、
 * 眼镜屏上的 Activity 直出、以及<strong>前台服务直接挂到眼镜屏的 Presentation
 * （绕 EMUI 门禁的兜底路径）</strong>。三处渲染器必须读同一份姿态和同一份
 * 桌面内容，否则手机上滑一下、眼镜里指针不动。</p>
 *
 * <p>所有组件（Activity / Service / Overlay）都从这里拿同一实例，不再各自 new。
 * 底层源对多路监听本就安全：手机传感器监听可重复注册，HID 节点按
 * {@code isAvailable()} 自动降级。</p>
 */
public final class PoseHub {

    private static volatile AutoPoseSource source;
    private static final HomeScene SCENE = new HomeScene();

    /** 姿态源的使用者计数：Activity（前后台）与服务直出（眼镜在位）各自持有一份。 */
    private static int holders;

    private PoseHub() {
    }

    public static AutoPoseSource get(Context context) {
        if (source == null) {
            synchronized (PoseHub.class) {
                if (source == null) {
                    Context app = context.getApplicationContext();
                    source = new AutoPoseSource(
                            new Pose6DofSensorSource(app),
                            new WalleHidPoseSource(),
                            new PhoneSensorPoseSource(app));
                }
            }
        }
        return source;
    }

    /**
     * 领取一份姿态源并确保它已启动（幂等、计数）。Activity onResume / 服务挂
     * 眼镜屏时调用；离开时调 {@link #release()}。没有计数的话，Activity 一退
     * 后台就会把服务直出正在用的姿态源一起停掉。
     */
    public static void acquire(Context context) {
        synchronized (PoseHub.class) {
            get(context).start();
            holders++;
        }
    }

    /** 归还一份使用权；计数归零才真正停传感器。 */
    public static void release() {
        synchronized (PoseHub.class) {
            if (holders > 0 && --holders == 0 && source != null) {
                source.stop();
            }
        }
    }

    /** 全局共享的桌面场景：所有渲染器读它，内容发布者写它。 */
    public static HomeScene scene() {
        return SCENE;
    }
}
