package com.hvr.shell;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * VR 桌面里的应用：能装什么、钉了哪些、怎么起。
 *
 * 「添加应用」不是让用户填包名，而是把手机里所有有启动入口的应用列出来让用户挑，
 * 挑中的写进 SharedPreferences（按包名保序），VR 桌面上就多一个格子。
 *
 * 只收有 LAUNCHER 入口的应用：没有入口的包（服务、插件）用户点不开，列出来只会添乱。
 */
final class AppCatalog {

    private static final String PREFS = "apps";
    private static final String KEY_PINNED = "pinned";
    /** 桌面一屏最多放 8 个（4 列 x 2 行），第 9 格永远留给「＋」。 */
    static final int MAX_PINNED = 8;

    /** 首次启动的默认钉选候选：按优先级，存在的才上桌面。 */
    private static final String[] DEFAULT_CANDIDATES = {
            "com.huawei.camera",        // 相机
            "com.android.settings",     // 设置
            "com.huawei.photos",        // 图库
            "com.huawei.video",         // 视频
            "com.huawei.music",         // 音乐
            "com.huawei.browser",       // 浏览器
    };

    /** 挑出手机上真实存在的默认应用（有启动入口才算）。 */
    private static List<Entry> seedDefaults(Context context) {
        PackageManager pm = context.getPackageManager();
        List<Entry> result = new ArrayList<>();
        for (String pkg : DEFAULT_CANDIDATES) {
            if (result.size() >= 6) {
                break;
            }
            try {
                CharSequence label = pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0));
                if (pm.getLaunchIntentForPackage(pkg) != null && label != null) {
                    result.add(new Entry(pkg, label.toString().trim()));
                }
            } catch (Throwable ignored) {
                // 手机上没装，跳过。
            }
        }
        return result;
    }

    static final class Entry {
        final String packageName;
        final String label;

        Entry(String packageName, String label) {
            this.packageName = packageName;
            this.label = label;
        }
    }

    /** 应用图标缓存：VR 桌面每次重画都要用，真实图标解析开销不小。 */
    private static final android.util.LruCache<String, android.graphics.Bitmap> ICONS =
            new android.util.LruCache<String, android.graphics.Bitmap>(32) {
                @Override
                protected void entryRemoved(boolean evicted, String key,
                                            android.graphics.Bitmap old, android.graphics.Bitmap fresh) {
                    if (old != null && old != fresh) {
                        old.recycle();
                    }
                }
            };

    /** 取应用图标（方图 sizePx 像素），失败返回 null（调用方画占位）。 */
    static android.graphics.Bitmap icon(Context context, String packageName, int sizePx) {
        String key = packageName + "@" + sizePx;
        android.graphics.Bitmap cached = ICONS.get(key);
        if (cached != null && !cached.isRecycled()) {
            return cached;
        }
        try {
            android.graphics.drawable.Drawable drawable = context.getPackageManager()
                    .getApplicationIcon(packageName);
            android.graphics.Bitmap bitmap = android.graphics.Bitmap.createBitmap(
                    sizePx, sizePx, android.graphics.Bitmap.Config.ARGB_8888);
            android.graphics.Canvas canvas = new android.graphics.Canvas(bitmap);
            drawable.setBounds(0, 0, sizePx, sizePx);
            drawable.draw(canvas);
            ICONS.put(key, bitmap);
            return bitmap;
        } catch (Throwable error) {
            return null;
        }
    }

    private AppCatalog() {
    }

    /** 手机里所有可以启动的应用，按名称排序。 */
    static List<Entry> listLaunchable(Context context) {
        List<Entry> result = new ArrayList<>();
        PackageManager pm = context.getPackageManager();
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> resolved;
        try {
            resolved = pm.queryIntentActivities(intent, 0);
        } catch (Throwable error) {
            ShellState.event("查询已安装应用失败", error);
            return result;
        }
        Set<String> seen = new LinkedHashSet<>();
        for (ResolveInfo info : resolved) {
            if (info == null || info.activityInfo == null) {
                continue;
            }
            String pkg = info.activityInfo.packageName;
            if (pkg == null || pkg.equals(context.getPackageName()) || !seen.add(pkg)) {
                continue;
            }
            CharSequence label = info.loadLabel(pm);
            result.add(new Entry(pkg, label == null ? pkg : label.toString().trim()));
        }
        Collections.sort(result, new Comparator<Entry>() {
            @Override
            public int compare(Entry left, Entry right) {
                return left.label.compareToIgnoreCase(right.label);
            }
        });
        return result;
    }

    /** 当前钉在 VR 桌面上的应用（按用户添加顺序）。 */
    static List<Entry> pinned(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (!prefs.contains(KEY_PINNED)) {
            // 首次使用：seed 一组常见应用（只收真实有启动入口的），避免空桌面。
            List<Entry> seeded = seedDefaults(context);
            savePinned(context, seeded);
            return new ArrayList<>(seeded);
        }
        String stored = prefs.getString(KEY_PINNED, "");
        List<Entry> result = new ArrayList<>();
        if (stored == null || stored.isEmpty()) {
            return result;
        }
        PackageManager pm = context.getPackageManager();
        for (String pkg : stored.split("\n")) {
            if (pkg.trim().isEmpty()) {
                continue;
            }
            String label = pkg;
            try {
                label = pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString();
            } catch (Throwable ignored) {
                // 应用被卸载了：保留记录，但显示包名；下次打开添加界面时会被清理。
            }
            result.add(new Entry(pkg, label));
        }
        return result;
    }

    static void savePinned(Context context, List<Entry> entries) {
        StringBuilder builder = new StringBuilder();
        for (Entry entry : entries) {
            if (builder.length() > 0) {
                builder.append('\n');
            }
            builder.append(entry.packageName);
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY_PINNED, builder.toString()).apply();
        ShellState.event("VR 桌面应用已更新：" + entries.size() + " 个");
    }

    static void addPinned(Context context, Entry entry) {
        List<Entry> current = pinned(context);
        for (Entry existing : current) {
            if (existing.packageName.equals(entry.packageName)) {
                return;
            }
        }
        if (current.size() >= MAX_PINNED) {
            ShellState.event("桌面已满（最多 " + MAX_PINNED + " 个），先移除一个");
            return;
        }
        current.add(entry);
        savePinned(context, current);
    }

    static void removePinned(Context context, String packageName) {
        List<Entry> current = pinned(context);
        for (int i = current.size() - 1; i >= 0; i--) {
            if (current.get(i).packageName.equals(packageName)) {
                current.remove(i);
            }
        }
        savePinned(context, current);
    }

    /**
     * 启动应用。
     *
     * 用的是包管理器给的标准启动意图，和用户点桌面图标是同一条路径——不伪造、
     * 也不要求对方配合。被启动的应用显示在手机屏上，再由 VR 的投屏链路拉进眼镜
     * （MediaProjection 需要用户点一次录屏授权，这是平台限制，绕不过去）。
     */
    static boolean launch(Context context, String packageName) {
        PackageManager pm = context.getPackageManager();
        Intent intent = pm.getLaunchIntentForPackage(packageName);
        if (intent == null) {
            ShellState.event("应用没有启动入口：" + packageName);
            return false;
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            context.startActivity(intent);
            ShellState.event("已启动应用：" + packageName);
            return true;
        } catch (Throwable error) {
            ShellState.event("启动应用失败：" + packageName, error);
            return false;
        }
    }
}
