package com.hvr.shell;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * 左右眼旋转 / 左右眼交换的实时校准中枢。
 *
 * <p>背景：两块 1600x1600 面板的物理安装角度只有拆机才能确认，猜一次就要重打
 * 一个包。这里把每眼的显示旋转做成四个象限（0°/90°/180°/270°），外加左右眼
 * 交换开关，手机端按钮实时调节、立即生效、持久化保存。</p>
 *
 * <p>steps 语义（显示内容顺时针转的角度）：</p>
 * <ul>
 *   <li>0 = 不转</li>
 *   <li>1 = 顺时针 90°（对应 shader 里 uRot=+1）</li>
 *   <li>2 = 180°（uRot=2，shader 里 (x,y)→(-x,-y)）</li>
 *   <li>3 = 顺时针 270° = 逆时针 90°（uRot=-1）</li>
 * </ul>
 *
 * <p>默认值 L=1 / R=3 是 r8 的 ±90° 结论；r10 起由用户在手机上校准。</p>
 */
public final class EyeCalibration {

    private static final String PREFS = "eye_calib";
    private static final String KEY_L = "rotL";
    private static final String KEY_R = "rotR";
    private static final String KEY_SWAP = "swap";
    /** 全局翻转（r15 前的旧键，作用于双眼；保留兼容已保存的校准）。 */
    private static final String KEY_FLIP_H = "flipH";
    private static final String KEY_FLIP_V = "flipV";
    /** r16 起每眼独立翻转。 */
    private static final String KEY_FLIP_LH = "flipLH";
    private static final String KEY_FLIP_LV = "flipLV";
    private static final String KEY_FLIP_RH = "flipRH";
    private static final String KEY_FLIP_RV = "flipRV";

    private EyeCalibration() {
    }

    public static int stepsLeft(Context context) {
        return prefs(context).getInt(KEY_L, 1);
    }

    public static int stepsRight(Context context) {
        return prefs(context).getInt(KEY_R, 3);
    }

    public static boolean swap(Context context) {
        return prefs(context).getBoolean(KEY_SWAP, false);
    }

    public static boolean flipH(Context context) {
        return prefs(context).getBoolean(KEY_FLIP_H, false);
    }

    public static boolean flipV(Context context) {
        return prefs(context).getBoolean(KEY_FLIP_V, false);
    }

    /** 各眼有效翻转 = 全局开关 || 每眼开关。 */
    public static boolean flipHL(Context context) {
        return flipH(context) || prefs(context).getBoolean(KEY_FLIP_LH, false);
    }

    public static boolean flipVL(Context context) {
        return flipV(context) || prefs(context).getBoolean(KEY_FLIP_LV, false);
    }

    public static boolean flipHR(Context context) {
        return flipH(context) || prefs(context).getBoolean(KEY_FLIP_RH, false);
    }

    public static boolean flipVR(Context context) {
        return flipV(context) || prefs(context).getBoolean(KEY_FLIP_RV, false);
    }

    /** 左眼多转 90°，立即生效，返回状态描述。 */
    public static String rotateLeft(Context context) {
        return put(context, KEY_L, stepsLeft(context) + 1);
    }

    /** 右眼多转 90°，立即生效，返回状态描述。 */
    public static String rotateRight(Context context) {
        return put(context, KEY_R, stepsRight(context) + 1);
    }

    /** 交换左右眼画面（两个面板镜像安装时内容反了用它），返回状态描述。 */
    public static String toggleSwap(Context context) {
        SharedPreferences p = prefs(context);
        p.edit().putBoolean(KEY_SWAP, !p.getBoolean(KEY_SWAP, false)).apply();
        return applyAndDescribe(context);
    }

    /** 指定眼睛转 delta 个 90°（delta 可为负），立即生效，返回状态描述。 */
    public static String nudge(Context context, boolean leftEye, int delta) {
        int steps = leftEye ? stepsLeft(context) : stepsRight(context);
        return put(context, leftEye ? KEY_L : KEY_R, steps + delta);
    }

    /** 翻转四态循环：无 → 垂直翻 → 水平翻 → 双翻 → 无。单键可遍历所有翻转组合。 */
    public static String cycleFlip(Context context) {
        SharedPreferences p = prefs(context);
        boolean h = p.getBoolean(KEY_FLIP_H, false);
        boolean v = p.getBoolean(KEY_FLIP_V, false);
        if (!h && !v) {
            v = true;
        } else if (!h) {
            h = true;
            v = false;
        } else if (!v) {
            v = true;
        } else {
            h = false;
            v = false;
        }
        p.edit().putBoolean(KEY_FLIP_H, h).putBoolean(KEY_FLIP_V, v).apply();
        return applyAndDescribe(context);
    }

    /** 全局水平镜像（双眼一起翻），返回状态描述。 */
    public static String toggleFlipH(Context context) {
        SharedPreferences p = prefs(context);
        p.edit().putBoolean(KEY_FLIP_H, !p.getBoolean(KEY_FLIP_H, false)).apply();
        return applyAndDescribe(context);
    }

    /** 全局垂直镜像（双眼一起翻），返回状态描述。 */
    public static String toggleFlipV(Context context) {
        SharedPreferences p = prefs(context);
        p.edit().putBoolean(KEY_FLIP_V, !p.getBoolean(KEY_FLIP_V, false)).apply();
        return applyAndDescribe(context);
    }

    /** 单眼翻转：leftEye 选眼，horizontal 选水平/垂直。 */
    public static String toggleEyeFlip(Context context, boolean leftEye, boolean horizontal) {
        String key = leftEye
                ? (horizontal ? KEY_FLIP_LH : KEY_FLIP_LV)
                : (horizontal ? KEY_FLIP_RH : KEY_FLIP_RV);
        SharedPreferences p = prefs(context);
        p.edit().putBoolean(key, !p.getBoolean(key, false)).apply();
        return applyAndDescribe(context);
    }

    /** 恢复默认（左90° 右270° 不交换）。 */
    public static String reset(Context context) {
        prefs(context).edit().clear().apply();
        return applyAndDescribe(context);
    }

    private static String put(Context context, String key, int steps) {
        int normalized = ((steps % 4) + 4) % 4;
        prefs(context).edit().putInt(key, normalized).apply();
        return applyAndDescribe(context);
    }

    private static String applyAndDescribe(Context context) {
        com.hvr.shell.render.StereoRenderer.applyCalibration(
                stepsLeft(context), stepsRight(context), swap(context),
                flipHL(context), flipVL(context), flipHR(context), flipVR(context));
        return describe(context);
    }

    /** 把保存的校准值套到新建的渲染器上（GlassesOverlay / Activity 挂载时调用）。 */
    public static void apply(Context context, com.hvr.shell.render.StereoRenderer renderer) {
        renderer.setEyeRotationSteps(stepsLeft(context), stepsRight(context), swap(context),
                flipHL(context), flipVL(context), flipHR(context), flipVR(context));
    }

    public static String describe(Context context) {
        return "左" + degrees(stepsLeft(context)) + flipNote(context, true)
                + " 右" + degrees(stepsRight(context)) + flipNote(context, false)
                + (swap(context) ? " 已交换" : "");
    }

    private static String flipNote(Context context, boolean leftEye) {
        boolean h = leftEye ? flipHL(context) : flipHR(context);
        boolean v = leftEye ? flipVL(context) : flipVR(context);
        if (h && v) {
            return "·双翻";
        }
        if (h) {
            return "·横翻";
        }
        if (v) {
            return "·竖翻";
        }
        return "";
    }

    private static String degrees(int steps) {
        switch (((steps % 4) + 4) % 4) {
            case 1:
                return "90°";
            case 2:
                return "180°";
            case 3:
                return "270°";
            default:
                return "0°";
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
