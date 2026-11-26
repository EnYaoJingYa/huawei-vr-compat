package dev.vrdemo.posedriver.pose;

/**
 * 姿态源。渲染端只依赖这个接口，因此 3DOF、HID、6DOF 可以互换。
 */
public interface PoseSource {

    boolean isAvailable();

    void start();

    void stop();

    /** 把当前朝向记为「正前方」。 */
    void recenter();

    /** 位置是否来自真实跟踪。默认 false（3DOF，仅旋转）。 */
    default boolean isPositionTracked() {
        return false;
    }

    /** 取最新姿态。实现必须保证 out 被完整写入。 */
    void getPose(Pose out);

    /**
     * 取「再过 deltaSeconds 秒」的预测姿态。
     * 对应原厂 {@code VrPoseState::predictPose(double)} 的用途：光子时间外推。
     */
    void predict(Pose out, float deltaSeconds);

    String name();
}
