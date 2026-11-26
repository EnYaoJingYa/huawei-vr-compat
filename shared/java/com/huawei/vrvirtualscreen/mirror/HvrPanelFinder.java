package com.huawei.vrvirtualscreen.mirror;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;

import com.huawei.vrframework.compat.VrPlatformCompat;

import java.util.Locale;

/**
 * 找眼镜那块副屏，并把当前所有屏幕打印出来，方便没有 adb 时排查。
 *
 * 顺序：
 *   1. 名字里带 HUAWEI / VR / AV03 / GLASS 的副屏（即使当前是 OFF 也能认出来）；
 *   2. 系统标记为 presentation 的屏；
 *   3. 带 {@link Display#FLAG_PRESENTATION} 的副屏；
 *   4. 兼容层兜底：非默认且不是 OFF 的屏。
 *
 * 注意：折叠屏的 cover 屏也可能满足第 3 条，所以名字匹配放在最前面。
 *
 * 2026-11-26 修复：dual 档（overlay_display_devices=100x100;1920x1080）下，
 * 第 2/3/4 级都可能有多块候选，旧代码返回「第一块」会命中小探针屏，把承载
 * SBS 双目的大屏变成空壳。现在每一级都在本级候选中按可视面积取最大的一块
 * （复用 {@link VrPlatformCompat#largestDisplay} 的面积口径）；只有第 1 级
 * 名字命中仍按列表顺序，因为真正的眼镜屏名字唯一且应优先于任何 overlay。
 */
public final class HvrPanelFinder {

    private static final String TAG = "HvrPanelFinder";

    private HvrPanelFinder() {
    }

    public static Display find(Context context) {
        if (context == null) {
            return null;
        }
        DisplayManager manager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) {
            return null;
        }
        try {
            Display[] displays = manager.getDisplays();
            for (Display display : displays) {
                if (display == null || display.getDisplayId() == Display.DEFAULT_DISPLAY) {
                    continue;
                }
                String name = display.getName() == null
                        ? "" : display.getName().toUpperCase(Locale.US);
                if (name.contains("HUAWEI") || name.contains("VR")
                        || name.contains("AV03") || name.contains("GLASS")) {
                    Log.i(TAG, "panel by name: " + describe(display));
                    return display;
                }
            }
            // 第 2 级：presentation 类别。多块时按面积取最大，避免命中小 overlay。
            // 传 requireOn=false，保持原逻辑「OFF 的眼镜屏也能认出来」的语义。
            Display presentationPanel = VrPlatformCompat.largestDisplay(
                    manager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION), false);
            if (presentationPanel != null) {
                Log.i(TAG, "panel by presentation category: " + describe(presentationPanel));
                return presentationPanel;
            }
            // 第 3 级：FLAG_PRESENTATION。同样先收集全部候选再按面积挑（含 OFF）。
            java.util.List<Display> flagged = new java.util.ArrayList<Display>();
            for (Display display : displays) {
                if (display == null || display.getDisplayId() == Display.DEFAULT_DISPLAY) {
                    continue;
                }
                if ((display.getFlags() & Display.FLAG_PRESENTATION) != 0) {
                    flagged.add(display);
                }
            }
            Display flaggedPanel = VrPlatformCompat.largestDisplay(
                    flagged.toArray(new Display[0]), false);
            if (flaggedPanel != null) {
                Log.i(TAG, "panel by FLAG_PRESENTATION: " + describe(flaggedPanel));
                return flaggedPanel;
            }
            // 第 4 级：兼容层兜底（externalDisplay 现已按面积选最大）。
            Display compat = VrPlatformCompat.externalDisplay(context);
            if (compat != null) {
                Log.i(TAG, "panel by compat fallback: " + describe(compat));
                return compat;
            }
        } catch (Throwable error) {
            Log.w(TAG, "display scan failed: " + error);
        }
        Log.w(TAG, "no panel found; " + describeAll(context));
        return null;
    }

    public static String describe(Display display) {
        if (display == null) {
            return "null";
        }
        StringBuilder out = new StringBuilder();
        out.append('#').append(display.getDisplayId()).append(' ').append(display.getName());
        out.append(" state=").append(stateName(display.getState()));
        try {
            DisplayMetrics metrics = new DisplayMetrics();
            display.getRealMetrics(metrics);
            out.append(' ').append(metrics.widthPixels).append('x')
                    .append(metrics.heightPixels).append(" @").append(metrics.densityDpi);
        } catch (Throwable error) {
            out.append(" size=?");
        }
        out.append(" flags=0x").append(Integer.toHexString(display.getFlags()));
        if (display.getDisplayId() == Display.DEFAULT_DISPLAY) {
            out.append(" (default)");
        }
        return out.toString();
    }

    public static String describeAll(Context context) {
        if (context == null) {
            return "no context";
        }
        DisplayManager manager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) {
            return "DisplayManager unavailable";
        }
        StringBuilder out = new StringBuilder();
        try {
            Display[] displays = manager.getDisplays();
            out.append("displays=").append(displays.length).append('\n');
            for (Display display : displays) {
                if (display != null) {
                    out.append("  ").append(describe(display)).append('\n');
                }
            }
        } catch (Throwable error) {
            out.append("display list failed: ").append(error);
        }
        return out.toString();
    }

    private static String stateName(int state) {
        switch (state) {
            case Display.STATE_ON:
                return "ON";
            case Display.STATE_OFF:
                return "OFF";
            case Display.STATE_DOZE:
                return "DOZE";
            case Display.STATE_DOZE_SUSPEND:
                return "DOZE_SUSPEND";
            case Display.STATE_VR:
                return "VR";
            case Display.STATE_UNKNOWN:
                return "UNKNOWN";
            default:
                return Integer.toString(state);
        }
    }
}
