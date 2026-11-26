package com.hvr.shell;

import android.util.Log;

/**
 * 独立应用的运行状态，供前台服务与界面共用。
 *
 * 全部是 volatile 字段：界面只读、服务只写，不加锁。这里存的是「实际发生了什么」，
 * 不是「希望发生什么」——拉不起来就如实写失败原因，界面照原样显示。
 */
final class ShellState {

    static final String TAG = "HvrShell";

    /** 眼镜在位（USB 身份 + 外接屏两个信号同时成立）。 */
    static volatile boolean glassPresent;
    /** USB 身份单独成立，用于区分「线插了但屏没起来」。 */
    static volatile boolean usbIdentity;
    /** 外接屏名字，没接时为 null。 */
    static volatile String displayName;

    /** 原版环境最后一次拉起的结果。 */
    static volatile String environmentNote = "未请求";
    static volatile long environmentLastMs;

    /** 手柄链路状态。 */
    static volatile String controllerNote = "未开始";

    /** 本地文件权限与扫描结果。 */
    static volatile String fileNote = "未检查";

    /** 服务启动时刻 / 最后一次事件，界面上用来判断「还活着吗」。 */
    static volatile long serviceStartedAt;
    static volatile String lastEvent = "-";

    private ShellState() {
    }

    static void event(String message) {
        lastEvent = message;
        Log.i(TAG, message);
    }

    static void event(String message, Throwable error) {
        lastEvent = message + ": " + error;
        Log.w(TAG, message, error);
    }
}
