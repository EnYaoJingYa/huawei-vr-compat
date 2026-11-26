package com.huawei.vrframework.compat;

import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.HashMap;
import java.util.Map;

/**
 * 把 Activity 交给「native 真正持有的那一份」SDK 类，消除类副本分裂。
 *
 * <p>取证（2026-11-06，RK3566 / Android 11，冷启动 logcat）：
 *
 * <pre>
 *   W LibUpdateCall: App is 32 bit, but server is 64 bit
 *   E LibUpdateCall: Init remote env failed
 *   I LibUpdateCall: Run update fall back 1.0
 *   I LibUpdate: common app
 *   I LibUpdate: load dex ok                     <- DexClassLoader(hvrframework.dex)
 *   I HvrFramework: SetClass HVR_FRAMEWORK_CLASS_INDEX   (index 0)
 *   I LibUpdate: load class com.huawei.vrframework.VrFramework in index 0 ok
 *   ...
 *   I HvrVrFramework: sdk class loader ready: .../base.apk
 *   I VrFramework: VrFramework init            <- 第二份，由 VrFrameworkBootstrap
 *                                                用 new DexClassLoader(base.apk) 定义
 *   E VrSystemClient: App activity is null
 *   I UnityPlugin: CheckVrMode, is not VRMode, exit
 *   E Unity_HVRRenderMgrCore: Current mode is not VRMode, ApplicationQuit
 * </pre>
 *
 * <p>{@code LibUpdate.loadJarAndClass()} 用 {@code hvrframework.dex} 定义了一个
 * {@code DexClassLoader}（记为 L4），把 {@code VrFramework} 等 5 个 Class 通过
 * {@code LibUpdateClient.loadClass(int, Object)} 交给 native 的 {@code SetClass}。
 * 而 {@code VrFrameworkBootstrap} 另建了一个指向 {@code base.apk} 的
 * {@code DexClassLoader}（L3），把 {@code VrFramework.init(Activity)} 调在 L3 的
 * 副本上。Java 的静态字段是按「类对象」隔离的，于是 native 侧
 * {@code VrFramework.mAppActivity} 永远是 null。
 *
 * <p>这里不再猜加载器：{@link #offer(int, Object)} 在 {@code loadClass} 入口
 * 直接接住 native 收到的 Class 对象本身，{@link #setActivity(Activity)} 在
 * {@code HVRActivity.onCreate()} 最前面记下 Activity，两者齐备时反射调用
 * 那一份 {@code VrFramework.init(Activity)} / {@code VrHelmetExt.init(Activity)}。
 *
 * <p>不新增开机逻辑、不改系统分区、不伪造任何 VR 状态；调用失败只记日志。
 */
public final class HvrSdkBridge {
    private static final String TAG = "HvrSdkBridge";
    private static final String FRAMEWORK = "com.huawei.vrframework.VrFramework";
    private static final String HELMET_EXT = "com.huawei.vrframework.VrHelmetExt";
    private static final String SYSTEM_CLIENT = "com.huawei.vrframework.VrSystemClient";
    private static final String VR_SYSTEM = "vr_system";

    private static final Map<String, Class<?>> CLASSES = new HashMap<String, Class<?>>();
    private static volatile Activity activity;
    private static volatile ClassLoader sdkLoader;
    private static volatile Object vrSystemServiceProxy;
    private static volatile boolean frameworkApplied;
    private static volatile boolean helmetApplied;

    private HvrSdkBridge() {
    }

    /** 由 {@code com.huawei.hvr.LibUpdateClient.loadClass(ILjava/lang/Object;)V} 调用。 */
    public static void offer(int index, Object value) {
        if (!(value instanceof Class)) {
            return;
        }
        Class<?> type = (Class<?>) value;
        Log.i(TAG, "offer[" + index + "] " + type.getName()
                + " loader=" + type.getClassLoader());
        synchronized (CLASSES) {
            CLASSES.put(type.getName(), type);
        }
        if (FRAMEWORK.equals(type.getName())) {
            applyFramework();
        }
        if (HELMET_EXT.equals(type.getName())) {
            applyHelmet();
        }
        if (SYSTEM_CLIENT.equals(type.getName())) {
            sdkLoader = type.getClassLoader();
            createVrSystemProxy();
        }
    }

    /**
     * 由 {@code HVRActivity.getSystemService(String)} 转发。
     *
     * <p>{@code VrSystemClient.init(Activity)} 会 {@code activity.getSystemService("vr_system")}
     * 并把结果 {@code check-cast} 成 {@code hvrframework.dex} 里的
     * {@code android.vrsystem.IVRSystemServiceManager}。EMUI 由框架注册该服务，
     * 通用安卓没有，于是拿到 null 就报
     * {@code VRSystemServiceManager doesn't exist!}，{@code init()} 返回 false，
     * 稍后 {@code VrSystemClient has not be initialized -> deinit -> finish all activity}。
     *
     * <p>这里用「SetClass 那一份类的加载器」动态代理出接口实现，check-cast 才过得去；
     * {@code isVRMode()} 转发到项目已有的 {@code IVRSystemServiceManagerEx} 兼容层
     * （它从 {@code content://com.huawei.vrlauncherx.registry} 取真实 binder），不编数据。
     */
    public static Object getSystemService(String name) {
        if (!VR_SYSTEM.equals(name)) {
            return null;
        }
        Object proxy = vrSystemServiceProxy;
        if (proxy == null) {
            createVrSystemProxy();
            proxy = vrSystemServiceProxy;
        }
        return proxy;
    }

    private static synchronized void createVrSystemProxy() {
        if (vrSystemServiceProxy != null) {
            return;
        }
        ClassLoader loader = sdkLoader;
        if (loader == null) {
            return;
        }
        try {
            Class<?> iface = Class.forName(
                    "android.vrsystem.IVRSystemServiceManager", false, loader);
            vrSystemServiceProxy = Proxy.newProxyInstance(
                    loader, new Class<?>[]{iface}, new VrSystemHandler());
            Log.i(TAG, "vr_system proxy ready on " + loader);
        } catch (Throwable error) {
            Log.w(TAG, "vr_system proxy failed", error);
        }
    }

    /** 由 {@code HVRActivity.onCreate()} 在 {@code LibUpdateClient.runUpdate()} 之前调用。 */
    public static void setActivity(Activity value) {
        activity = value;
        applyFramework();
        applyHelmet();
    }

    private static Class<?> find(String name) {
        synchronized (CLASSES) {
            return CLASSES.get(name);
        }
    }

    private static synchronized void applyFramework() {
        if (frameworkApplied) {
            return;
        }
        Activity act = activity;
        Class<?> type = find(FRAMEWORK);
        if (act == null || type == null) {
            return;
        }
        try {
            Method method = type.getMethod("init", Activity.class);
            method.invoke(null, act);
            frameworkApplied = true;
            Log.i(TAG, "VrFramework.init(Activity) OK on SetClass copy");
        } catch (Throwable error) {
            Log.w(TAG, "VrFramework.init(Activity) failed", error);
        }
    }

    private static synchronized void applyHelmet() {
        if (helmetApplied) {
            return;
        }
        Activity act = activity;
        Class<?> type = find(HELMET_EXT);
        if (act == null || type == null) {
            return;
        }
        try {
            Object instance = type.getMethod("getInstanceObject").invoke(null);
            if (instance == null) {
                return;
            }
            type.getMethod("init", Activity.class).invoke(instance, act);
            helmetApplied = true;
            Log.i(TAG, "VrHelmetExt.init(Activity) OK on SetClass copy");
        } catch (Throwable error) {
            Log.w(TAG, "VrHelmetExt.init(Activity) failed", error);
        }
    }

    /** 只响应 VrSystemClient.init() 真正会调用的几个方法，其余给类型默认值。 */
    private static final class VrSystemHandler implements InvocationHandler {
        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            if ("isVRMode".equals(name)) {
                return realIsVRMode();
            }
            if ("asBinder".equals(name)) {
                return new Binder();
            }
            if ("registerVRListener".equals(name)
                    || "registerExpandListener".equals(name)
                    || "unregisterVRListener".equals(name)) {
                // 记下监听者即可；VrSystemActor 的 onVrModeChanged 由系统服务 binder 驱动。
                return null;
            }
            Class<?> ret = method.getReturnType();
            if (ret == boolean.class) {
                return Boolean.FALSE;
            }
            if (ret == int.class) {
                return Integer.valueOf(0);
            }
            if (ret == long.class) {
                return Long.valueOf(0L);
            }
            if (ret == float.class) {
                return Float.valueOf(0f);
            }
            if (ret == double.class) {
                return Double.valueOf(0d);
            }
            return null;
        }

        /**
         * 走桌面原本的线协议直接问 VrSystemActor，而不是套 IVRSystemService 的
         * AIDL 包装 —— SystemServiceBinder 只认 code=2 / what=0x835
         * (getVRModeState)，套 AIDL 会拿到默认值 0，Unity 就误判「非 VR 模式」。
         * 读的是 actor.isVrMode() 的真实结果（vrMode && helmetPresent），不编数据。
         */
        private boolean realIsVRMode() {
            Activity act = activity;
            if (act == null) {
                return false;
            }
            IBinder binder = null;
            try {
                Bundle answer = act.getContentResolver().call(
                        Uri.parse("content://com.huawei.vrlauncherx.registry"),
                        "getService", "vr_system_state", null);
                if (answer != null) {
                    binder = answer.getBinder("binder");
                }
            } catch (Throwable error) {
                Log.w(TAG, "vr_system_state registry lookup failed", error);
                return false;
            }
            if (binder == null) {
                Log.w(TAG, "vr_system_state binder not published yet");
                return false;
            }
            Parcel data = Parcel.obtain();
            Parcel reply = Parcel.obtain();
            try {
                data.writeInterfaceToken("com.huawei.vrservice.ISysServiceInterface");
                data.writeInt(0x835);   // getVRModeState
                data.writeInt(0);       // 参数个数
                binder.transact(2, data, reply, 0);
                reply.readException();
                int value = reply.readInt();
                boolean mode = (value & 1) != 0;
                Log.i(TAG, "getVRModeState -> " + value + " isVRMode=" + mode);
                return mode;
            } catch (Throwable error) {
                Log.w(TAG, "getVRModeState failed", error);
                return false;
            } finally {
                data.recycle();
                reply.recycle();
            }
        }
    }
}
