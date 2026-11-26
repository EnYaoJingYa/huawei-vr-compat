package com.hvr.shell;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.view.Display;

/**
 * 「眼镜在不在位」的判定，语义与原版兼容层
 * {@code com.huawei.vrframework.compat.VrPlatformCompat} 一致：
 * <b>两个信号同时成立才算在位</b>。
 *
 * <ul>
 *   <li>USB 身份：VID 0x12d1 + PID 0x1092（DisplayPort 复合）或 0x107e（HID）。
 *       它证明线那头确实是这副眼镜，不是别的 Type-C 设备。</li>
 *   <li>外接屏：非默认屏且 state != OFF。它证明眼镜的 DisplayPort 侧起来了。</li>
 * </ul>
 *
 * 只看一个都会误判：只插线不开屏时眼镜没画面；折叠屏合盖时副屏也会「存在」。
 */
final class GlassPresence {

    static final int HUAWEI_VENDOR_ID = 0x12d1;
    static final int GLASS_CV10_PRODUCT_ID = 0x1092;
    static final int GLASS_HID_PRODUCT_ID = 0x107e;

    private GlassPresence() {
    }

    static boolean hasUsbIdentity(Context context) {
        if (context == null) {
            return false;
        }
        UsbManager manager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        if (manager == null) {
            return false;
        }
        try {
            for (UsbDevice device : manager.getDeviceList().values()) {
                if (device.getVendorId() == HUAWEI_VENDOR_ID
                        && (device.getProductId() == GLASS_CV10_PRODUCT_ID
                        || device.getProductId() == GLASS_HID_PRODUCT_ID)) {
                    return true;
                }
            }
        } catch (Throwable error) {
            ShellState.event("USB 探测不可用", error);
        }
        return false;
    }

    static Display externalDisplay(Context context) {
        if (context == null) {
            return null;
        }
        DisplayManager manager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) {
            return null;
        }
        try {
            for (Display display : manager.getDisplays()) {
                if (display == null || display.getDisplayId() == Display.DEFAULT_DISPLAY) {
                    continue;
                }
                if (display.getState() != Display.STATE_OFF) {
                    return display;
                }
            }
        } catch (Throwable error) {
            ShellState.event("显示探测不可用", error);
        }
        return null;
    }

    static boolean sample(Context context) {
        boolean usb = hasUsbIdentity(context);
        Display display = externalDisplay(context);
        boolean present = usb && display != null;
        ShellState.usbIdentity = usb;
        ShellState.displayName = display == null ? null : display.getName();
        ShellState.glassPresent = present;
        return present;
    }

    static String describe() {
        return "usb=" + ShellState.usbIdentity
                + " display=" + (ShellState.displayName == null ? "无" : ShellState.displayName)
                + " 在位=" + ShellState.glassPresent;
    }
}
