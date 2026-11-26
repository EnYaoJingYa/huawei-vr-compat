package com.huawei.hvrsdkserverapp.compat;

import android.content.Context;
import android.net.Uri;
import android.os.Bundle;
import android.os.IBinder;
import android.util.Log;

/**
 * 把 {@link SystemServiceBinder} 也发布到桌面托管的注册表，供别的进程读真值。
 *
 * <p>背景（2026-11-06）：{@code vr_system} 注册表里的 binder 是桌面自己的
 * {@code t0/b}（IVRSystemService.Stub），它的 {@code isVRmode()} 走
 * {@code z0/c.n() -> t0/a.e()}。而 {@code t0/a.e()} 里那个
 * {@code SystemServiceBinder} 只通过 handshake 注入了 VRService 进程，
 * launcherx 进程里的 {@code t0/a} 是空的，于是 getVRModeState 恒 0，
 * Unity 的 {@code CheckVrMode} 判「非 VR 模式」直接 {@code ApplicationQuit}。
 *
 * <p>这里不改任何状态、不代答：只是把已经在 {@code VrSystemActor} 里存在的、
 * 会真实回答 {@code code=2 / what=0x835} 的那个 binder，多发布一份到
 * {@code vr_system_state}。查询方拿到后照样走原线协议问
 * {@code actor.isVrMode()}（= vrMode && helmetPresent）。
 */
public final class HvrStatePublisher {
    private static final String TAG = "HvrStatePublisher";
    public static final String NAME = "vr_system_state";

    private HvrStatePublisher() {
    }

    public static void publish(Context context, IBinder binder) {
        if (context == null || binder == null) {
            return;
        }
        try {
            Bundle extras = new Bundle();
            extras.putString("name", NAME);
            extras.putBinder("binder", binder);
            Bundle answer = context.getContentResolver().call(
                    Uri.parse("content://com.huawei.vrlauncherx.registry"),
                    "putService", NAME, extras);
            Log.i(TAG, "published " + NAME + ": " + (answer != null));
        } catch (Throwable error) {
            Log.w(TAG, "publish " + NAME + " failed", error);
        }
    }
}
