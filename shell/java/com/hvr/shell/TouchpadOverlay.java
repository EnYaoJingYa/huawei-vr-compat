package com.hvr.shell;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 手机屏上的悬浮触控板（r21）。
 *
 * <p>为什么不复用 {@link ShellActivity} 的触控板：门禁会把 Activity 拦掉（vr_system
 * 未注册），眼镜一连上就拉不起界面，触控板跟着一起没了。这里直接走
 * {@code WindowManager} + {@code TYPE_APPLICATION_OVERLAY}，不需要 Activity，
 * 眼镜在位时由 {@link ShellService} 挂上去 —— 于是「手机触屏」和「手柄」可以同时在线。</p>
 *
 * <p>操作：单指滑动 = 移动指针（绝对值，指哪打哪）；轻点 = 确认；长按 = 进出校准模式。
 * 底部一排按钮在没有手柄时也能完成整套校准。</p>
 */
final class TouchpadOverlay {

    private final Context context;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private WindowManager wm;
    private LinearLayout root;
    private TouchpadView pad;
    private boolean showing;
    /**
     * r23：{@link ShellActivity} 在前台时让位。Activity 自己带触控板和校准按钮，
     * 悬浮层压在上面会把整块 UI 的点击全吃掉 —— 表现就是「点了手机按钮没反应」。
     */
    private static boolean suppressed;

    TouchpadOverlay(Context context) {
        this.context = context;
    }

    boolean isShowing() {
        return showing;
    }

    void show() {
        if (showing || suppressed) {
            return;
        }
        try {
            wm = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
            if (wm == null) {
                return;
            }
            root = build();
            WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    dpToPx(268),
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    // r24：KEEP_SCREEN_ON —— 插上眼镜后系统会按 VR 使用场景自动熄屏，
                    // 手机一黑，触控板跟着失效，用户以为「没有触控模式」。挂着的触控板
                    // 必须让屏幕保持点亮，触手可及。
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                            | WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                    PixelFormat.TRANSLUCENT);
            params.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
            params.x = 0;
            params.y = dpToPx(8);
            wm.addView(root, params);
            showing = true;
            ShellState.event("手机触控板已就位（滑动=移指针，轻点=确认，长按=校准）");
        } catch (Throwable error) {
            showing = false;
            ShellState.event("触控板挂载失败（检查悬浮窗权限）", error);
        }
    }

    void hide() {
        if (!showing || root == null) {
            return;
        }
        try {
            wm.removeView(root);
        } catch (Throwable ignored) {
            // 静默
        }
        root = null;
        pad = null;
        showing = false;
    }

    /** Activity 在前台时收掉悬浮层（避免挡住界面点击），退到后台再挂回来。 */
    void setSuppressed(boolean value) {
        suppressed = value;
        if (value) {
            hide();
        } else {
            show();
        }
    }

    // ------------------------------------------------------------------ UI

    private LinearLayout build() {
        LinearLayout column = new LinearLayout(context);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(dpToPx(10), dpToPx(8), dpToPx(10), dpToPx(10));

        GradientDrawable back = new GradientDrawable();
        back.setColor(Color.argb(0xE6, 0x0B, 0x10, 0x1C));
        back.setCornerRadius(dpToPx(18));
        back.setStroke(dpToPx(1), Color.argb(0x80, 0x4A, 0x6E, 0xA8));
        column.setBackground(back);

        TextView title = new TextView(context);
        title.setText("触控板 · 滑动移指针 / 轻点确认 / 长按校准");
        title.setTextColor(Color.rgb(0x9E, 0xC4, 0xE0));
        title.setTextSize(12f);
        title.setPadding(dpToPx(6), 0, 0, dpToPx(4));
        column.addView(title);

        pad = new TouchpadView();
        LinearLayout.LayoutParams padParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        column.addView(pad, padParams);

        LinearLayout buttons = new LinearLayout(context);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setPadding(0, dpToPx(6), 0, 0);
        column.addView(buttons, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));

        addButton(buttons, "左◀", new Runnable() {
            @Override
            public void run() {
                apply("校准：" + EyeCalibration.nudge(app(), true, -1));
            }
        });
        addButton(buttons, "左▶", new Runnable() {
            @Override
            public void run() {
                apply("校准：" + EyeCalibration.nudge(app(), true, 1));
            }
        });
        addButton(buttons, "右◀", new Runnable() {
            @Override
            public void run() {
                apply("校准：" + EyeCalibration.nudge(app(), false, -1));
            }
        });
        addButton(buttons, "右▶", new Runnable() {
            @Override
            public void run() {
                apply("校准：" + EyeCalibration.nudge(app(), false, 1));
            }
        });
        addButton(buttons, "翻转", new Runnable() {
            @Override
            public void run() {
                apply("校准：" + EyeCalibration.cycleFlip(app()));
            }
        });
        addButton(buttons, "隐藏", new Runnable() {
            @Override
            public void run() {
                hide();
                ShellState.event("触控板已收起");
            }
        });

        return column;
    }

    private Context app() {
        return context.getApplicationContext();
    }

    private void apply(String note) {
        ShellState.event(note);
        DesktopPresenter.get().publish(app());
    }

    private void addButton(LinearLayout parent, String label, final Runnable action) {
        TextView button = new TextView(context);
        button.setText(label);
        button.setTextColor(Color.rgb(0xDC, 0xE9, 0xFF));
        button.setTextSize(13f);
        button.setGravity(Gravity.CENTER);
        button.setPadding(0, dpToPx(9), 0, dpToPx(9));

        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.argb(0x33, 0x5A, 0xC8, 0xFA));
        bg.setCornerRadius(dpToPx(10));
        bg.setStroke(dpToPx(1), Color.argb(0x66, 0x5A, 0xC8, 0xFA));
        button.setBackground(bg);

        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        params.setMargins(dpToPx(3), 0, dpToPx(3), 0);
        parent.addView(button, params);
        button.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                action.run();
            }
        });
    }

    /** 触控面板：面板坐标映射 + 轻点确认 + 长按切校准。 */
    private final class TouchpadView extends View {

        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint edge = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint hint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();

        private float downX;
        private float downY;
        private boolean longPressFired;
        private final Runnable longPress = new Runnable() {
            @Override
            public void run() {
                longPressFired = true;
                DesktopPresenter presenter = DesktopPresenter.get();
                presenter.calibMode = !presenter.calibMode;
                ShellState.event(presenter.calibMode
                        ? "进入校准模式（手机触控板）" : "校准已保存，退出校准模式");
                presenter.publish(app());
            }
        };

        TouchpadView() {
            super(TouchpadOverlay.this.context);
            fill.setColor(Color.argb(0x26, 0xFF, 0xFF, 0xFF));
            edge.setColor(Color.argb(0x55, 0x5A, 0xC8, 0xFA));
            edge.setStyle(Paint.Style.STROKE);
            hint.setColor(Color.argb(0x8C, 0xC7, 0xDA, 0xF5));
            hint.setTextSize(dpToPx(12));
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            float r = dpToPx(14);
            rect.set(1, 1, w - 1, h - 1);
            canvas.drawRoundRect(rect, r, r, fill);
            canvas.drawRoundRect(rect, r, r, edge);
            canvas.drawText("滑动选择 · 轻点确认 · 长按校准", dpToPx(12),
                    h - dpToPx(10), hint);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = event.getX();
                    downY = event.getY();
                    longPressFired = false;
                    handler.postDelayed(longPress, 1200L);
                    movePointer(event.getX(), event.getY());
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (Math.abs(event.getX() - downX) > dpToPx(10)
                            || Math.abs(event.getY() - downY) > dpToPx(10)) {
                        handler.removeCallbacks(longPress);
                    }
                    movePointer(event.getX(), event.getY());
                    return true;
                case MotionEvent.ACTION_UP:
                    handler.removeCallbacks(longPress);
                    movePointer(event.getX(), event.getY());
                    if (!longPressFired
                            && Math.abs(event.getX() - downX) < dpToPx(14)
                            && Math.abs(event.getY() - downY) < dpToPx(14)) {
                        DesktopPresenter presenter = DesktopPresenter.get();
                        if (presenter.calibMode) {
                            ShellState.event("校准：" + EyeCalibration.toggleSwap(app()));
                            presenter.publish(app());
                        } else {
                            String note = presenter.confirm(app());
                            if (note != null) {
                                ShellState.event(note);
                            }
                        }
                    }
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    handler.removeCallbacks(longPress);
                    DesktopPresenter.get().setPointer(app(), 0f, 0f, false);
                    return true;
                default:
                    return super.onTouchEvent(event);
            }
        }

        private void movePointer(float x, float y) {
            float nx = getWidth() == 0 ? 0f : (x / getWidth()) * 2f - 1f;
            float ny = getHeight() == 0 ? 0f : (y / getHeight()) * 2f - 1f;
            DesktopPresenter.get().movePointer(app(), nx, ny);
        }
    }

    private int dpToPx(float dp) {
        return Math.round(dp * context.getResources().getDisplayMetrics().density);
    }
}
