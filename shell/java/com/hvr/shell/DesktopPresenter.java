package com.hvr.shell;

import android.content.Context;
import android.graphics.Bitmap;

import com.hvr.shell.pose.PoseHub;

import java.util.ArrayList;
import java.util.List;

/**
 * VR 桌面的状态中枢：应用列表、指针位置、选中格子、面板内容发布。
 *
 * <p>为什么单拎一个单例：桌面有<b>两个宿主</b>——手机上的 {@link ShellActivity}
 * （触控板 + 预览）和 {@link ShellService} 直驱的 {@link GlassesOverlay}（眼镜屏）。
 * 两者必须看到同一份桌面：同一个应用网格、同一根指针、同一个选中格。谁有输入
 * （触控板滑动、手柄移动、抬手确认）就调 {@link #movePointer} / {@link #confirm}，
 * 内容变了统一走 {@link #publish} 重画位图交给 {@link com.hvr.shell.render.HomeScene}。</p>
 *
 * <p>只在主线程使用（位图绘制 + GL 上传都按主线程约定设计）。</p>
 */
final class DesktopPresenter {

    private static final DesktopPresenter INSTANCE = new DesktopPresenter();

    static DesktopPresenter get() {
        return INSTANCE;
    }

    /** 已钉住的应用（顺序 = 桌面格子顺序）。 */
    final List<AppCatalog.Entry> pinnedApps = new ArrayList<>();

    /** 指针状态，面板像素坐标。 */
    float pointerX = VrUi.PANEL_WIDTH / 2f;
    float pointerY = VrUi.PANEL_HEIGHT / 2f;
    boolean pointerVisible;

    /** 当前选中的格子（-1 = 无）。{@link HomeContent} 画高亮用。 */
    volatile int selectedSlot = -1;

    /**
     * 校准模式（手柄长按确认键 1.2s 进入/退出）：方向键调左右眼旋转、
     * B 循环翻转、短按确认交换左右眼。进入后面板顶部出现操作横幅，
     * 全程不需要碰手机。
     */
    volatile boolean calibMode;

    /** 确认键长按检测（进/出校准模式用）。 */
    private final android.os.Handler keyHandler = new android.os.Handler(
            android.os.Looper.getMainLooper());
    private Runnable confirmLongPress;

    /** pinned 列表是否已从磁盘加载（避免每个宿主重复读 SharedPreferences）。 */
    private boolean loaded;

    /** 应用上下文（画图标等需要 Context 的静态工具用）。 */
    private Context appContext;

    /** 时钟刷新：桌面内容是静态位图，靠它每 30 秒重画一次更新时间。 */
    private final android.os.Handler clockHandler = new android.os.Handler(
            android.os.Looper.getMainLooper());
    private final Runnable clockTick = new Runnable() {
        @Override
        public void run() {
            if (appContext != null) {
                publish(appContext);
            }
            clockHandler.postDelayed(this, 30_000L);
        }
    };

    private DesktopPresenter() {
        clockHandler.postDelayed(clockTick, 30_000L);
    }

    /** 给无状态工具（HomeContent 画图标）用的应用上下文。 */
    Context appContext() {
        return appContext;
    }

    /** 首次使用时加载已钉应用并发布一帧内容。幂等。 */
    void ensureLoaded(Context context) {
        if (loaded) {
            return;
        }
        reloadPinned(context);
    }

    void reloadPinned(Context context) {
        Context app = context.getApplicationContext();
        appContext = app;
        pinnedApps.clear();
        pinnedApps.addAll(AppCatalog.pinned(app));
        if (selectedSlot >= pinnedApps.size()) {
            selectedSlot = -1;
        }
        loaded = true;
        publish(app);
    }

    /** 触控板/摇杆的归一化坐标（-1..1）驱动指针。 */
    void movePointer(Context context, float normalizedX, float normalizedY) {
        pointerX = VrUi.toPanelX(normalizedX);
        pointerY = VrUi.toPanelY(normalizedY);
        selectedSlot = VrUi.slotAt(pointerX, pointerY);
        pointerVisible = true;
        publish(context);
    }

    /** 面板像素坐标直接设指针（手柄射线与面板求交的结果）。 */
    void setPointer(Context context, float px, float py, boolean visible) {
        pointerX = px;
        pointerY = py;
        pointerVisible = visible;
        selectedSlot = visible ? VrUi.slotAt(px, py) : -1;
        publish(context);
    }

    /**
     * 方向键在格子间跳（全局接管服务与 Activity 共用这一份导航）。
     * 指针直接跳到目标格中心，复用同一套命中逻辑。
     */
    void moveSelection(Context context, int keyCode) {
        int slot = selectedSlot;
        if (slot < 0) {
            slot = 0;
        } else {
            int column = slot % VrUi.GRID_COLUMNS;
            int row = slot / VrUi.GRID_COLUMNS;
            switch (keyCode) {
                case android.view.KeyEvent.KEYCODE_DPAD_LEFT:
                    if (column > 0) {
                        slot -= 1;
                    }
                    break;
                case android.view.KeyEvent.KEYCODE_DPAD_RIGHT:
                    if (column < VrUi.GRID_COLUMNS - 1) {
                        slot += 1;
                    }
                    break;
                case android.view.KeyEvent.KEYCODE_DPAD_UP:
                    if (row > 0) {
                        slot -= VrUi.GRID_COLUMNS;
                    }
                    break;
                case android.view.KeyEvent.KEYCODE_DPAD_DOWN:
                    if (row < VrUi.GRID_ROWS - 1) {
                        slot += VrUi.GRID_COLUMNS;
                    }
                    break;
                default:
                    return;
            }
        }
        setPointer(context,
                VrUi.tileLeft(slot) + VrUi.TILE_WIDTH / 2f,
                VrUi.tileTop(slot) + VrUi.TILE_HEIGHT / 2f,
                true);
    }

    /**
     * 抬手/扳机确认：指针停在应用格上就启动它，停在「＋」上提示去手机端添加。
     *
     * @return 给手机端显示的结果描述；null = 没有命中任何格子
     */
    String confirm(Context context) {
        Context app = context.getApplicationContext();
        int slot = VrUi.slotAt(pointerX, pointerY);
        if (slot < 0) {
            return null;
        }
        String note;
        if (slot < pinnedApps.size()) {
            AppCatalog.Entry entry = pinnedApps.get(slot);
            boolean launched = AppCatalog.launch(app, entry.packageName);
            note = launched ? "已启动 " + entry.label : "启动失败：" + entry.label;
            ShellState.environmentNote = note;
        } else if (slot == pinnedApps.size()) {
            note = "「＋」格确认：请在手机上打开桌面点「添加应用」";
            ShellState.event(note);
        } else {
            note = null;
        }
        publish(app);
        return note;
    }

    void removeSelected(Context context) {
        if (selectedSlot < 0 || selectedSlot >= pinnedApps.size()) {
            ShellState.event("先选中一个应用，再点移除");
            return;
        }
        AppCatalog.removePinned(context.getApplicationContext(),
                pinnedApps.get(selectedSlot).packageName);
        reloadPinned(context);
    }

    /**
     * 统一手柄按键路由——全局接管服务与 Activity 共用，保证两路行为一致。
     *
     * <p>普通模式：方向键移动选中格、确认键启动应用、B 收起指针；
     * <b>长按确认键 1.2s 进/出校准模式</b>。校准模式：◀▶ 调左眼、▲▼ 调右眼
     * （各 ±90°）、B 循环翻转（无→垂直→水平→双翻）、短按确认交换左右眼。</p>
     *
     * @return true = 按键已消费，调用方不要再处理
     */
    boolean handleKey(final Context context, boolean down, int keyCode) {
        final Context app = context.getApplicationContext();
        switch (keyCode) {
            case android.view.KeyEvent.KEYCODE_DPAD_CENTER:
            case android.view.KeyEvent.KEYCODE_ENTER:
            case android.view.KeyEvent.KEYCODE_BUTTON_A:
                if (down) {
                    scheduleConfirmLongPress(app);
                } else {
                    cancelConfirmLongPress();
                    if (calibMode) {
                        ShellState.event("校准：" + EyeCalibration.toggleSwap(app));
                    } else {
                        String note = confirm(app);
                        if (note != null) {
                            ShellState.event(note);
                        }
                    }
                    publish(app);
                }
                return true;
            case android.view.KeyEvent.KEYCODE_BUTTON_B:
            case android.view.KeyEvent.KEYCODE_BACK:
                if (down) {
                    if (calibMode) {
                        ShellState.event("校准：" + EyeCalibration.cycleFlip(app));
                        publish(app);
                    } else {
                        setPointer(app, 0f, 0f, false);
                    }
                }
                return true;
            case android.view.KeyEvent.KEYCODE_HOME:
                // 手柄主页键：校准模式下等于保存退出，否则指针回到第一格。
                if (down) {
                    if (calibMode) {
                        calibMode = false;
                        ShellState.event("校准已保存，退出校准模式");
                    } else {
                        setPointer(app,
                                VrUi.tileLeft(0) + VrUi.TILE_WIDTH / 2f,
                                VrUi.tileTop(0) + VrUi.TILE_HEIGHT / 2f, true);
                    }
                    publish(app);
                }
                return true;
            case android.view.KeyEvent.KEYCODE_DPAD_LEFT:
            case android.view.KeyEvent.KEYCODE_DPAD_RIGHT:
            case android.view.KeyEvent.KEYCODE_DPAD_UP:
            case android.view.KeyEvent.KEYCODE_DPAD_DOWN:
                if (down) {
                    if (calibMode) {
                        // ◀▶ = 左眼 ∓90°；▲▼ = 右眼 ±90°。
                        boolean left = keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT
                                || keyCode == android.view.KeyEvent.KEYCODE_DPAD_RIGHT;
                        int delta = keyCode == android.view.KeyEvent.KEYCODE_DPAD_LEFT
                                || keyCode == android.view.KeyEvent.KEYCODE_DPAD_DOWN ? -1 : 1;
                        ShellState.event("校准：" + EyeCalibration.nudge(app, left, delta));
                    } else {
                        moveSelection(app, keyCode);
                    }
                    publish(app);
                }
                return true;
            default:
                return false;
        }
    }

    private void scheduleConfirmLongPress(final Context app) {
        cancelConfirmLongPress();
        confirmLongPress = new Runnable() {
            @Override
            public void run() {
                confirmLongPress = null;
                calibMode = !calibMode;
                ShellState.event(calibMode
                        ? "进入校准模式：◀▶左眼 ▲▼右眼 B翻转 短按确认=交换，长按确认退出"
                        : "校准已保存，退出校准模式");
                publish(app);
            }
        };
        keyHandler.postDelayed(confirmLongPress, 1200L);
    }

    private void cancelConfirmLongPress() {
        if (confirmLongPress != null) {
            keyHandler.removeCallbacks(confirmLongPress);
            confirmLongPress = null;
        }
    }

    /** 重画面板位图并交给共享的 HomeScene（眼镜与手机预览同源）。 */
    void publish(Context context) {
        Context app = context.getApplicationContext();
        Bitmap bitmap = HomeContent.render(app,
                new ArrayList<>(pinnedApps), pointerX, pointerY, pointerVisible,
                calibMode ? calibBanner(app) : null);
        PoseHub.scene().setContent(bitmap);
    }

    /** 校准模式横幅：操作说明 + 当前值，画在面板顶部。 */
    private static String calibBanner(Context app) {
        return "【校准】◀▶左眼 ▲▼右眼 · B翻转 · 短按确认=交换 · 长按确认=保存退出 ─ "
                + EyeCalibration.describe(app);
    }
}
