package com.hvr.shell;

import android.accessibilityservice.AccessibilityService;
import android.content.Intent;
import android.view.KeyEvent;

import com.hvr.shell.cast.DisplayFinder;

/**
 * 手柄/眼镜触板的<b>全局按键接管</b>——修「手柄在桌面上不能用」的根。
 *
 * <p>根因：HUAWEI GLASS HID（眼镜手柄通道）是键盘源输入设备，事件只发给
 * <b>手机默认屏当前聚焦的窗口</b>。手机停在桌面/锁屏/其他应用时，{@link ShellActivity}
 * 不在前台，它的 dispatchKeyEvent 永远收不到——眼镜里的桌面就成了「看得见摸不着」。</p>
 *
 * <p>解法：AccessibilityService 的 {@link #onKeyEvent} 是系统级按键过滤器，
 * 无论前台是谁都能先拿到硬件按键。无 root、无系统权限，用户在无障碍设置里
 * 开一次即可（ShellActivity 里的「手柄全局接管」按钮直达）。</p>
 *
 * <p>克制原则：只在<b>眼镜在位</b>（桌面实际可见）时截获按键，其余情况全部
 * 放行给系统——手机上的方向键、返回键行为不变。识别不了的键码打一条日志，
 * 方便后续把 CF20 的私有键位补全。</p>
 */
public final class HvrInputService extends AccessibilityService {

    private static volatile HvrInputService instance;

    /** 用户是否已在无障碍设置里开启（ShellActivity 状态栏显示用）。 */
    public static boolean isActive() {
        return instance != null;
    }

    @Override
    protected void onServiceConnected() {
        instance = this;
        ShellState.event("手柄全局接管已启用：眼镜在位时按键直达 VR 桌面");
    }

    @Override
    public boolean onUnbind(Intent intent) {
        instance = null;
        ShellState.event("手柄全局接管已关闭");
        return super.onUnbind(intent);
    }

    /** 已打过程日志的键码：同码只打一次，不刷屏。 */
    private final java.util.Set<Integer> loggedKeys = new java.util.HashSet<>();
    /** r24：前若干个按键无条件记日志，用来判断「到底有没有收到」而不是「映射丢失」。 */
    private int arrivalCount;

    @Override
    protected boolean onKeyEvent(KeyEvent event) {
        // 眼镜不在位 = 桌面不可见：按键与 VR 无关，全部放行。
        // r24：DisplayFinder 依赖 DisplayManager 枚举，插拔瞬间可能为空；用服务轮询的
        // glassPresent 兜底，避免「眼镜在位但过滤全放行」的假死。
        if (DisplayFinder.find(this) == null && !ShellState.glassPresent) {
            return false;
        }
        int action = event.getAction();
        if (action != KeyEvent.ACTION_DOWN && action != KeyEvent.ACTION_UP) {
            return false;
        }
        if (action == KeyEvent.ACTION_DOWN && arrivalCount < 16) {
            arrivalCount++;
            ShellState.event("按键到达[" + arrivalCount + "] code=" + event.getKeyCode()
                    + " source=0x" + Integer.toHexString(event.getSource()));
        }
        // 统一路由（含校准模式与长按检测），与 Activity 手柄路径完全一致。
        boolean consumed = DesktopPresenter.get().handleKey(this,
                action == KeyEvent.ACTION_DOWN, translateMediaKey(event.getKeyCode()));
        if (!consumed && action == KeyEvent.ACTION_DOWN
                && loggedKeys.add(event.getKeyCode())) {
            ShellState.event("手柄新键码 " + event.getKeyCode()
                    + "（未映射；如有按键无反应请反馈此数字）");
        }
        return consumed;
    }

    @Override
    public void onAccessibilityEvent(android.view.accessibility.AccessibilityEvent event) {
        // 不需要窗口事件，只为按键过滤存活。
    }

    /**
     * r27：眼镜本体（USB HID，/dev/input/event7）只声明了媒体键：
     * 0xa3 下一曲 / 0xa4 播放暂停 / 0xa5 上一曲 / 0xa6 停止，外加音量键。
     * 手柄的 CF20 私有通道（GATT）目前拿不到，但这几个键是现成的输入源，
     * 映射成桌面导航，至少能「用眼镜上的按键」把指针移起来并确认。
     */
    private static int translateMediaKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_MEDIA_STOP:
            case KeyEvent.KEYCODE_HEADSETHOOK:
                return KeyEvent.KEYCODE_DPAD_CENTER;
            case KeyEvent.KEYCODE_MEDIA_NEXT:
                return KeyEvent.KEYCODE_DPAD_RIGHT;
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                return KeyEvent.KEYCODE_DPAD_LEFT;
            case KeyEvent.KEYCODE_VOLUME_UP:
                return KeyEvent.KEYCODE_DPAD_UP;
            case KeyEvent.KEYCODE_VOLUME_DOWN:
                return KeyEvent.KEYCODE_DPAD_DOWN;
            default:
                return keyCode;
        }
    }

    @Override
    public void onInterrupt() {
        // 无播报，无需要中断的内容。
    }
}
