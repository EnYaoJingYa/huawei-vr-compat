package dev.vrdemo.posedriver.pose;

/**
 * 单位四元数，分量顺序为 <b>(w, x, y, z)</b>。
 *
 * <p>这个顺序是刻意选的：华为 {@code Posture.quat} 就是 w-first
 * （见 {@code ArvrRuntimeModuleManager.getHelmetPos} 的单位四元数初始化），
 * 而 Android 的 {@code SensorManager.getQuaternionFromVector()} 返回 x-first。
 * 两者在本类与 {@link PhoneSensorPoseSource} 的边界上换序，内部一律 w-first。</p>
 *
 * <p>约定：{@code q} 把「机体坐标」旋转到「世界坐标」，
 * {@code world = q * body}。世界坐标对传感器而言是 ENU（东-北-天），
 * 经 {@link HeadPoseFusion} 的固定旋转后再变成渲染用的 Y-up 坐标。</p>
 */
public final class Quat {

    public float w = 1f;
    public float x;
    public float y;
    public float z;

    public Quat() {
    }

    public Quat(float w, float x, float y, float z) {
        set(w, x, y, z);
    }

    public void set(float w, float x, float y, float z) {
        this.w = w;
        this.x = x;
        this.y = y;
        this.z = z;
    }

    public void set(Quat other) {
        set(other.w, other.x, other.y, other.z);
    }

    public void setIdentity() {
        set(1f, 0f, 0f, 0f);
    }

    public Quat copy() {
        return new Quat(w, x, y, z);
    }

    public float dot(Quat other) {
        return w * other.w + x * other.x + y * other.y + z * other.z;
    }

    public void normalize() {
        float lengthSq = w * w + x * x + y * y + z * z;
        if (lengthSq < 1e-12f) {
            setIdentity();
            return;
        }
        float inv = 1f / (float) Math.sqrt(lengthSq);
        w *= inv;
        x *= inv;
        y *= inv;
        z *= inv;
    }

    /** 单位四元数的共轭 = 逆。 */
    public void conjugate() {
        x = -x;
        y = -y;
        z = -z;
    }

    /** out = a * b（Hamilton 积）。允许 out 与 a 或 b 别名。 */
    public static void multiply(Quat out, Quat a, Quat b) {
        float aw = a.w, ax = a.x, ay = a.y, az = a.z;
        float bw = b.w, bx = b.x, by = b.y, bz = b.z;
        out.w = aw * bw - ax * bx - ay * by - az * bz;
        out.x = aw * bx + ax * bw + ay * bz - az * by;
        out.y = aw * by - ax * bz + ay * bw + az * bx;
        out.z = aw * bz + ax * by - ay * bx + az * bw;
    }

    /** this = this * b，即绕机体轴旋转。 */
    public void postMultiply(Quat b) {
        multiply(this, this, b);
    }

    /** 轴角构造。轴不需要预先归一化。 */
    public void setAxisAngle(float axisX, float axisY, float axisZ, float angleRadians) {
        float length = (float) Math.sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ);
        if (length < 1e-8f) {
            setIdentity();
            return;
        }
        float half = angleRadians * 0.5f;
        float sin = (float) Math.sin(half) / length;
        w = (float) Math.cos(half);
        x = axisX * sin;
        y = axisY * sin;
        z = axisZ * sin;
    }

    /**
     * 把一小步机体角速度（rad/s）写成旋转增量 {@code exp(0.5·ω·dt)}。
     * <b>会覆盖当前值</b>；要积分请配合 {@link #postMultiply(Quat)} 使用。
     */
    public void setFromAngularVelocity(float gx, float gy, float gz, float dtSeconds) {
        float omega = (float) Math.sqrt(gx * gx + gy * gy + gz * gz);
        setAxisAngle(gx, gy, gz, omega * dtSeconds);
    }

    /** out = q * v * q⁻¹，v 为三维向量。 */
    public void rotateVector(float vx, float vy, float vz, float[] out) {
        float tx = 2f * (y * vz - z * vy);
        float ty = 2f * (z * vx - x * vz);
        float tz = 2f * (x * vy - y * vx);
        out[0] = vx + w * tx + (y * tz - z * ty);
        out[1] = vy + w * ty + (z * tx - x * tz);
        out[2] = vz + w * tz + (x * ty - y * tx);
    }

    /**
     * 写入 4x4 列主序旋转矩阵（OpenGL 约定），平移分量为 0。
     * 与 {@code android.opengl.Matrix} 的内存布局一致。
     */
    public void toMatrix(float[] m, int offset) {
        float xx = x * x, yy = y * y, zz = z * z;
        float xy = x * y, xz = x * z, yz = y * z;
        float wx = w * x, wy = w * y, wz = w * z;

        m[offset] = 1f - 2f * (yy + zz);
        m[offset + 1] = 2f * (xy + wz);
        m[offset + 2] = 2f * (xz - wy);
        m[offset + 3] = 0f;

        m[offset + 4] = 2f * (xy - wz);
        m[offset + 5] = 1f - 2f * (xx + zz);
        m[offset + 6] = 2f * (yz + wx);
        m[offset + 7] = 0f;

        m[offset + 8] = 2f * (xz + wy);
        m[offset + 9] = 2f * (yz - wx);
        m[offset + 10] = 1f - 2f * (xx + yy);
        m[offset + 11] = 0f;

        m[offset + 12] = 0f;
        m[offset + 13] = 0f;
        m[offset + 14] = 0f;
        m[offset + 15] = 1f;
    }

    /** 行主序 3x3 旋转矩阵（{@code SensorManager.getRotationMatrix} 的输出）→ 四元数。 */
    public void fromRotationMatrix(float[] m, int offset) {
        float m00 = m[offset], m01 = m[offset + 1], m02 = m[offset + 2];
        float m10 = m[offset + 3], m11 = m[offset + 4], m12 = m[offset + 5];
        float m20 = m[offset + 6], m21 = m[offset + 7], m22 = m[offset + 8];
        float trace = m00 + m11 + m22;

        if (trace > 0f) {
            float s = (float) Math.sqrt(trace + 1.0) * 2f;
            w = 0.25f * s;
            x = (m21 - m12) / s;
            y = (m02 - m20) / s;
            z = (m10 - m01) / s;
        } else if (m00 > m11 && m00 > m22) {
            float s = (float) Math.sqrt(1.0 + m00 - m11 - m22) * 2f;
            w = (m21 - m12) / s;
            x = 0.25f * s;
            y = (m01 + m10) / s;
            z = (m02 + m20) / s;
        } else if (m11 > m22) {
            float s = (float) Math.sqrt(1.0 + m11 - m00 - m22) * 2f;
            w = (m02 - m20) / s;
            x = (m01 + m10) / s;
            y = 0.25f * s;
            z = (m12 + m21) / s;
        } else {
            float s = (float) Math.sqrt(1.0 + m22 - m00 - m11) * 2f;
            w = (m10 - m01) / s;
            x = (m02 + m20) / s;
            y = (m12 + m21) / s;
            z = 0.25f * s;
        }
        normalize();
    }

    /** 归一化线性插值：this = nlerp(a, b, t)。 */
    public void nlerp(Quat a, Quat b, float t) {
        float sign = a.dot(b) < 0f ? -1f : 1f;
        w = a.w + (b.w * sign - a.w) * t;
        x = a.x + (b.x * sign - a.x) * t;
        y = a.y + (b.y * sign - a.y) * t;
        z = a.z + (b.z * sign - a.z) * t;
        normalize();
    }

    /** 两个姿态之间的夹角（弧度，0..π）。 */
    public static float angleBetween(Quat a, Quat b) {
        float d = Math.abs(a.dot(b));
        if (d > 1f) {
            d = 1f;
        }
        return 2f * (float) Math.acos(d);
    }

    @Override
    public String toString() {
        return String.format(java.util.Locale.US, "(w=%.3f, x=%.3f, y=%.3f, z=%.3f)", w, x, y, z);
    }
}
