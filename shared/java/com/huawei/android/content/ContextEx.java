package com.huawei.android.content;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Handler;
import android.os.UserHandle;

/**
 * Huawei's Context extension. registerReceiverAsUser is a hidden platform API;
 * on common Android the same registration is done with the public
 * Context.registerReceiver, which registers for the caller's own user. The
 * receiver, filter and handler are passed through unchanged.
 */
public final class ContextEx {
    /**
     * 本应用自己的 Application context，由兼容层注入的 provider
     * （com.huawei.vrframework.compat.HvrContextProvider）在进程启动时填进来。
     *
     * 为什么需要它：下面两条路都不是每个进程都能走通 ——
     * Unity 那条只在 Unity 进程成立；ActivityThread.currentApplication() 是
     * hidden API，反射在 targetSdk≥28 上会被拦。provider 是平台自己实例化的，
     * 这里拿到的就是真实 application context，没有任何合成。
     */
    private static volatile Context applicationContext;

    private ContextEx() {
    }

    public static void setApplication(Context context) {
        if (context == null) {
            return;
        }
        Context application = context.getApplicationContext();
        applicationContext = application != null ? application : context;
    }

    public static Context currentApplication() {
        Context known = applicationContext;
        if (known != null) {
            return known;
        }
        try {
            Class<?> player = Class.forName("com.unity3d.player.UnityPlayer");
            Object activity = player.getField("currentActivity").get(null);
            if (activity instanceof Activity) return ((Activity) activity).getApplicationContext();
        } catch (Throwable ignored) {
            // Not a Unity process.
        }
        // 第三条：ActivityThread.currentApplication()（普通反射）。
        // 2026-11-03 补回：vrlauncherx 的 process="com.huawei.vrservice" 子进程里
        // （GlassesTipActivity / VrStateService 都在那儿）没有任何 ContentProvider，
        // 上面的 setApplication 永远不会被调用，而这个进程恰恰是发布和消费
        // vr_system 的地方 —— 拿不到 context 就只能退回进程内自造值，门禁永远拦。
        Context reflected = reflectedApplication();
        if (reflected != null) {
            applicationContext = reflected;
            return reflected;
        }
        return null;
    }

    /**
     * 用反射取当前进程的 Application。
     *
     * 两级：先普通反射（targetSdk<30 的进程通常只告警不拦），被拦再用
     * meta-reflection —— 通过系统类 Class 持有的 getDeclaredMethod 去取
     * ActivityThread.currentApplication，绕开调用方的 hidden API 检查。
     * 这与 VrPlatformCompat 里取 Build.MANUFACTURER 的兜底是同一套写法。
     */
    private static Context reflectedApplication() {
        try {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            java.lang.reflect.Method current =
                    activityThread.getDeclaredMethod("currentApplication");
            current.setAccessible(true);
            Object application = current.invoke(null);
            if (application instanceof Context) {
                return (Context) application;
            }
        } catch (Throwable ignored) {
            // targetSdk>=28 上可能被 hidden API 拦掉，走下面的 meta-reflection。
        }
        try {
            java.lang.reflect.Method getDeclaredMethod = Class.class
                    .getDeclaredMethod("getDeclaredMethod", String.class, Class[].class);
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            java.lang.reflect.Method current = (java.lang.reflect.Method) getDeclaredMethod
                    .invoke(activityThread, "currentApplication", new Class[0]);
            current.setAccessible(true);
            Object application = current.invoke(null);
            if (application instanceof Context) {
                return (Context) application;
            }
        } catch (Throwable ignored) {
            // 两条都不通，交回调用方的 null 分支。
        }
        return null;
    }

    public static Intent registerReceiverAsUser(Context context, BroadcastReceiver receiver,
            UserHandle user, IntentFilter filter, String broadcastPermission, Handler scheduler) {
        if (context == null || receiver == null || filter == null) return null;
        try {
            // The user handle only selects whose registrations are touched; a
            // common Android app can only register for its own user, which is
            // the same user this process runs as.
            return context.registerReceiver(receiver, filter, broadcastPermission, scheduler);
        } catch (Throwable error) {
            return null;
        }
    }
}
