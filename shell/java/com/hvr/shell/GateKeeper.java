package com.hvr.shell;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;

/**
 * 门禁唤醒器。
 *
 * EMUI 在「VR 模式」下会拦截一切 vr_only Activity 的启动，直到
 * {@code vr_system} 系统服务注册——而注册者是 com.huawei.vrservice 包的
 * VRService，该包所有组件都未导出或带签名权限守卫，外部无法直接启动。
 *
 * 两个唤醒点：
 * <ol>
 *   <li><b>client 进程</b>：vrlauncherx 的 {@code VrStateService}（exported
 *       无守卫，跑在 com.huawei.vrservice 进程里）——把进程带起来，满足
 *       「进程存活」类检查（已实机验证）；</li>
 *   <li><b>vrservice 包停止态</b>：该包若处于 stopped 态，插镜的
 *       USB_DEVICE_ATTACHED 广播会被系统整个丢弃（EMUI 连 am 的
 *       include-stopped 标志都阉了）。用<b>应用内代码</b>带
 *       {@link Intent#FLAG_INCLUDE_STOPPED_PACKAGES} 向它的导出
 *       UsbReceiver 投递显式广播：receiver 内部校验 action 不匹配会静默
 *       返回，但 AMS 为投递广播新建进程时会<b>顺带清除 stopped 标志</b>——
 *       之后真实插镜广播就能进入正常链路。</li>
 * </ol>
 *
 * 本类只做唤醒，不 bind、不依赖返回值；幂等可重复调用。
 */
public final class GateKeeper {

    private static final ComponentName CLIENT_STATE = new ComponentName(
            "com.huawei.vrlauncherx",
            "com.huawei.client.vrservice.VrStateService");

    /** vrservice 包的导出 receiver：广播只用于「拉进程清停止态」，action 是任意的。 */
    private static final ComponentName VR_SERVICE_USB = new ComponentName(
            "com.huawei.vrservice", "com.huawei.vrservice.UsbReceiver");

    /** 唤醒节流：进程被拉起后不会马上死，没必要每次都打。 */
    private static final long THROTTLE_MS = 60_000L;

    private static long lastWakeAt;

    private GateKeeper() {
    }

    /** 拉起 client 进程并清除 vrservice 停止态。失败只记日志不抛出。 */
    public static void wake(Context context, String reason) {
        long now = System.currentTimeMillis();
        if (now - lastWakeAt < THROTTLE_MS) {
            return;
        }
        lastWakeAt = now;
        wakeClientProcess(context, reason);
        wakeVrServicePackage(context, reason);
    }

    /** 强制唤醒（绕过节流），用于开机广播等低频高价值场景。 */
    public static void wakeNow(Context context, String reason) {
        lastWakeAt = 0L;
        wake(context, reason);
    }

    private static void wakeClientProcess(Context context, String reason) {
        Intent intent = new Intent();
        intent.setComponent(CLIENT_STATE);
        try {
            context.startService(intent);
            ShellState.event("已唤醒 VR 客户端进程（" + reason + "）");
        } catch (Throwable error) {
            ShellState.event("唤醒 VR 客户端失败（" + reason + "）", error);
        }
    }

    /**
     * 显式广播 + FLAG_INCLUDE_STOPPED_PACKAGES：只为把 vrservice 包从
     * stopped 态里捞出来（AM 新建进程时清标志），receiver 不会执行任何逻辑。
     */
    private static void wakeVrServicePackage(Context context, String reason) {
        try {
            Intent intent = new Intent("com.hvr.shell.action.WAKE_VRSERVICE");
            intent.setComponent(VR_SERVICE_USB);
            intent.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
            context.sendBroadcast(intent);
            ShellState.event("已投递 vrservice 唤醒广播（" + reason + "）");
        } catch (Throwable error) {
            ShellState.event("vrservice 唤醒广播失败（" + reason + "）", error);
        }
    }
}
