package com.hvr.shell.pose;

/**
 * 6DOF 姿态源契约，渲染端可直接当 {@link PoseSource} 用。
 *
 * <p><b>这不是华为 6DOF 的复刻。</b>原厂是双目鱼眼 + IMU 的 VIO/SLAM
 * （{@code libVR6Dof.so} + {@code libarvr_slam.so}），需要相机内参、LED 布局、
 * IMU 标定，无法靠公开信息还原。这里只是给通用 Android 留的接入点。</p>
 *
 * <p>接 ARCore 时：</p>
 * <pre>
 * Session session = Session(...);
 * Frame frame = session.update();
 * com.google.ar.core.Pose camera = frame.getCamera().getPose(); // Y-up, 朝 -Z
 * Pose out = ...;                        // com.hvr.shell.pose.Pose
 * out.orientation.set(camera.qw(), camera.qx(), camera.qy(), camera.qz());
 * out.position[0] = camera.tx();
 * out.position[1] = camera.ty();
 * out.position[2] = camera.tz();
 * out.hasPosition = frame.getCamera().getTrackingState() == TrackingState.TRACKING;
 * out.timestampNs = frame.getTimestamp();
 * </pre>
 * 注意 ARCore 的平移是「相机在 world 中的位置」，而渲染 view 矩阵要的是
 * {@code T(-position) * Rᵀ}，两者不要混。
 */
public interface SixDofProvider extends PoseSource {

    /** 位置是否来自真实跟踪（而不是演示位移）。 */
    boolean isPositionTracked();
}
