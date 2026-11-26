package dev.vrdemo.posedriver.pose;

/**
 * 可热切换的姿态源。渲染器持有它，UI 切换 3DOF/6DOF 时不需要重建 GL 管线。
 */
public final class SwitchablePoseSource implements PoseSource {

    private volatile PoseSource delegate;

    public SwitchablePoseSource(PoseSource initial) {
        delegate = initial;
    }

    public void set(PoseSource next) {
        delegate = next;
    }

    public PoseSource get() {
        return delegate;
    }

    @Override
    public boolean isPositionTracked() {
        PoseSource current = delegate;
        return current != null && current.isPositionTracked();
    }

    @Override
    public boolean isAvailable() {
        PoseSource current = delegate;
        return current != null && current.isAvailable();
    }

    @Override
    public void start() {
        PoseSource current = delegate;
        if (current != null) {
            current.start();
        }
    }

    @Override
    public void stop() {
        PoseSource current = delegate;
        if (current != null) {
            current.stop();
        }
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
}
