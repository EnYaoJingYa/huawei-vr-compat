package com.hvr.shell.pose;

import android.util.Log;

/**
 * 自动选择姿态源，UI 不再需要「3DOF / 6DOF」开关。
 *
 * <p>优先级：</p>
 * <ol>
 *   <li>{@link Pose6DofSensorSource}：设备真的暴露了 {@code TYPE_POSE_6DOF}，
 *       这是唯一不依赖第三方 SDK 的真 6DOF 公开 API；</li>
 *   <li>{@link WalleHidPoseSource}：能读 {@code /dev/hwvr1} 时用眼镜 IMU（3DOF）；</li>
 *   <li>{@link PhoneSensorPoseSource}：手机 IMU（3DOF）。</li>
 * </ol>
 *
 * <p>眼镜插拔、{@code /dev/hwvr1} 出现/消失时调用 {@link #refresh()} 即可热切换。
 * 如果设备没有 6DOF 传感器，就老老实实输出 3DOF，不拿 IMU 积分伪造位置。</p>
 */
public final class AutoPoseSource implements SixDofProvider {

    private static final String TAG = "AutoPoseSource";

    private final Pose6DofSensorSource sixDof;
    private final WalleHidPoseSource hid;
    private final PhoneSensorPoseSource phone;

    private volatile PoseSource delegate;
    private boolean running;

    public AutoPoseSource(Pose6DofSensorSource sixDof,
                          WalleHidPoseSource hid,
                          PhoneSensorPoseSource phone) {
        this.sixDof = sixDof;
        this.hid = hid;
        this.phone = phone;
        delegate = choose();
    }

    /**
     * 重新探测。显示设备变化（眼镜插拔）时调用；如果选中的源没变就什么也不做。
     */
    public synchronized void refresh() {
        PoseSource next = choose();
        PoseSource old = delegate;
        if (next == old) {
            return;
        }
        if (running && old != null) {
            old.stop();
        }
        delegate = next;
        if (running && next != null) {
            next.start();
        }
        Log.i(TAG, "姿态源切换: " + (old == null ? "null" : old.name())
                + " -> " + (next == null ? "null" : next.name()));
    }

    @Override
    public boolean isPositionTracked() {
        PoseSource current = delegate;
        return current instanceof SixDofProvider
                && ((SixDofProvider) current).isPositionTracked();
    }

    @Override
    public boolean isAvailable() {
        PoseSource current = delegate;
        return current != null && current.isAvailable();
    }

    @Override
    public synchronized void start() {
        if (running) {
            return;
        }
        PoseSource next = choose();
        if (next != delegate) {
            delegate = next;
        }
        if (next != null) {
            next.start();
        }
        running = true;
    }

    @Override
    public synchronized void stop() {
        PoseSource current = delegate;
        if (running && current != null) {
            current.stop();
        }
        running = false;
    }

    @Override
    public void recenter() {
        PoseSource current = delegate;
        if (current != null) {
            current.recenter();
        }
    }

    @Override
    public void getPose(Pose out) {
        PoseSource current = delegate;
        if (current == null) {
            out.reset();
            return;
        }
        current.getPose(out);
    }

    @Override
    public void predict(Pose out, float deltaSeconds) {
        PoseSource current = delegate;
        if (current == null) {
            out.reset();
            return;
        }
        current.predict(out, deltaSeconds);
    }

    @Override
    public String name() {
        PoseSource current = delegate;
        return current == null ? "无姿态源" : current.name();
    }

    private PoseSource choose() {
        if (sixDof != null && sixDof.isAvailable()) {
            return sixDof;
        }
        if (hid != null && hid.isAvailable()) {
            return hid;
        }
        return phone;
    }
}
