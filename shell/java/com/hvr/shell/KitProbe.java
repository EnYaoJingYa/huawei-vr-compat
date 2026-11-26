package com.hvr.shell;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.app.PendingIntent;
import android.os.Build;
import android.util.Log;

import java.util.HashMap;

/**
 * 6DoF 模组（Omnivision UVC 相机 + 手柄射频盒）的 USB 深度探测。
 *
 * <p>已确认的硬件事实（P30 + EMUI11，眼镜内建 Hub）：</p>
 * <ul>
 *   <li>模组本体 VID 0x12D1 / PID 0x3A09，"6DoF Gaming Kit Par-CG012"，
 *       Omnivision 制造，含 VideoControl(class 14/1) 接口 → UVC 相机；</li>
 *   <li>眼镜 HID 复合设备 0x107E 暴露 3 个串口通道 + 2 个 HID 接口，
 *       内核已绑定 ttyUSB0-2（SELinux 类型 comraw_device，App 打不开）；</li>
 *   <li>Camera2 里没有模组相机 → 原厂走私有 HAL。</li>
 * </ul>
 *
 * <p>本探测回答三个问题：</p>
 * <ol>
 *   <li>模组的视频流端点是 BULK 还是 ISOCHRONOUS？—— BULK 则 App 可直读；</li>
 *   <li>App 能否 claim 模组的各接口并实际读到数据？</li>
 *   <li>107E 设备的 HID/串口接口能否被 App 抢占（手柄/IMU 数据通路）？</li>
 * </ol>
 */
final class KitProbe {

    static final String ACTION_GRANTED = "com.hvr.shell.USB_PERMISSION";
    /** 模组：6DoF Gaming Kit。 */
    private static final int KIT_PID = 0x3A09;
    /** 眼镜 HID 复合设备（含 3 串口 + 2 HID）。 */
    private static final int HID_PID = 0x107E;
    private static final int VID = 0x12D1;

    private static final String TAG = "HvrProbe";

    private KitProbe() {
    }

    /** 找设备（也匹配模组插在别处的情况）。 */
    private static UsbDevice find(UsbManager um, int pid) {
        for (UsbDevice device : um.getDeviceList().values()) {
            if (device.getVendorId() == VID && device.getProductId() == pid) {
                return device;
            }
        }
        return null;
    }

    static String run(Context context) {
        StringBuilder out = new StringBuilder();
        UsbManager um = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        if (um == null) {
            return "无 UsbManager";
        }
        probeDevice(context, um, find(um, KIT_PID), "6DoF 模组", out);
        out.append('\n');
        probeDevice(context, um, find(um, HID_PID), "眼镜HID复合(107E)", out);
        return out.toString();
    }

    private static void probeDevice(Context context, UsbManager um, UsbDevice device,
                                    String label, StringBuilder out) {
        out.append("== ").append(label).append(" ==\n");
        if (device == null) {
            out.append("  未连接\n");
            return;
        }
        out.append("  ").append(device.getProductName()).append("  ")
                .append(String.format("%04x:%04x", device.getVendorId(),
                        device.getProductId())).append('\n');

        // 先枚举描述符（不需要权限）
        for (int i = 0; i < device.getInterfaceCount(); i++) {
            UsbInterface iface = device.getInterface(i);
            out.append("  接口").append(i)
                    .append(" class=").append(iface.getInterfaceClass())
                    .append(" sub=").append(iface.getInterfaceSubclass())
                    .append(" proto=").append(iface.getInterfaceProtocol())
                    .append(" 端点x").append(iface.getEndpointCount()).append('\n');
            for (int j = 0; j < iface.getEndpointCount(); j++) {
                UsbEndpoint ep = iface.getEndpoint(j);
                out.append("    ep").append(j).append(' ').append(typeName(ep.getType()))
                        .append(ep.getDirection() == UsbConstants.USB_DIR_IN ? " IN" : " OUT")
                        .append(" addr=0x").append(Integer.toHexString(ep.getAddress()))
                        .append(" maxpkt=").append(ep.getMaxPacketSize())
                        .append(" interval=").append(ep.getInterval()).append('\n');
            }
        }

        if (!um.hasPermission(device)) {
            requestPermission(context, um, device);
            out.append("  [需要 USB 权限，已在手机上弹窗——点允许后重新点一次硬件诊断]\n");
            return;
        }

        UsbDeviceConnection conn = um.openDevice(device);
        if (conn == null) {
            out.append("  openDevice 失败\n");
            return;
        }
        try {
            // 逐个接口尝试 claim + 读写测试
            for (int i = 0; i < device.getInterfaceCount(); i++) {
                UsbInterface iface = device.getInterface(i);
                boolean claimed;
                try {
                    claimed = conn.claimInterface(iface, true);
                } catch (Throwable error) {
                    out.append("  接口").append(i).append(" claim 异常：")
                            .append(error).append('\n');
                    continue;
                }
                if (!claimed) {
                    out.append("  接口").append(i).append(" claim 失败（内核占用？）\n");
                    continue;
                }
                out.append("  接口").append(i).append(" claim 成功\n");
                for (int j = 0; j < iface.getEndpointCount(); j++) {
                    UsbEndpoint ep = iface.getEndpoint(j);
                    if (ep.getDirection() != UsbConstants.USB_DIR_IN) {
                        continue;
                    }
                    if (ep.getType() == UsbConstants.USB_ENDPOINT_XFER_ISOC) {
                        out.append("    ep").append(j).append(" 是 ISO 端点，")
                                .append("Android USB Host API 不支持，跳过\n");
                        continue;
                    }
                    byte[] buffer = new byte[16 * 1024];
                    int n;
                    try {
                        n = conn.bulkTransfer(ep, buffer, buffer.length, 400);
                    } catch (Throwable error) {
                        out.append("    ep").append(j).append(" 读取异常：")
                                .append(error).append('\n');
                        continue;
                    }
                    out.append("    ep").append(j).append(' ').append(typeName(ep.getType()))
                            .append(" 读到 ").append(n).append(" 字节");
                    if (n > 0) {
                        out.append("  头16B:");
                        for (int k = 0; k < Math.min(16, n); k++) {
                            out.append(String.format(" %02x", buffer[k]));
                        }
                    }
                    out.append('\n');
                }
                conn.releaseInterface(iface);
            }
        } finally {
            conn.close();
        }
    }

    private static String typeName(int type) {
        switch (type) {
            case UsbConstants.USB_ENDPOINT_XFER_BULK:
                return "BULK";
            case UsbConstants.USB_ENDPOINT_XFER_ISOC:
                return "ISO";
            case UsbConstants.USB_ENDPOINT_XFER_INT:
                return "INT";
            default:
                return "CTRL(" + type + ")";
        }
    }

    private static void requestPermission(Context context, UsbManager um, UsbDevice device) {
        // 编译目标 android-30 没有 FLAG_MUTABLE 常量；31+ 需要显式可变标志。
        int flag = Build.VERSION.SDK_INT >= 31 ? 0x02000000 : 0;
        PendingIntent pi = PendingIntent.getBroadcast(context, 0,
                new Intent(ACTION_GRANTED).setPackage(context.getPackageName()), flag);
        um.requestPermission(device, pi);
    }

    /** USB 权限弹窗的回执，仅用于日志。 */
    static BroadcastReceiver grantReceiver() {
        return new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                boolean granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED,
                        false);
                Log.i(TAG, "USB 权限回执：granted=" + granted);
            }
        };
    }

    /** 便捷入口：跑一次并整段打日志。 */
    static void logOnce(Context context) {
        String report;
        try {
            report = run(context);
        } catch (Throwable error) {
            report = "探测异常：" + error;
        }
        Log.i(TAG, report);
        ShellState.event("模组探测完成，见日志");
    }
}
