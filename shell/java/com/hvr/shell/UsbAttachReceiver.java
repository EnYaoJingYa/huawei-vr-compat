package com.hvr.shell;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 眼镜插拔的即时通知。
 *
 * 服务里已经注册了同样的监听，这个静态接收器是「服务刚被系统杀掉、还没来得及
 * 重启」时的补位：收到插拔就顺手把服务叫起来。重复启动是幂等的。
 */
public final class UsbAttachReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent == null ? null : intent.getAction();
        ShellState.event("眼镜插拔广播 " + action);
        ShellService.ensureRunning(context);
    }
}
