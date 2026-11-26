package dev.vrdemo.posedriver.pose;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;

/**
 * 手机 IMU 姿态源。对应原厂 {@code libMobileSensor.so} 的角色：
 * 「没有眼镜 IMU 时，用手机自己的传感器做 3DOF」。
 *
 * <p>优先级：</p>
 * <ol>
 *   <li>{@code TYPE_GAME_ROTATION_VECTOR}：系统融合，不用磁力计，yaw 会慢慢漂但很稳；</li>
 *   <li>{@code TYPE_ROTATION_VECTOR}：系统融合，带磁力计；</li>
 *   <li>陀螺 + 加速度（+ 磁力计）：交给 {@link HeadPoseFusion} 自己融合。</li>
 * </ol>
 */
public final class PhoneSensorPoseSource implements PoseSource, SensorEventListener {

    private static final int SAMPLE_PERIOD_US = 10_000;   // 100 Hz
    private static final int MAG_PERIOD_US = 20_000;      // 50 Hz

    private final SensorManager sensorManager;
    private final HeadPoseFusion fusion = new HeadPoseFusion();

    private final Sensor rotationVector;
    private final Sensor gyroscope;
    private final Sensor accelerometer;
    private final Sensor magnetometer;

    private final boolean systemFusion;
    private boolean running;

    public PhoneSensorPoseSource(Context context) {
        sensorManager = (SensorManager) context.getApplicationContext()
                .getSystemService(Context.SENSOR_SERVICE);

        Sensor rotation = null;
        if (sensorManager != null) {
            rotation = sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR);
            if (rotation == null) {
                rotation = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
            }
        }
        rotationVector = rotation;

        gyroscope = sensorManager == null ? null
                : sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        accelerometer = sensorManager == null ? null
                : sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        magnetometer = sensorManager == null ? null
                : sensorManager.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD);

        systemFusion = rotationVector != null;
    }

    public boolean usesSystemFusion() {
        return systemFusion;
    }

    @Override
    public boolean isAvailable() {
        if (sensorManager == null) {
            return false;
        }
        return systemFusion || (gyroscope != null && accelerometer != null);
    }

    @Override
    public void start() {
        if (running || sensorManager == null) {
            return;
        }
        fusion.reset();
        if (systemFusion) {
            sensorManager.registerListener(this, rotationVector, SAMPLE_PERIOD_US, 0);
        } else {
            if (gyroscope != null) {
                sensorManager.registerListener(this, gyroscope, SAMPLE_PERIOD_US, 0);
            }
            if (accelerometer != null) {
                sensorManager.registerListener(this, accelerometer, SAMPLE_PERIOD_US, 0);
            }
            if (magnetometer != null) {
                sensorManager.registerListener(this, magnetometer, MAG_PERIOD_US, 0);
            }
        }
        running = true;
    }

    @Override
    public void stop() {
        if (!running || sensorManager == null) {
            return;
        }
        sensorManager.unregisterListener(this);
        running = false;
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
        if (systemFusion) {
            return "手机 IMU（系统旋转矢量）";
        }
        return "手机 IMU（陀螺+加速度自融合）";
    }

    @Override
    public void onSensorChanged(SensorEvent event) {
        switch (event.sensor.getType()) {
            case Sensor.TYPE_GAME_ROTATION_VECTOR:
            case Sensor.TYPE_ROTATION_VECTOR:
                fusion.setFromRotationVector(event.values, event.timestamp);
                break;
            case Sensor.TYPE_GYROSCOPE:
                fusion.onGyro(event.timestamp,
                        event.values[0], event.values[1], event.values[2]);
                break;
            case Sensor.TYPE_ACCELEROMETER:
                fusion.onAccel(event.timestamp,
                        event.values[0], event.values[1], event.values[2]);
                break;
            case Sensor.TYPE_MAGNETIC_FIELD:
                fusion.onMag(event.timestamp,
                        event.values[0], event.values[1], event.values[2]);
                break;
            default:
                break;
        }
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
        // 磁力计精度变化时原厂会调低校正权重；这里由 HeadPoseFusion 的模长检查兜底。
    }
}
