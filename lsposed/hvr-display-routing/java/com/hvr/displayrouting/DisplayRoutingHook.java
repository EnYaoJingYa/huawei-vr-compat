package com.hvr.displayrouting;

import android.content.Context;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.os.Build;

import java.util.HashSet;
import java.util.Set;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * 放行华为 VR 七包在通用安卓上需要、但只有系统签名才拿得到的两类能力。
 *
 * 一、把 VR 活动启动到自建虚拟屏上（文档 docs/PATCH_AUDIT.md 第 65/66 节）
 *
 * 原版在 EMUI 的 VR 模式里把 VR 应用放到 `HUAWEI VR Display` 那块虚拟屏上。
 * 通用安卓里我们自己用公开 API 建了同一块屏（名字、尺寸都对齐），但往它上面
 * 启动活动会被平台拒绝：
 *
 *     SecurityException: Permission Denial: starting Intent {...}
 *       from ProcessRecord{...} (pid=..., uid=10421) with launchDisplayId=27
 *
 * 原因是 `ActivityTaskSupervisor.isCallerAllowedToLaunchOnDisplay` 先判
 * 「这块屏是否 trusted」——非系统进程建的虚拟屏都不 trusted，于是连屏的
 * 拥有者自己也不放行；要过这一关需要 `INTERNAL_SYSTEM_WINDOW`（signature 级）。
 *
 * 二、投屏页自己的屏幕采集（`CaptureDisplay.java`）
 *
 * 投屏包用 `DisplayManager.createVirtualDisplay(..., AUTO_MIRROR)` 把手机默认屏
 * 采集成 GL 纹理（`b/a/c/f/a0`，flags 0x14 = AUTO_MIRROR | SECURE）。这个调用在
 * 平台侧要求 `CAPTURE_VIDEO_OUTPUT`（signature|privileged），普通应用签名拿不到，
 * 会抛 `SecurityException: Requires CAPTURE_VIDEO_OUTPUT permission`。
 * 原版靠系统 UID 天然持有；这里只对我们这七个包、且只对这两个采集权限放行。
 *
 * 模块只改这两处判断：调用方必须是我们这七个包之一；其它应用、默认屏、
 * 其它权限一律不干预。
 */
public final class DisplayRoutingHook implements IXposedHookLoadPackage {
    private static final String TAG = "HvrDisplayRouting";

    private static final String SUPERVISOR = "com.android.server.wm.ActivityTaskSupervisor";
    private static final String METHOD = "isCallerAllowedToLaunchOnDisplay";
    private static final String ACTIVITY_MANAGER = "com.android.server.am.ActivityManagerService";

    /** 只放行华为 VR 这七个包（原版六个 + 从固件提取的 vrservice）。 */
    private static final String[] PACKAGES = {
            "com.huawei.vrlauncherx",
            "com.huawei.himovie.vr",
            "com.huawei.vrvirtualscreen",
            "com.huawei.appmarket.vr",
            "com.huawei.vrhandle",
            "com.huawei.hvrsdkserverapp",
            "com.huawei.vrservice",
    };

    /** 只放行投屏/系统应用在 EMUI 上天然持有的采集权限。 */
    private static final Set<String> CAPTURE_PERMISSIONS = new HashSet<>();

    static {
        CAPTURE_PERMISSIONS.add("android.permission.CAPTURE_VIDEO_OUTPUT");
        CAPTURE_PERMISSIONS.add("android.permission.CAPTURE_SECURE_VIDEO_OUTPUT");
    }

    private static Set<Integer> ourUids;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam param) {
        if (!"android".equals(param.packageName)) {
            return;
        }
        hookDisplayLaunch(param);
        hookCapturePermission(param);
    }

    private void hookDisplayLaunch(XC_LoadPackage.LoadPackageParam param) {
        try {
            XposedHelpers.findAndHookMethod(SUPERVISOR, param.classLoader, METHOD,
                    int.class, int.class, int.class, ActivityInfo.class,
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam call) {
                            int callingUid = (Integer) call.args[0];
                            int launchDisplayId = (Integer) call.args[2];
                            if (launchDisplayId <= 0) {
                                return;   // 默认屏，原样走原逻辑
                            }
                            if (isOurUid(call.thisObject, callingUid)) {
                                XposedBridge.log(TAG + ": allow uid " + callingUid
                                        + " to launch on display " + launchDisplayId);
                                call.setResult(Boolean.TRUE);
                            }
                        }
                    });
            XposedBridge.log(TAG + ": hooked " + SUPERVISOR + "#" + METHOD);
        } catch (Throwable error) {
            XposedBridge.log(TAG + ": hook failed on SDK " + Build.VERSION.SDK_INT
                    + " -> " + error);
        }
    }

    /**
     * 投屏页的 `DisplayManager.createVirtualDisplay(..., AUTO_MIRROR)` 在平台里
     * 走 `Context.checkCallingPermission(CAPTURE_VIDEO_OUTPUT)` →
     * `ActivityManagerService.checkPermission(String, int, int)`。
     * 只对七包 + 两个采集权限返回 GRANTED。
     */
    private void hookCapturePermission(XC_LoadPackage.LoadPackageParam param) {
        try {
            XposedHelpers.findAndHookMethod(ACTIVITY_MANAGER, param.classLoader,
                    "checkPermission", String.class, int.class, int.class,
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam call) {
                            String permission = (String) call.args[0];
                            int uid = (Integer) call.args[2];
                            if (permission != null
                                    && CAPTURE_PERMISSIONS.contains(permission)
                                    && isOurUid(call.thisObject, uid)) {
                                XposedBridge.log(TAG + ": allow uid " + uid
                                        + " permission " + permission);
                                call.setResult(PackageManager.PERMISSION_GRANTED);
                            }
                        }
                    });
            XposedBridge.log(TAG + ": hooked " + ACTIVITY_MANAGER
                    + "#checkPermission (capture)");
        } catch (Throwable error) {
            XposedBridge.log(TAG + ": capture hook failed on SDK "
                    + Build.VERSION.SDK_INT + " -> " + error);
        }
    }

    /** 调用方的 uid 是否属于我们这七个包。 */
    private static boolean isOurUid(Object host, int uid) {
        Set<Integer> known = ourUids;
        if (known != null) {
            return known.contains(uid);
        }
        Set<Integer> found = new HashSet<>();
        try {
            Context context = systemContext(host);
            if (context != null) {
                PackageManager manager = context.getPackageManager();
                for (String packageName : PACKAGES) {
                    try {
                        found.add(manager.getPackageUid(packageName, 0));
                    } catch (Throwable ignored) {
                        // 该包没装，跳过
                    }
                }
                if (!found.isEmpty()) {
                    ourUids = found;
                }
            }
        } catch (Throwable error) {
            XposedBridge.log(TAG + ": uid lookup failed: " + error);
        }
        return found.contains(uid);
    }

    /**
     * 从 system_server 的对象里取系统 Context。
     * `ActivityTaskSupervisor.mService` → `ActivityTaskManagerService`，
     * 它的 `mContext` 就是 system_server 的 Context；
     * `ActivityManagerService` 自己就有 `mContext`。
     * 字段名随 ROM 走，取不到就退化成「每次都重新查一遍」，不影响功能。
     */
    private static Context systemContext(Object host) {
        try {
            Object service = XposedHelpers.getObjectField(host, "mService");
            if (service != null) {
                return (Context) XposedHelpers.getObjectField(service, "mContext");
            }
        } catch (Throwable ignored) {
            // 不是 ActivityTaskSupervisor，继续试下面的字段
        }
        try {
            return (Context) XposedHelpers.getObjectField(host, "mContext");
        } catch (Throwable error) {
            XposedBridge.log(TAG + ": system context unavailable: " + error);
            return null;
        }
    }
}
