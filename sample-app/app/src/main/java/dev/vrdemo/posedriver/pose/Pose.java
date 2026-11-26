package dev.vrdemo.posedriver.pose;

/**
 * 一帧姿态快照。
 *
 * <p>{@link #orientation} 是「机体 → 渲染世界」的四元数（w-first，Y-up，-Z 向前），
 * 已经过 {@link HeadPoseFusion} 的坐标重映射与 recenter。渲染端可以直接
 * {@code orientation.toMatrix(...)} 后转置得到 view 矩阵。</p>
 *
 * <p>{@link #position} 是相机在世界坐标中的位置，单位米，只在
 * {@link #hasPosition} 为真时有意义。3DOF 永远是 {@code false}。</p>
 */
public final class Pose {

    public final Quat orientation = new Quat();
    public final float[] position = new float[3];
    /** 机体角速度，rad/s，用于预测外推。 */
    public final float[] angularVelocity = new float[3];
    public long timestampNs;
    public boolean hasPosition;

    public void set(Pose other) {
        orientation.set(other.orientation);
        System.arraycopy(other.position, 0, position, 0, 3);
        System.arraycopy(other.angularVelocity, 0, angularVelocity, 0, 3);
        timestampNs = other.timestampNs;
        hasPosition = other.hasPosition;
    }

    public void reset() {
        orientation.setIdentity();
        position[0] = position[1] = position[2] = 0f;
        angularVelocity[0] = angularVelocity[1] = angularVelocity[2] = 0f;
        timestampNs = 0L;
        hasPosition = false;
    }
}
