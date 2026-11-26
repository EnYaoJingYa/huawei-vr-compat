package com.hvr.shell.pose;

import android.util.Log;

import java.io.File;
import java.io.FileInputStream;

/**
 * 从华为眼镜的 HID 节点读 IMU（实验性）。
 *
 * <p>报文格式来自对 {@code libWalleDev.so} 的反汇编，详见
 * {@code docs/AI_VR_DRIVER_AND_CASTING.md} §4.1：</p>
 *
 * <pre>
 *   [0]      tag = 3
 *   [1..12]  acc   float32 LE ×3
 *   [13..24] gyro  float32 LE ×3
 *   [25..36] mag   float32 LE ×3
 *   [37..40] timestamp float32 LE，单位 µs
 *   [41..44] 扩展
 * </pre>
 *
 * <p><b>为什么默认不用它</b>：普通 App 打不开 {@code /dev/hwvr1}。要么系统里有
 * EMUI 的 {@code hwvr} 驱动 + 放宽 SELinux，要么用仓库里的内核模块方案。
 * 读不到时 {@link #isAvailable()} 返回 false，调用方应回退到手机 IMU。</p>
 *
 * <p>另外 gyro 的单位在反汇编里没有标注（rad/s 还是 deg/s）。这里用
 * {@link #GYRO_SCALE} 暴露出来，默认按 rad/s 处理；如果转头速度明显不对，
 * 把它改成 {@code (float)(Math.PI / 180.0)}。</p>
 */
public final class WalleHidPoseSource implements PoseSource {

    private static final String TAG = "WalleHidPoseSource";
    public static final String DEFAULT_NODE = "/dev/hwvr1";

    private static final int TAG_IMU = 3;
    private static final int REPORT_LEN = 45;
    /** 反汇编没有给出单位；1.0 = rad/s。 */
    public static final float GYRO_SCALE = 1.0f;

    private final String nodePath;
    private final HeadPoseFusion fusion = new HeadPoseFusion();

    private volatile boolean running;
    private volatile FileInputStream input;
    private Thread thread;

    public WalleHidPoseSource() {
        this(DEFAULT_NODE);
    }

    public WalleHidPoseSource(String nodePath) {
        this.nodePath = nodePath;
    }

    @Override
    public boolean isAvailable() {
        File node = new File(nodePath);
        return node.exists() && node.canRead();
    }

    @Override
    public void start() {
        if (running || !isAvailable()) {
            return;
        }
        fusion.reset();
        running = true;
        thread = new Thread(this::readLoop, "walle-hid");
        thread.setDaemon(true);
        thread.start();
    }

    @Override
    public void stop() {
        running = false;
        FileInputStream stream = input;
        if (stream != null) {
            try {
                stream.close();
            } catch (Throwable ignored) {
                // 关闭失败不影响退出
            }
        }
        input = null;
        Thread worker = thread;
        if (worker != null) {
            try {
                worker.join(300L);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }
        thread = null;
    }

    @Override
    public void recenter() {
        fusion.recenter();
    }

    @Override
    public void getPose(Pose out) {
        fusion.getPose(out);
    }

    @Override
    public void predict(Pose out, float deltaSeconds) {
        fusion.predict(out, deltaSeconds);
    }

    @Override
    public String name() {
        return "华为眼镜 HID（" + nodePath + "）";
    }

    private void readLoop() {
        byte[] buffer = new byte[256];
        try (FileInputStream stream = new FileInputStream(nodePath)) {
            input = stream;
            while (running) {
                int length = stream.read(buffer);
                if (length < 0) {
                    Log.i(TAG, nodePath + " 已到 EOF");
                    break;
                }
                if (length == 0) {
                    continue;
                }
                if (!parseImu(buffer, length, fusion)) {
                    Log.v(TAG, "忽略非 IMU 报文: tag=" + (buffer[0] & 0xFF)
                            + ", len=" + length);
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "读取 " + nodePath + " 失败: " + error);
        } finally {
            input = null;
            running = false;
        }
    }

    /**
     * 解析一条 IMU 报文。抽成静态方法是为了能在没有设备时用单元测试/日志回放验证。
     */
    public static boolean parseImu(byte[] report, int length, HeadPoseFusion fusion) {
        if (report == null || length < REPORT_LEN || fusion == null) {
            return false;
        }
        if ((report[0] & 0xFF) != TAG_IMU) {
            return false;
        }
        float ax = leFloat(report, 1);
        float ay = leFloat(report, 5);
        float az = leFloat(report, 9);
        float gx = leFloat(report, 13) * GYRO_SCALE;
        float gy = leFloat(report, 17) * GYRO_SCALE;
        float gz = leFloat(report, 21) * GYRO_SCALE;
        float mx = leFloat(report, 25);
        float my = leFloat(report, 29);
        float mz = leFloat(report, 33);
        double seconds = leFloat(report, 37) / 1e6;

        fusion.onImu(ax, ay, az, gx, gy, gz, mx, my, mz, seconds);
        return true;
    }

    private static float leFloat(byte[] buffer, int offset) {
        int bits = (buffer[offset] & 0xFF)
                | ((buffer[offset + 1] & 0xFF) << 8)
                | ((buffer[offset + 2] & 0xFF) << 16)
                | ((buffer[offset + 3] & 0xFF) << 24);
        return Float.intBitsToFloat(bits);
    }
}
