package com.huawei.vrvirtualscreen.mirror;

import android.app.Activity;
import android.content.Intent;
import android.util.Log;

/**
 * 点开「VR 手机投屏」图标时的默认入口：直接进免 root 投屏流程。
 *
 * 这里**不再**先判断眼镜副屏是否存在：先把系统的录屏授权弹出来，授权后再由
 * {@link HvrMirrorActivity} 检查副屏。否则眼镜没被识别成第二块屏时，用户只会
 * 看到原帮助页，连授权框都不会出现。
 */
public final class HvrMirrorEntry {

    private static final String TAG = "HvrMirrorEntry";

    private HvrMirrorEntry() {
    }

    public static void start(Activity activity) {
        if (activity == null) {
            return;
        }
        try {
            activity.startActivity(new Intent(activity, HvrMirrorActivity.class));
            activity.finish();
        } catch (Throwable error) {
            Log.w(TAG, "cannot start the mirror activity: " + error);
        }
    }
}
