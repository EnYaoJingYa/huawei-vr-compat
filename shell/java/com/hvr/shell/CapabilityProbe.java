package com.hvr.shell;

import android.content.Context;
import android.graphics.ImageFormat;
import android.hardware.Sensor;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.hardware.display.DisplayManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.util.Log;
import android.util.Size;
import android.view.Display;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

/**
 * 硬件能力探测：回答「6DOF 到底有没有可能」这个问题。
 *
 * <p>6DOF 的原厂实现是双目 VIO/SLAM（{@code libVR6Dof.so} + {@code libarvr_slam.so}），
 * 它必须拿到两路相机图像。原厂走的是华为私有 HAL
 * {@code android.hardware.hivrar.camera.IHiARCamera}，普通应用连不上。
 * 但 {@code assets/vrglass.xml} 里相机的 {@code cameraid} 写的是 0 和 1，
 * 也就是 Android Camera2 的编号——如果这两个相机同时也挂在标准 Camera2 上，
 * 那么无 root 也能取到图像，6DOF 就还有生路。</p>
 *
 * <p>所以这里把三件事查清楚：</p>
 * <ol>
 *   <li>标准 Camera2 能看到几路相机、有没有 {@code LENS_FACING_EXTERNAL}（外接=眼镜）；</li>
 *   <li>系统有没有 {@code TYPE_POSE_6DOF}（有则直接用系统 VIO，最省事）；</li>
 *   <li>眼镜的 USB 复合设备里有没有 Video Class(14) 接口，以及 {@code /dev/hwvr1} 是否可读。</li>
 * </ol>
 */
final class CapabilityProbe {

    private static final String TAG = "HvrProbe";

    private CapabilityProbe() {
    }

    static String run(Context context) {
        StringBuilder out = new StringBuilder();
        out.append("== 设备 ==\n");
        out.append(Build.MANUFACTURER).append(' ').append(Build.MODEL)
                .append("  API ").append(Build.VERSION.SDK_INT).append('\n');

        probeCameras(context, out);
        probeSensors(context, out);
        probeUsb(context, out);
        probeDisplay(context, out);
        conclude(out);

        String text = out.toString();
        Log.i(TAG, "\n" + text);
        return text;
    }

    // ------------------------------------------------------------ 相机

    private static void probeCameras(Context context, StringBuilder out) {
        out.append("\n== 相机（标准 Camera2）==\n");
        CameraManager manager =
                (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
        if (manager == null) {
            out.append("  无 CameraManager\n");
            return;
        }
        int external = 0;
        try {
            String[] ids = manager.getCameraIdList();
            out.append("  共 ").append(ids.length).append(" 路：\n");
            for (String id : ids) {
                CameraCharacteristics ch = manager.getCameraCharacteristics(id);
                Integer facing = ch.get(CameraCharacteristics.LENS_FACING);
                boolean isExternal = facing != null
                        && facing == CameraCharacteristics.LENS_FACING_EXTERNAL;
                if (isExternal) {
                    external++;
                }
                String facingText;
                if (facing == null) {
                    facingText = "未知";
                } else if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                    facingText = "后置";
                } else if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
                    facingText = "前置";
                } else if (isExternal) {
                    facingText = "外接(外部相机)";
                } else {
                    facingText = "其他(" + facing + ")";
                }
                out.append("  #").append(id).append(' ').append(facingText)
                        .append(isExternal ? "  <== 可能是眼镜\n" : "\n");
                describeStreams(out, ch);
            }
            if (external == 0) {
                out.append("  结论：没有外接相机被枚举\n");
            }
        } catch (Throwable error) {
            out.append("  枚举失败：").append(error).append('\n');
        }
    }

    /** 输出尺寸与格式：VIO 只吃 YUV/灰度，尺寸要能出 640x480。 */
    private static void describeStreams(StringBuilder out, CameraCharacteristics ch) {
        try {
            StreamConfigurationMap map = ch.get(
                    CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            if (map == null) {
                out.append("      无 SCALER_STREAM_CONFIGURATION_MAP\n");
                return;
            }
            Size[] sizes = map.getOutputSizes(ImageFormat.YUV_420_888);
            if (sizes == null || sizes.length == 0) {
                out.append("      不支持 YUV_420_888（VIO 无法直接取帧）\n");
            } else {
                out.append("      YUV_420_888 尺寸：");
                int shown = 0;
                boolean has640 = false;
                for (Size size : sizes) {
                    if (size.getWidth() == 640 && size.getHeight() == 480) {
                        has640 = true;
                    }
                    if (shown < 4) {
                        out.append(size.getWidth()).append('x').append(size.getHeight()).append(' ');
                        shown++;
                    }
                }
                out.append(sizes.length > 4 ? "... 共 " + sizes.length + " 种" : "");
                out.append(has640 ? "  [含 640x480 ✓]" : "  [无 640x480 ✗]");
                out.append('\n');
            }
            int[] formats = map.getOutputFormats();
            out.append("      格式数：").append(formats == null ? 0 : formats.length);
            Integer level = ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL);
            out.append("  HAL级别：").append(level == null ? "?" : String.valueOf(level));
            if (level != null && level == CameraCharacteristics
                    .INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL) {
                out.append("(EXTERNAL)");
            }
            out.append('\n');
        } catch (Throwable error) {
            out.append("      查询失败：").append(error).append('\n');
        }
    }

    // ------------------------------------------------------------ 传感器

    private static void probeSensors(Context context, StringBuilder out) {
        out.append("\n== 传感器 ==\n");
        SensorManager manager =
                (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
        if (manager == null) {
            out.append("  无 SensorManager\n");
            return;
        }
        boolean pose6 = false;
        try {
            Sensor pose = manager.getDefaultSensor(Sensor.TYPE_POSE_6DOF);
            if (pose != null) {
                pose6 = true;
                out.append("  TYPE_POSE_6DOF：有（").append(pose.getName()).append("）\n");
            } else {
                out.append("  TYPE_POSE_6DOF：无\n");
            }
        } catch (Throwable error) {
            out.append("  TYPE_POSE_6DOF 查询失败：").append(error).append('\n');
        }
        append(out, manager, Sensor.TYPE_ROTATION_VECTOR, "ROTATION_VECTOR");
        append(out, manager, Sensor.TYPE_GAME_ROTATION_VECTOR, "GAME_ROTATION_VECTOR");
        append(out, manager, Sensor.TYPE_GYROSCOPE, "GYROSCOPE");
        append(out, manager, Sensor.TYPE_ACCELEROMETER, "ACCELEROMETER");
    }

    private static void append(StringBuilder out, SensorManager manager, int type, String name) {
        Sensor sensor = manager.getDefaultSensor(type);
        out.append("  ").append(name).append("：")
                .append(sensor == null ? "无" : sensor.getName()).append('\n');
    }

    // ------------------------------------------------------------ USB

    private static void probeUsb(Context context, StringBuilder out) {
        out.append("\n== USB ==\n");
        UsbManager manager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        if (manager == null) {
            out.append("  无 UsbManager\n");
            return;
        }
        List<UsbDevice> devices = new ArrayList<>(manager.getDeviceList().values());
        out.append("  设备数：").append(devices.size()).append('\n');
        boolean videoClass = false;
        for (UsbDevice device : devices) {
            out.append(String.format("  %04x:%04x %s",
                    device.getVendorId(), device.getProductId(),
                    device.getProductName() == null ? "" : device.getProductName()));
            if (device.getVendorId() == GlassPresence.HUAWEI_VENDOR_ID) {
                out.append("  [华为]");
            }
            out.append('\n');
            for (int i = 0; i < device.getInterfaceCount(); i++) {
                UsbInterface iface = device.getInterface(i);
                String cls = interfaceClass(iface.getInterfaceClass());
                out.append("    接口").append(i).append(": class=")
                        .append(iface.getInterfaceClass()).append(' ').append(cls)
                        .append(" 端点x").append(iface.getEndpointCount()).append('\n');
                if (iface.getInterfaceClass() == 14) {
                    videoClass = true;
                }
            }
        }
        if (videoClass) {
            out.append("  发现 Video Class 接口：眼镜相机走 UVC\n");
        }
        File node = new File("/dev/hwvr1");
        out.append("  /dev/hwvr1：").append(node.exists()
                ? (node.canRead() ? "存在且可读" : "存在但不可读（权限）")
                : "不存在").append('\n');
    }

    private static String interfaceClass(int cls) {
        switch (cls) {
            case 3:
                return "(HID)";
            case 14:
                return "(Video/UVC)";
            case 1:
                return "(Audio)";
            case 8:
                return "(MassStorage)";
            case 255:
                return "(厂商自定义)";
            default:
                return "";
        }
    }

    // ------------------------------------------------------------ 显示

    private static void probeDisplay(Context context, StringBuilder out) {
        out.append("\n== 显示 ==\n");
        DisplayManager manager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) {
            out.append("  无 DisplayManager\n");
            return;
        }
        Display[] displays = manager.getDisplays();
        out.append("  显示器数：").append(displays.length).append('\n');
        for (Display display : displays) {
            Display.Mode mode = display.getMode();
            out.append("  #").append(display.getDisplayId())
                    .append(' ').append(display.getName())
                    .append("  ").append(mode.getPhysicalWidth()).append('x')
                    .append(mode.getPhysicalHeight()).append('@')
                    .append(Math.round(mode.getRefreshRate())).append("Hz")
                    .append(display.getDisplayId() == Display.DEFAULT_DISPLAY ? " [主屏]" : " [外接]")
                    .append('\n');
        }
        Display external = GlassPresence.externalDisplay(context);
        out.append("  眼镜屏：").append(external == null ? "未检测到" : external.getName()).append('\n');
    }

    // ------------------------------------------------------------ 结论

    private static void conclude(StringBuilder out) {
        out.append("\n== 6DOF 可行性 ==\n");
        String text = out.toString();
        boolean externalCamera = text.contains("外接(外部相机)");
        boolean pose6 = text.contains("TYPE_POSE_6DOF：有");
        boolean uvClass = text.contains("Video Class 接口");
        boolean node = text.contains("/dev/hwvr1：存在且可读");

        if (pose6) {
            out.append("  [可用] 系统自带 TYPE_POSE_6DOF，直接读位姿。\n");
        }
        if (node) {
            out.append("  [可用] /dev/hwvr1 可读，能拿眼镜 IMU（3DOF 更准）。\n");
        }
        if (externalCamera) {
            out.append("  [可行] 标准 Camera2 能看到外接相机 → 双路图像可取。\n"
                    + "        配 vrglass.xml 的内参/畸变/时间延迟，可自建 VIO。\n");
        } else if (uvClass) {
            out.append("  [受限] 眼镜相机是 UVC，但 Android USB Host 不支持等时传输，\n"
                    + "        取不到视频流（非 root 无解）。\n");
        } else if (!pose6 && !node && !externalCamera) {
            out.append("  [不可行] 三条件全不满足：无 6DOF 传感器、无 IMU 节点、\n"
                    + "        相机未暴露在标准 API。原厂 SLAM 无法在非 root 下复现。\n");
        }
        out.append("  说明：以上任一「可用/可行」为真，6DOF 才有实现基础；\n"
                + "        全为假则只能停在 3DOF。\n");
    }
}
