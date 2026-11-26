package dev.vrdemo.posedriver.pose;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.util.Log;

/**
 * Android 公开 API 的 6DOF 姿态源：{@link Sensor#TYPE_POSE_6DOF}（API 24+）。
 *
 * <p>它不是华为的 VIO/SLAM。设备厂商若实现了这个 sensor HAL，系统会直接给出
 * 带位置的四元数；没有这个传感器的手机（包括多数华为手机）根本不会出现在
 * {@link SensorManager#getDefaultSensor(int)} 里，此时由
 * {@link AutoPoseSource} 自动回退到 3DOF。</p>
 *
 * <p>事件值（Android 标准）：</p>
 * <pre>
 *   values[0..2] 姿态四元数的 x,y,z
 *   values[3]    姿态四元数的 w
 *   values[4..6] 平移 x,y,z，单位米，原点由设备厂商定义
 *   values[7..10] 相对上一帧的增量四元数 x,y,z,w（本类不用）
 *   values[11..13] 相对上一帧的增量平移（本类不用）
 * </pre>
 *
 * <p><b>坐标</b>：四元数仍是「设备 → 传感器世界」。厂商的 world frame 没有统一
 * 规定，可能是 ENU（Z-up），也可能是 ARCore 那种 Y-up。本类启动时读取
 * {@link Sensor#TYPE_GRAVITY}，用第一帧姿态把「测得的上方向」对齐到渲染的 +Y，
 * 再乘以 {@link #recenter} 的 yaw 偏移。拿不到重力时退回
 * {@code Rx(-90°)}（ENU 假设）。</p>
 *
 * <p><b>位置</b>：平移是「从任意原点出发」的米制量。recenter 会把它清零，
 * 因此只影响相对走动，不依赖厂商原点的绝对位置。</p>
 */
public final class Pose6DofSensorSource implements SixDofProvider, SensorEventListener {

    private static final String TAG = "Pose6Dof";
    private static final int SAMPLE_PERIOD_US = 10_000;   // 100 Hz

    private final SensorManager sensorManager;
    private final Sensor poseSensor;
    private final Sensor gravitySensor;

    /** 设备 → 传感器世界。 */
    private final Quat q = new Quat();
    private final Quat previous = new Quat();
    /** 世界系左乘的 yaw 偏移。 */
    private final Quat recenter = new Quat();
    /** 传感器世界 → 渲染 Y-up。启动时用重力自动求，失败则默认 Rx(-90°)。 */
    private final Quat worldToRender = new Quat();

    private final Quat tmpA = new Quat();
    private final Quat tmpB = new Quat();

    private final float[] position = new float[3];
    private final float[] recenterPosition = new float[3];
    private final float[] gravityDevice = new float[3];
    private final float[] tmpVector = new float[3];
    private final float[] tmpVector2 = new float[3];
    private final float[] angularVelocity = new float[3];

    private volatile boolean running;
    private boolean hasPose;
    private boolean hasPrevious;
    private boolean hasGravity;
    private boolean calibrated;
    private long lastTimestampNs;
    private long firstPoseTimestampNs;

    public Pose6DofSensorSource(Context context) {
        SensorManager manager = (SensorManager) context.getApplicationContext()
                .getSystemService(Context.SENSOR_SERVICE);
        sensorManager = manager;
        poseSensor = manager == null ? null
                : manager.getDefaultSensor(Sensor.TYPE_POSE_6DOF);
        gravitySensor = manager == null ? null
                : manager.getDefaultSensor(Sensor.TYPE_GRAVITY);
        worldToRender.setAxisAngle(1f, 0f, 0f, (float) (-Math.PI / 2.0));
        recenter.setIdentity();
    }

    @Override
    public boolean isAvailable() {
        return poseSensor != null;
    }

    @Override
    public boolean isPositionTracked() {
        return true;
    }

    @Override
    public synchronized void start() {
        if (running || sensorManager == null || poseSensor == null) {
            return;
        }
        resetState();
        // 先开重力，让第一帧姿态就能做 auto-level。
        if (gravitySensor != null) {
            sensorManager.registerListener(this, gravitySensor, SAMPLE_PERIOD_US, 0);
        }
        sensorManager.registerListener(this, poseSensor, SAMPLE_PERIOD_US, 0);
        running = true;
    }

    @Override
    public synchronized void stop() {
        if (sensorManager != null) {
            sensorManager.unregisterListener(this);
        }
        running = false;
    }

    @Override
    public synchronized void recenter() {
        if (!hasPose) {
            recenter.setIdentity();
            recenterPosition[0] = recenterPosition[1] = recenterPosition[2] = 0f;
            return;
        }

        tmpA.set(worldToRender);
        Quat.multiply(tmpB, tmpA, q);                 // C · q
        tmpB.rotateVector(0f, 0f, -1f, tmpVector);
        // 正朝上/下看时水平投影接近 0，yaw 没有意义，保持原有 yaw；
        // 但位置仍然要清零，否则厂商的任意原点会把相机抛到场景外。
        if (tmpVector[0] * tmpVector[0] + tmpVector[2] * tmpVector[2] >= 0.01f) {
            float yaw = (float) Math.atan2(tmpVector[0], -tmpVector[2]);
            recenter.setAxisAngle(0f, 1f, 0f, yaw);
        }

        // recenter 后的世界位置 = R_yaw · (C · p)。记下点击时的位置作为原点。
        worldToRender.rotateVector(position[0], position[1], position[2], tmpVector);
        recenter.rotateVector(tmpVector[0], tmpVector[1], tmpVector[2], recenterPosition);
    }

    @Override
    public synchronized void getPose(Pose out) {
        if (!hasPose) {
            out.reset();
            return;
        }

        tmpA.set(worldToRender);
        Quat.multiply(tmpB, tmpA, q);                 // C · q
        Quat.multiply(tmpA, recenter, tmpB);          // R_yaw · C · q
        out.orientation.set(tmpA);
        out.orientation.normalize();

        if (calibrated) {
            worldToRender.rotateVector(position[0], position[1], position[2], tmpVector);
            recenter.rotateVector(tmpVector[0], tmpVector[1], tmpVector[2], tmpVector2);
            out.position[0] = tmpVector2[0] - recenterPosition[0];
            out.position[1] = tmpVector2[1] - recenterPosition[1];
            out.position[2] = tmpVector2[2] - recenterPosition[2];
        } else {
            // 还没完成重力对齐：先按 3DOF 输出，避免厂商的任意原点把相机抛出去。
            out.position[0] = out.position[1] = out.position[2] = 0f;
        }

        out.angularVelocity[0] = angularVelocity[0];
        out.angularVelocity[1] = angularVelocity[1];
        out.angularVelocity[2] = angularVelocity[2];
        out.timestampNs = lastTimestampNs;
        out.hasPosition = calibrated;
    }

    @Override
    public synchronized void predict(Pose out, float deltaSeconds) {
        getPose(out);
        if (deltaSeconds <= 1e-4f || !out.hasPosition) {
            return;
        }
        // 位置预测需要速度；TYPE_POSE_6DOF 的标准事件没有直接给速度，
        // 这里只外推旋转（10ms 的位置滞后对行走速度只有约 1.5cm）。
        float gx = angularVelocity[0];
        float gy = angularVelocity[1];
        float gz = angularVelocity[2];
        float omega = (float) Math.sqrt(gx * gx + gy * gy + gz * gz);
        if (omega < 1e-5f) {
            return;
        }
        tmpA.setAxisAngle(gx, gy, gz, omega * deltaSeconds);
        Quat.multiply(tmpB, out.orientation, tmpA);
        out.orientation.set(tmpB);
        out.orientation.normalize();
    }

    @Override
    public String name() {
        return "设备 6DOF（TYPE_POSE_6DOF）";
    }

    @Override
    public synchronized void onSensorChanged(SensorEvent event) {
        if (event == null || event.sensor == null || event.values == null) {
            return;
        }
        if (event.sensor.getType() == Sensor.TYPE_GRAVITY) {
            if (event.values.length < 3) {
                return;
            }
            gravityDevice[0] = event.values[0];
            gravityDevice[1] = event.values[1];
            gravityDevice[2] = event.values[2];
            hasGravity = true;
            maybeCalibrate();
            return;
        }
        if (event.sensor != poseSensor || event.values.length < 7) {
            return;
        }

        float[] v = event.values;
        // Android: (x,y,z,w) -> 内部: (w,x,y,z)
        q.set(v[3], v[0], v[1], v[2]);
        q.normalize();
        position[0] = v[4];
        position[1] = v[5];
        position[2] = v[6];

        if (hasPrevious && lastTimestampNs > 0L) {
            float dt = (event.timestamp - lastTimestampNs) * 1e-9f;
            if (dt > 1e-4f && dt < 0.25f) {
                tmpA.set(previous);
                tmpA.conjugate();
                Quat.multiply(tmpB, tmpA, q);
                if (tmpB.w < 0f) {
                    tmpB.w = -tmpB.w;
                    tmpB.x = -tmpB.x;
                    tmpB.y = -tmpB.y;
                    tmpB.z = -tmpB.z;
                }
                float scale = 2f / dt;
                angularVelocity[0] = tmpB.x * scale;
                angularVelocity[1] = tmpB.y * scale;
                angularVelocity[2] = tmpB.z * scale;
            }
        }

        previous.set(q);
        hasPrevious = true;
        lastTimestampNs = event.timestamp;
        hasPose = true;

        if (firstPoseTimestampNs == 0L) {
            firstPoseTimestampNs = event.timestamp;
        }
        maybeCalibrate();
        // 重力传感器通常几毫秒内就有数据；如果它存在但一直不来，
        // 500ms 后按默认 ENU 假设起步，至少保证初次画面和位置是居中的。
        if (!calibrated && (gravitySensor == null
                || event.timestamp - firstPoseTimestampNs > 500_000_000L)) {
            calibrated = true;
            recenter();
        }
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
        // 6DOF sensor 的 tracking state 不在公开 SensorEvent 里；保持最后姿态。
    }

    // ---------------------------------------------------------------- 内部

    /**
     * 用第一帧姿态和重力求「传感器世界 → 渲染 Y-up」的旋转。
     *
     * <p>重力传感器在静止时给出设备坐标里的“上”方向（与加速度计同向）；
     * {@code q · g} 就是它在传感器世界里的方向。把它最短弧转到 +Y 即可。
     * 这样既兼容 Z-up 的 ENU 实现，也兼容 Y-up 的 ARCore 风格实现。</p>
     */
    private void maybeCalibrate() {
        if (calibrated || !hasPose || !hasGravity) {
            return;
        }
        q.rotateVector(gravityDevice[0], gravityDevice[1], gravityDevice[2], tmpVector);
        float length = (float) Math.sqrt(
                tmpVector[0] * tmpVector[0]
                        + tmpVector[1] * tmpVector[1]
                        + tmpVector[2] * tmpVector[2]);
        if (length < 1e-3f) {
            return;
        }
        float ux = tmpVector[0] / length;
        float uy = tmpVector[1] / length;
        float uz = tmpVector[2] / length;

        // cross(up, +Y) = (-uz, 0, ux)
        float cx = -uz;
        float cz = ux;
        float sin = (float) Math.sqrt(cx * cx + cz * cz);
        if (sin < 1e-4f) {
            if (uy >= 0f) {
                worldToRender.setIdentity();
            } else {
                // 上下颠倒：绕 X 转 180°
                worldToRender.set(0f, 1f, 0f, 0f);
            }
        } else {
            float angle = (float) Math.atan2(sin, uy);
            worldToRender.setAxisAngle(cx / sin, 0f, cz / sin, angle);
        }
        calibrated = true;
        if (gravitySensor != null) {
            sensorManager.unregisterListener(this, gravitySensor);
        }
        // 首次对齐后把厂商的任意原点清零，避免相机一开始就在场景外。
        if (hasPose) {
            recenter();
        }
        Log.i(TAG, "auto-level upWorld=(" + ux + ", " + uy + ", " + uz + ")");
    }

    private void resetState() {
        q.setIdentity();
        previous.setIdentity();
        recenter.setIdentity();
        worldToRender.setAxisAngle(1f, 0f, 0f, (float) (-Math.PI / 2.0));
        position[0] = position[1] = position[2] = 0f;
        recenterPosition[0] = recenterPosition[1] = recenterPosition[2] = 0f;
        gravityDevice[0] = gravityDevice[1] = gravityDevice[2] = 0f;
        angularVelocity[0] = angularVelocity[1] = angularVelocity[2] = 0f;
        hasPose = false;
        hasPrevious = false;
        hasGravity = false;
        calibrated = false;
        lastTimestampNs = 0L;
        firstPoseTimestampNs = 0L;
    }
}
