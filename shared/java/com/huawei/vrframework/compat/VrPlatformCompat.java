package com.huawei.vrframework.compat;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.util.Log;
import android.view.Display;

/**
 * Replacement for the Huawei kernel probe the VR framework uses.
 *
 * Three places decide whether the glasses are connected by looking for the
 * Huawei kernel device node:
 *
 *     new File("/dev/hwvr1").exists()
 *   VrSystemClient.isVRGlassExist()      -> "vr glass not exist, no need to bind service"
 *   VrMonitor.isVRGlassDevExist()
 *   VrTouchService.isVRGlassExist()
 *
 * That node is created by Huawei's kernel driver when the glasses are plugged
 * in; a stock device has no such driver, so the whole phone-controller path was
 * skipped even though the glasses really were attached:
 *
 *   W PhoneController: vr glass not exist, no need to bind service
 *   W VrControllerManager: bind VrTouchService failed
 *   E Unity_HVRController: Right controller is not available in Update
 *
 * The same question - "are the glasses attached?" - is answered here from the
 * two real signals this port relies on:
 *
 *   1. the USB identity the glasses present on the wire: vendor 0x12d1 with
 *      product 0x1092 ("HUAWEI GLASS CV10", the DisplayPort + HID composite) or
 *      0x107e ("HUAWEI GLASS HID", the HID pair the runtime and handle use);
 *   2. an external display being connected, which is the DisplayPort side of
 *      the very same cable.
 *
 * Neither signal is a device name. Any headset that comes up as an external
 * display on that Huawei USB identity answers true; any other external screen
 * without the identity answers false. No state is invented: with the glasses
 * unplugged both signals disappear and the check returns false, exactly like
 * the missing kernel node.
 */
public final class VrPlatformCompat {
    private static final String TAG = "VrPlatformCompat";

    /** Huawei's USB vendor id, used by every VR Glass generation. */
    public static final int HUAWEI_VENDOR_ID = 0x12d1;
    /** "HUAWEI GLASS CV10": DisplayPort + HID composite of the CV10 glass. */
    public static final int GLASS_CV10_PRODUCT_ID = 0x1092;
    /** "HUAWEI GLASS HID": the HID interface pair the runtime and handle use. */
    public static final int GLASS_HID_PRODUCT_ID = 0x107e;

    private VrPlatformCompat() {
    }

    public static boolean isVrGlassPresent() {
        Context context = application();
        if (context == null) {
            // Third-party processes (e.g. the ALVR client) never see our compat
            // provider, and hidden-API rules can block the reflection fallback.
            // The kernel node answers the same question with no context at all:
            // it exists exactly while the glasses probe is satisfied (on real
            // hardware Huawei's driver creates it; on this port the hvrglass
            // module keeps it alive while the glasses are attached).
            boolean fallback = KERNEL_NODE.exists();
            Log.w(TAG, "no application context, kernel-node probe: " + fallback);
            return fallback;
        }
        return isVrGlassPresent(context);
    }

    /**
     * Same answer, from the caller's context. Both real signals must agree: the
     * USB identity proves which device is on the cable, the external display
     * proves its DisplayPort side came up.
     */
    public static boolean isVrGlassPresent(Context context) {
        if (context == null) {
            return false;
        }
        boolean usb = hasGlassUsbIdentity(context);
        boolean display = hasExternalDisplay(context);
        Log.i(TAG, "glass probe: usb=" + usb + " externalDisplay=" + display);
        return usb && display;
    }

    /** True while a USB device with the Huawei glass identity is attached. */
    public static boolean hasGlassUsbIdentity(Context context) {
        if (context == null) {
            return false;
        }
        UsbManager manager =
                (UsbManager) context.getSystemService(Context.USB_SERVICE);
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
            // Listing can be restricted: report "no identity" instead of guessing.
            Log.w(TAG, "usb probe unavailable: " + error);
        }
        return false;
    }

    /** True when any display other than the built-in panels is connected. */
    public static boolean hasExternalDisplay(Context context) {
        return externalDisplay(context) != null;
    }

    /**
     * The external display the glasses present, or {@code null} when none is
     * connected. Selection is by public display state, never by name: the main
     * panel is {@link Display#DEFAULT_DISPLAY} and the foldable's cover panel
     * reports {@link Display#STATE_OFF} while the phone is open, so neither is
     * ever returned. This only ever *confirms* the USB identity above - on its
     * own it would also match the cover panel of a folded phone.
     *
     * <p><b>2026-11-26 修复：</b>当 {@code overlay_display_devices} 配成两块副屏
     * （dual 档：{@code 100x100/320;1920x1080/320}）时，旧的「返回第一块非默认亮屏」
     * 会选中 100x100 的探针屏，Presentation 随之挂到它上面，真正承载 SBS
     * 双目的大屏成了空壳。现在改为在所有合格副屏里按**可视面积最大**选择；面积
     * 相同时按 displayId 稳定取小的一个。{@link #hasExternalDisplay(Context)} 的
     * 「是否存在」语义不变（有任意合格副屏即为 true），只影响「选哪块当面板」。
     *
     * @see #displayArea(Display)
     */
    public static Display externalDisplay(Context context) {
        if (context == null) {
            return null;
        }
        DisplayManager manager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) {
            return null;
        }
        return largestDisplay(manager.getDisplays());
    }

    /**
     * 在一组 display 里挑可视面积最大的合格副屏（非默认、非 OFF）。
     * 在位判定与面板选择共用同一套「按面积」口径，避免两处各自退回「第一块」打架。
     */
    public static Display largestDisplay(Display[] displays) {
        return largestDisplay(displays, true);
    }

    /**
     * 与 {@link #largestDisplay(Display[])} 相同，但可通过 {@code requireOn} 控制
     * 是否排除 OFF 屏。
     *
     * <p>{@code HvrPanelFinder} 的 presentation 类别 / FLAG_PRESENTATION 两级在修复前
     * 并不检查 OFF（眼镜屏短暂进入 OFF 时仍要认出来），传 {@code false} 可保持该语义；
     * 真正用于呈现画面的兜底级传 {@code true}，与 {@link #externalDisplay(Context)} 一致。
     */
    public static Display largestDisplay(Display[] displays, boolean requireOn) {
        if (displays == null) {
            return null;
        }
        Display best = null;
        long bestArea = -1;
        for (Display display : displays) {
            if (!isCandidatePanel(display, requireOn)) {
                continue;
            }
            long area = displayArea(display);
            // 面积更大，或面积相同但 displayId 更小（稳定、可复现）时替换。
            if (best == null || area > bestArea
                    || (area == bestArea && display.getDisplayId() < best.getDisplayId())) {
                best = display;
                bestArea = area;
            }
        }
        return best;
    }

    /** 合格的面板候选：非 null、非默认屏；requireOn 为 true 时还要求状态不是 OFF。 */
    public static boolean isCandidatePanel(Display display, boolean requireOn) {
        return display != null
                && display.getDisplayId() != Display.DEFAULT_DISPLAY
                && (!requireOn || display.getState() != Display.STATE_OFF);
    }

    /** display 的可视面积（realPixels 宽×高）；拿不到尺寸时返回 0 而非抛异常。 */
    public static long displayArea(Display display) {
        if (display == null) {
            return 0;
        }
        try {
            android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
            display.getRealMetrics(metrics);
            long w = Math.max(0, metrics.widthPixels);
            long h = Math.max(0, metrics.heightPixels);
            return w * h;
        } catch (Throwable error) {
            Log.w(TAG, "displayArea failed for #" + display.getDisplayId() + ": " + error);
            return 0;
        }
    }

    /** Real name of the connected external display, or {@code null}. */
    public static String externalDisplayName(Context context) {
        Display display = externalDisplay(context);
        return display == null ? null : display.getName();
    }

    private static final java.io.File KERNEL_NODE = new java.io.File("/dev/hwvr1");

    /**
     * 走兼容层统一的 Context 来源（provider 注入的真实 application context）。
     *
     * 之前这里自己反射 `ActivityThread.currentApplication()`：Runtime 的 targetSdk 是
     * 26 时能用，但这个探测会被桌面等 targetSdk≥28 的进程调用，反射会被 hidden API
     * 拦掉，结果是「拿不到 context → 判定眼镜不在位 → 整条手柄链路被跳过」。
     *
     * 两级兜底：先普通反射（targetSdk<28 的进程直接可用），被拦再用 meta-reflection
     * 绕过（通过 Class.class 这个系统类持有 getDeclaredMethod，hidden API 检查对
     * 系统发起方豁免）。
     */
    private static Context application() {
        Context context = com.huawei.android.content.ContextEx.currentApplication();
        if (context != null) {
            return context;
        }
        try {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            context = (Context) activityThread
                    .getMethod("currentApplication").invoke(null);
            if (context != null) {
                return context;
            }
        } catch (Throwable blocked) {
            // Expected on targetSdk>=28 callers; try the meta-reflection bypass.
        }
        try {
            java.lang.reflect.Method getDeclaredMethod = Class.class
                    .getDeclaredMethod("getDeclaredMethod", String.class, Class[].class);
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            java.lang.reflect.Method currentApplication =
                    (java.lang.reflect.Method) getDeclaredMethod.invoke(activityThread,
                            "currentApplication", new Class[0]);
            Object application = currentApplication.invoke(null);
            if (application instanceof Context) {
                Log.i(TAG, "application context via meta-reflection");
                return (Context) application;
            }
        } catch (Throwable error) {
            Log.w(TAG, "reflection fallback failed: " + error);
        }
        return null;
    }
}
