package com.hvr.shell;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 开机 / 应用更新后把总控服务拉起来。
 *
 * 这一步是「不需要多余操作」的起点：用户重启手机后不做任何事，插上眼镜就能进
 * VR 桌面。BOOT_COMPLETED 是平台明确允许启动前台服务的场景之一，所以这里不需要
 * 额外豁免。
 */
public final class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        ShellState.event("开机广播 " + action);
        ShellService.ensureRunning(context);
    }
}
