package dev.vrdemo.posedriver.pose;

import android.hardware.SensorManager;

import java.util.Arrays;

/**
 * 3DOF 融合核心，对应原厂 {@code libWalleAlg.so} 里 {@code VrPoseState} 的结构：
 *
 * <pre>
 *   q ← q ⊗ exp(0.5·ω·dt)          陀螺积分（机体角速度右乘）
 *   q ← tiltCorrect(q, accel)      低频把重力方向拉回来（roll/pitch）
 *   q ← yawCorrect(q, mag)         水平面磁北校正（yaw）
 *   q ← normalize(q)
 * </pre>
 *
 * <p>原厂还带磁异常检测、按运动强度调平滑、RLS 等（见文档 §4.3），
 * 这里只实现可验证的最小版本：磁模长异常时直接跳过 yaw 校正，
 * 静止时学习陀螺零偏。</p>
 *
 * <p><b>坐标</b>：内部 {@code q} 是「设备 → ENU」的旋转，与 Android
 * {@code getRotationMatrixFromVector} 的约定一致；输出前再左乘一个固定旋转
 * {@code Rx(-90°)}，把 ENU（Z-up）变成渲染用的 Y-up，并做 yaw recenter。</p>
 */
public final class HeadPoseFusion {

    private static final float GRAVITY = 9.80665f;
    /** 倾角校正增益，1/s。越大跟重力越快，也越容易被线性加速度干扰。 */
    private static final float TILT_GAIN = 1.6f;
    /** 磁 yaw 校正增益，1/s。 */
    private static final float MAG_GAIN = 0.8f;
    private static final float GYRO_STEADY_RAD = 0.05f;
    private static final float ACC_STEADY_MPS2 = 0.4f;
    /** 地磁模长的合理区间（µT），超出视为异常，不做 yaw 校正。 */
    private static final float MAG_MIN_UT = 20f;
    private static final float MAG_MAX_UT = 80f;

    /** ENU → 渲染世界：Rx(-90°)，(x,y,z) → (x,z,-y)。 */
    private final Quat sensorToRender = new Quat();

    private final Quat q = new Quat();          // device -> ENU
    private final Quat recenter = new Quat();   // 世界系左乘的 yaw 偏移
    private final Quat previous = new Quat();
    private final Quat tmpA = new Quat();
    private final Quat tmpB = new Quat();

    private final float[] rotationQuaternion = new float[4];
    private final float[] rotationMatrix = new float[9];
    private final float[] accel = new float[3];
    private final float[] mag = new float[3];
    private final float[] upInDevice = new float[3];
    private final float[] magnitudeWorld = new float[3];
    private final float[] forward = new float[3];
    private final float[] gyroBias = new float[3];
    private final float[] angularVelocity = new float[3];

    private boolean initialized;
    private boolean hasAccel;
    private boolean hasMag;
    private boolean hasPrevious;
    private boolean magReferenceValid;
    private float magReferenceHeading;
    private long lastGyroNs;
    private long lastMagNs;
    private long lastRotationNs;
    private int steadyFrames;
    private int accelSamples;

    public HeadPoseFusion() {
        sensorToRender.setAxisAngle(1f, 0f, 0f, (float) (-Math.PI / 2.0));
        reset();
    }

    public synchronized void reset() {
        q.setIdentity();
        recenter.setIdentity();
        previous.setIdentity();
        Arrays.fill(gyroBias, 0f);
        Arrays.fill(angularVelocity, 0f);
        Arrays.fill(accel, 0f);
        Arrays.fill(mag, 0f);
        initialized = false;
        hasAccel = false;
        hasMag = false;
        hasPrevious = false;
        magReferenceValid = false;
        magReferenceHeading = 0f;
        lastGyroNs = 0L;
        lastMagNs = 0L;
        lastRotationNs = 0L;
        steadyFrames = 0;
        accelSamples = 0;
    }

    // ---------------------------------------------------------------- 系统旋转矢量

    /**
     * 直接采用系统融合结果（{@code TYPE_GAME_ROTATION_VECTOR} /
     * {@code TYPE_ROTATION_VECTOR}）。角速度由相邻两帧四元数差分估计。
     */
    public synchronized void setFromRotationVector(float[] rotationVector, long timestampNs) {
        SensorManager.getQuaternionFromVector(rotationQuaternion, rotationVector);
        // Android: (x, y, z, w) → 内部: (w, x, y, z)
        q.set(rotationQuaternion[3], rotationQuaternion[0],
                rotationQuaternion[1], rotationQuaternion[2]);
        q.normalize();

        if (hasPrevious && lastRotationNs > 0L) {
            float dt = (timestampNs - lastRotationNs) * 1e-9f;
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
        lastRotationNs = timestampNs;
        initialized = true;
    }

    // ---------------------------------------------------------------- 原始传感器

    public synchronized void onAccel(long timestampNs, float ax, float ay, float az) {
        accel[0] = ax;
        accel[1] = ay;
        accel[2] = az;
        hasAccel = true;
        maybeInitialize();
    }

    public synchronized void onMag(long timestampNs, float mx, float my, float mz) {
        mag[0] = mx;
        mag[1] = my;
        mag[2] = mz;
        hasMag = true;
        lastMagNs = timestampNs;
        maybeInitialize();
    }

    /** 陀螺角速度，单位 rad/s，机体坐标。 */
    public synchronized void onGyro(long timestampNs, float gx, float gy, float gz) {
        if (!initialized) {
            lastGyroNs = timestampNs;
            return;
        }
        if (lastGyroNs == 0L) {
            lastGyroNs = timestampNs;
            return;
        }
        float dt = (timestampNs - lastGyroNs) * 1e-9f;
        if (dt <= 0f || dt > 0.2f) {
            lastGyroNs = timestampNs;
            return;
        }
        lastGyroNs = timestampNs;

        updateGyroBias(gx, gy, gz);

        float cx = gx - gyroBias[0];
        float cy = gy - gyroBias[1];
        float cz = gz - gyroBias[2];

        angularVelocity[0] = cx;
        angularVelocity[1] = cy;
        angularVelocity[2] = cz;

        tmpA.setFromAngularVelocity(cx, cy, cz, dt);
        q.postMultiply(tmpA);

        if (hasAccel) {
            correctTilt(dt);
        }
        if (hasMag && timestampNs - lastMagNs < 200_000_000L) {
            correctYaw(dt);
        }
        q.normalize();
    }

    /**
     * 一次 IMU 采样（用于 HID 报文：acc/gyro/mag 同时到达）。
     *
     * @param seconds 设备时间戳，秒
     */
    public synchronized void onImu(float ax, float ay, float az,
                                  float gx, float gy, float gz,
                                  float mx, float my, float mz,
                                  double seconds) {
        long timestampNs = (long) (seconds * 1e9);
        accel[0] = ax;
        accel[1] = ay;
        accel[2] = az;
        hasAccel = true;
        mag[0] = mx;
        mag[1] = my;
        mag[2] = mz;
        hasMag = true;
        lastMagNs = timestampNs;
        maybeInitialize();
        onGyro(timestampNs, gx, gy, gz);
    }

    // ---------------------------------------------------------------- 校正

    /**
     * 启动时定初值。
     *
     * <p>有可用磁力计时用 {@code getRotationMatrix} 得到绝对的 device→ENU；
     * 没有磁力计（或 HID 报文里的 mag 全 0）时，退化为「加速度定 tilt、yaw 取 0」
     * 的初值。后者仍然能从第一帧开始积分，只是航向是任意的——recenter 之后
     * 对用户没有区别。</p>
     */
    private void maybeInitialize() {
        if (initialized || !hasAccel) {
            return;
        }
        float magLength = (float) Math.sqrt(
                mag[0] * mag[0] + mag[1] * mag[1] + mag[2] * mag[2]);
        if (hasMag && magLength > 5f
                && SensorManager.getRotationMatrix(rotationMatrix, null, accel, mag)) {
            q.fromRotationMatrix(rotationMatrix, 0);
            initialized = true;
            lastGyroNs = 0L;
            magReferenceValid = false;
            accelSamples = 0;
            return;
        }
        if (++accelSamples < 10) {
            return;
        }
        initializeFromAccel();
    }

    /** 只用重力方向构造 device→ENU：把测得的「上」转到世界 +Z，yaw 任意。 */
    private void initializeFromAccel() {
        float ax = accel[0];
        float ay = accel[1];
        float az = accel[2];
        float length = (float) Math.sqrt(ax * ax + ay * ay + az * az);
        if (length < 1e-3f) {
            return;
        }
        ax /= length;
        ay /= length;
        az /= length;

        float horizontal = (float) Math.sqrt(ax * ax + ay * ay);
        if (horizontal < 1e-4f) {
            if (az > 0f) {
                q.setIdentity();
            } else {
                // 设备朝下：绕 X 转 180°
                q.set(0f, 1f, 0f, 0f);
            }
        } else {
            // 轴 = a × (0,0,1) = (ay, -ax, 0)，角度 = a 与世界 +Z 的夹角
            float angle = (float) Math.atan2(horizontal, az);
            q.setAxisAngle(ay / horizontal, -ax / horizontal, 0f, angle);
        }
        q.normalize();
        initialized = true;
        lastGyroNs = 0L;
        magReferenceValid = false;
        accelSamples = 0;
    }

    /**
     * 重力倾角校正。
     *
     * <p>预测的「上」在机体系是 {@code q⁻¹ · (0,0,1)}，测得的上是归一化加速度。
     * Mahony 型修正：误差轴取 {@code measured × predicted}，右乘到 q 上。</p>
     */
    private void correctTilt(float dt) {
        float length = (float) Math.sqrt(
                accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
        if (length < 0.1f) {
            return;
        }
        float mx = accel[0] / length;
        float my = accel[1] / length;
        float mz = accel[2] / length;

        tmpA.set(q);
        tmpA.conjugate();
        tmpA.rotateVector(0f, 0f, 1f, upInDevice);

        float cx = my * upInDevice[2] - mz * upInDevice[1];
        float cy = mz * upInDevice[0] - mx * upInDevice[2];
        float cz = mx * upInDevice[1] - my * upInDevice[0];
        float sin = (float) Math.sqrt(cx * cx + cy * cy + cz * cz);
        if (sin < 1e-5f) {
            return;
        }
        float dot = mx * upInDevice[0] + my * upInDevice[1] + mz * upInDevice[2];
        float angle = (float) Math.atan2(sin, dot);
        float gain = Math.min(1f, TILT_GAIN * dt);

        tmpB.setAxisAngle(cx / sin, cy / sin, cz / sin, angle * gain);
        q.postMultiply(tmpB);
        q.normalize();
    }

    /**
     * 磁北 yaw 校正。
     *
     * <p>把磁力计向量转到世界系，只看水平分量；以第一次有效读数为参考航向，
     * 误差绕世界 +Z 左乘。模长异常（磁干扰）时整帧跳过。</p>
     */
    private void correctYaw(float dt) {
        float magLength = (float) Math.sqrt(
                mag[0] * mag[0] + mag[1] * mag[1] + mag[2] * mag[2]);
        if (magLength < MAG_MIN_UT || magLength > MAG_MAX_UT) {
            return;
        }

        q.rotateVector(mag[0], mag[1], mag[2], magnitudeWorld);
        float hx = magnitudeWorld[0];
        float hy = magnitudeWorld[1];
        if (hx * hx + hy * hy < 9f) {
            return;
        }
        float heading = (float) Math.atan2(hy, hx);
        if (!magReferenceValid) {
            magReferenceHeading = heading;
            magReferenceValid = true;
            return;
        }

        float error = wrapPi(magReferenceHeading - heading);
        if (Math.abs(error) < 1e-4f) {
            return;
        }
        float gain = Math.min(1f, MAG_GAIN * dt);
        tmpB.setAxisAngle(0f, 0f, 1f, error * gain);
        Quat.multiply(tmpA, tmpB, q);
        q.set(tmpA);
        q.normalize();
    }

    private void updateGyroBias(float gx, float gy, float gz) {
        float accelNorm = (float) Math.sqrt(
                accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
        boolean steady = hasAccel
                && Math.abs(accelNorm - GRAVITY) < ACC_STEADY_MPS2
                && Math.sqrt(gx * gx + gy * gy + gz * gz) < GYRO_STEADY_RAD;
        if (!steady) {
            steadyFrames = 0;
            return;
        }
        if (++steadyFrames <= 40) {
            return;
        }
        gyroBias[0] += (gx - gyroBias[0]) * 0.01f;
        gyroBias[1] += (gy - gyroBias[1]) * 0.01f;
        gyroBias[2] += (gz - gyroBias[2]) * 0.01f;
    }

    // ---------------------------------------------------------------- 输出

    /** 把当前朝向记为渲染坐标的正前方（只影响 yaw）。 */
    public synchronized void recenter() {
        tmpA.set(sensorToRender);
        Quat.multiply(tmpB, tmpA, q);
        tmpB.rotateVector(0f, 0f, -1f, forward);
        // 正朝上/下看时 forward 在水平面的投影接近 0，yaw 没有意义。
        if (forward[0] * forward[0] + forward[2] * forward[2] < 0.01f) {
            return;
        }
        float yaw = (float) Math.atan2(forward[0], -forward[2]);
        recenter.setAxisAngle(0f, 1f, 0f, yaw);
    }

    public synchronized void getPose(Pose out) {
        compose(out.orientation);
        out.angularVelocity[0] = angularVelocity[0];
        out.angularVelocity[1] = angularVelocity[1];
        out.angularVelocity[2] = angularVelocity[2];
        out.timestampNs = lastRotationNs != 0L ? lastRotationNs : lastGyroNs;
        out.hasPosition = false;
        out.position[0] = out.position[1] = out.position[2] = 0f;
    }

    public synchronized void predict(Pose out, float deltaSeconds) {
        getPose(out);
        if (deltaSeconds <= 1e-4f) {
            return;
        }
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

    /** 当前渲染姿态（不含预测）。 */
    public synchronized void getOrientation(Quat out) {
        compose(out);
    }

    private void compose(Quat out) {
        tmpA.set(sensorToRender);
        Quat.multiply(tmpB, tmpA, q);       // q_render = S · q
        Quat.multiply(tmpA, recenter, tmpB); // 再左乘 recenter
        out.set(tmpA);
        out.normalize();
    }

    private static float wrapPi(float angle) {
        while (angle > Math.PI) {
            angle -= (float) (Math.PI * 2.0);
        }
        while (angle < -Math.PI) {
            angle += (float) (Math.PI * 2.0);
        }
        return angle;
    }
}
