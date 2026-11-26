package com.hvr.shell.cast;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;

import java.util.Locale;

/**
 * 找眼镜那块副屏。
 *
 * <p>顺序（越靠前越可信）：</p>
 * <ol>
 *   <li>名字里带 VR/GLASS/HUAWEI/AV03/HOLO/XREAL/NREAL/ROKID/VITURE；</li>
 *   <li>{@code DISPLAY_CATEGORY_PRESENTATION}；</li>
 *   <li>{@code FLAG_PRESENTATION}；</li>
 *   <li>第一块非默认且不是 OFF 的屏。</li>
 * </ol>
 *
 * <p>折叠屏的 cover 屏也可能满足第 3 条，所以名字匹配必须放最前。</p>
 */
public final class DisplayFinder {

    private static final String TAG = "DisplayFinder";

    private static final String[] NAME_HINTS = {
            "VR", "GLASS", "HUAWEI", "AV03", "HOLO",
            "XREAL", "NREAL", "ROKID", "VITURE", "THUNDERBOLT"
    };

    private DisplayFinder() {
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
                if (!isCandidate(display)) {
                    continue;
                }
                String name = display.getName() == null
                        ? "" : display.getName().toUpperCase(Locale.US);
                for (String hint : NAME_HINTS) {
                    if (name.contains(hint)) {
                        Log.i(TAG, "按名字命中: " + describe(display));
                        return display;
                    }
                }
            }
            for (Display display : manager.getDisplays(
                    DisplayManager.DISPLAY_CATEGORY_PRESENTATION)) {
                if (isCandidate(display)) {
                    Log.i(TAG, "按 presentation 分类命中: " + describe(display));
                    return display;
                }
            }
            for (Display display : displays) {
                if (isCandidate(display)
                        && (display.getFlags() & Display.FLAG_PRESENTATION) != 0) {
                    Log.i(TAG, "按 FLAG_PRESENTATION 命中: " + describe(display));
                    return display;
                }
            }
            for (Display display : displays) {
                if (isCandidate(display) && display.getState() != Display.STATE_OFF) {
                    Log.i(TAG, "按「非默认且亮着」命中: " + describe(display));
                    return display;
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "扫描屏幕失败: " + error);
        }
        Log.w(TAG, "没有找到副屏\n" + describeAll(context));
        return null;
    }

    private static boolean isCandidate(Display display) {
        return display != null
                && display.isValid()
                && display.getDisplayId() != Display.DEFAULT_DISPLAY;
    }

    public static String describe(Display display) {
        if (display == null) {
            return "未找到";
        }
        StringBuilder out = new StringBuilder();
        out.append('#').append(display.getDisplayId()).append(' ')
                .append(display.getName()).append(" state=")
                .append(stateName(display.getState()));
        try {
            DisplayMetrics metrics = new DisplayMetrics();
            display.getRealMetrics(metrics);
            out.append(' ').append(metrics.widthPixels).append('x')
                    .append(metrics.heightPixels).append(" @").append(metrics.densityDpi);
        } catch (Throwable error) {
            out.append(" size=?");
        }
        out.append(" flags=0x").append(Integer.toHexString(display.getFlags()));
        return out.toString();
    }

    public static String describeAll(Context context) {
        if (context == null) {
            return "no context";
        }
        DisplayManager manager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        if (manager == null) {
            return "DisplayManager 不可用";
        }
        StringBuilder out = new StringBuilder();
        try {
            Display[] displays = manager.getDisplays();
            out.append("displays=").append(displays.length);
            for (Display display : displays) {
                out.append('\n').append("  ").append(describe(display));
            }
        } catch (Throwable error) {
            out.append("列举屏幕失败: ").append(error);
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
