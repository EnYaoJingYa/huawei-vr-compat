package com.hvr.shell.pose;

/**
 * 6DOF 管线演示：在 3DOF 姿态上叠加一个前后位移。
 *
 * <p><b>它不是 6DOF 跟踪。</b>{@link #isPositionTracked()} 明确返回 false，
 * UI 也会标成「演示」。它的价值是让渲染端的
 * {@code view = T(-position) · Rᵀ} 这条路径先跑通。</p>
 *
 * <p><b>默认路径不使用它</b>：{@link AutoPoseSource} 只选真 6DOF
 * （{@link Pose6DofSensorSource}）、眼镜 HID 或手机 IMU。它保留下来仅作
 * 渲染管线教学/回放，不要把它接回自动选择，否则又变成“假 6DOF”。</p>
 */
public final class DemoSixDofProvider implements SixDofProvider {

    private final PoseSource base;
    private volatile long startNs;

    public DemoSixDofProvider(PoseSource base) {
        this.base = base;
    }

    @Override
    public boolean isPositionTracked() {
        return false;
    }

    @Override
    public boolean isAvailable() {
        return base.isAvailable();
    }

    @Override
    public void start() {
        startNs = System.nanoTime();
        base.start();
    }

    @Override
    public void stop() {
        base.stop();
    }

    @Override
    public void recenter() {
        base.recenter();
    }

    @Override
    public void getPose(Pose out) {
        base.getPose(out);
        applyDemoPosition(out);
    }

    @Override
    public void predict(Pose out, float deltaSeconds) {
        base.predict(out, deltaSeconds);
        applyDemoPosition(out);
    }

    @Override
    public String name() {
        return "6DOF 演示位移（非真实跟踪）";
    }

    private void applyDemoPosition(Pose out) {
        double seconds = (System.nanoTime() - startNs) / 1e9;
        out.position[0] = 0f;
        out.position[1] = 0f;
        out.position[2] = (float) (Math.sin(seconds * 0.7) * 1.2);
        out.hasPosition = true;
    }
}
