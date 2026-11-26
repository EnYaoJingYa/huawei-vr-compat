package com.hvr.shell;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Random;

/**
 * VR 桌面的内容：深空背景 + 大时钟 + 应用图标卡片 + 指针。
 *
 * 观感对齐华为 VR 桌面：深邃太空底、悬浮的半透明应用卡（真实图标 + 名称）、
 * 选中时描边发光。整张内容还是一张位图（{@link VrUi#PANEL_WIDTH}x
 * {@link VrUi#PANEL_HEIGHT}），交给 {@link com.hvr.shell.render.HomeScene} 上传纹理。
 *
 * 尺寸与坐标全部取自 {@link VrUi}——画的人和判命中的人共用同一套坐标。
 */
final class HomeContent {

    private HomeContent() {
    }

    static Bitmap render(Context context, List<AppCatalog.Entry> apps,
                         float pointerX, float pointerY, boolean pointerVisible,
                         String calibBanner) {
        // r20：2 倍超采样。布局坐标仍按 1440x810 写（VrUi.PANEL_*），
        // 纹理按 2880x1620 出图，GPU 再缩到眼镜屏实际像素 —— 文字边缘明显更锐。
        Bitmap bitmap = Bitmap.createBitmap(
                Math.round(VrUi.PANEL_WIDTH * SS), Math.round(VrUi.PANEL_HEIGHT * SS),
                Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.scale(SS, SS);
        drawSpace(canvas);
        drawHeader(canvas);
        drawGrid(canvas, apps);
        drawFooter(canvas, apps);
        if (calibBanner != null) {
            drawBanner(canvas, calibBanner);
        }
        drawPointer(canvas, pointerX, pointerY, pointerVisible);
        return bitmap;
    }

    /** 面板超采样倍率。 */
    private static final float SS = 2f;

    /** 校准模式横幅：面板顶部通栏，蓝底白字，一眼看清操作方式。 */
    private static void drawBanner(Canvas canvas, String text) {
        Paint back = new Paint(Paint.ANTI_ALIAS_FLAG);
        back.setColor(Color.argb(0xD0, 0x10, 0x3A, 0x6E));
        canvas.drawRect(0, 0, VrUi.PANEL_WIDTH, 176, back);

        Paint bar = new Paint();
        bar.setColor(Color.rgb(0x5A, 0xC8, 0xFA));
        canvas.drawRect(0, 0, VrUi.PANEL_WIDTH, 8, bar);

        Paint line = text(38, Color.rgb(0xEA, 0xF4, 0xFF), true);
        float maxWidth = VrUi.PANEL_WIDTH - 128;
        while (line.measureText(text) > maxWidth && line.getTextSize() > 24f) {
            line.setTextSize(line.getTextSize() - 2f);
        }
        canvas.drawText(text, 64, 74, line);

        Paint tip = text(26, Color.argb(0xC8, 0x9E, 0xC4, 0xE0), false);
        canvas.drawText("调两眼都正后画面会自动融合；觉得值对了就长按确认保存", 64, 128, tip);
    }

    // ---------------------------------------------------------------- 背景

    /** 深空：纵向渐变 + 确定性星点 + 一团淡淡的星云光晕。 */
    private static void drawSpace(Canvas canvas) {
        Paint gradient = new Paint();
        gradient.setShader(new LinearGradient(0, 0, 0, VrUi.PANEL_HEIGHT,
                Color.rgb(0x0A, 0x10, 0x24), Color.rgb(0x02, 0x04, 0x0A),
                Shader.TileMode.CLAMP));
        canvas.drawPaint(gradient);

        // 星云：右上与左下各一团，非常淡。
        Paint nebula = new Paint(Paint.ANTI_ALIAS_FLAG);
        nebula.setShader(new RadialGradient(
                VrUi.PANEL_WIDTH * 0.82f, VrUi.PANEL_HEIGHT * 0.18f, 340f,
                Color.argb(46, 0x35, 0x6B, 0xC9), Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        canvas.drawPaint(nebula);
        nebula.setShader(new RadialGradient(
                VrUi.PANEL_WIDTH * 0.12f, VrUi.PANEL_HEIGHT * 0.85f, 300f,
                Color.argb(34, 0x6B, 0x3A, 0xC9), Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        canvas.drawPaint(nebula);

        // 星点：固定种子，每帧一样的星空（内容是静态位图，其实只画一次，
        // 但确定性让预览和眼镜严格一致）。
        Random random = new Random(20261101L);
        Paint star = new Paint(Paint.ANTI_ALIAS_FLAG);
        for (int i = 0; i < 140; i++) {
            float x = random.nextFloat() * VrUi.PANEL_WIDTH;
            float y = random.nextFloat() * VrUi.PANEL_HEIGHT;
            float size = 1f + random.nextFloat() * 2.4f;
            int alpha = 60 + random.nextInt(150);
            star.setColor(Color.argb(alpha, 0xD8, 0xE6, 0xFF));
            canvas.drawCircle(x, y, size, star);
        }
    }

    // ---------------------------------------------------------------- 头部

    private static void drawHeader(Canvas canvas) {
        // 大时钟（华为 VR 桌面的标志性元素）。
        String time = new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date());
        Paint clock = text(72, Color.rgb(0xF2, 0xF6, 0xFF), true);
        canvas.drawText(time, 64, 108, clock);

        String date = new SimpleDateFormat("M月d日 EEEE", Locale.getDefault())
                .format(new Date());
        Paint sub = text(26, Color.rgb(0x8E, 0x9C, 0xBC), false);
        canvas.drawText(date, 68, 146, sub);

        // 右上状态：眼镜/手柄。
        Paint status = text(22, ShellState.glassPresent
                        ? Color.rgb(0x69, 0xE0, 0x9C) : Color.rgb(0xB9, 0x8E, 0x50),
                false);
        String right = ShellState.glassPresent
                ? "● 眼镜已连接" : "○ 等待眼镜";
        float rightWidth = status.measureText(right);
        canvas.drawText(right, VrUi.PANEL_WIDTH - 64 - rightWidth, 92, status);

        Paint controller = text(20, Color.rgb(0x8E, 0x9C, 0xBC), false);
        String second = "手柄：" + ShellState.controllerNote;
        float secondWidth = controller.measureText(second);
        canvas.drawText(second, VrUi.PANEL_WIDTH - 64 - secondWidth, 124, controller);
    }

    // ---------------------------------------------------------------- 网格

    private static void drawGrid(Canvas canvas, List<AppCatalog.Entry> apps) {
        int selected = DesktopPresenter.get().selectedSlot;
        for (int slot = 0; slot < VrUi.SLOTS; slot++) {
            boolean filled = slot < apps.size();
            boolean plus = slot == apps.size();
            if (!filled && !plus) {
                continue;
            }
            boolean hovered = slot == selected;
            AppCatalog.Entry entry = filled ? apps.get(slot) : null;
            drawCard(canvas, slot, entry, plus, hovered);
        }
    }

    private static void drawCard(Canvas canvas, int slot, AppCatalog.Entry entry,
                                 boolean plus, boolean hovered) {
        float left = VrUi.tileLeft(slot);
        float top = VrUi.tileTop(slot);
        RectF rect = new RectF(left, top, left + VrUi.TILE_WIDTH, top + VrUi.TILE_HEIGHT);

        // 卡片底：半透明玻璃感；悬停时提亮。
        Paint card = new Paint(Paint.ANTI_ALIAS_FLAG);
        card.setColor(Color.argb(hovered ? 0x66 : 0x40, 0x1C, 0x26, 0x3E));
        canvas.drawRoundRect(rect, 28, 28, card);

        Paint border = new Paint(Paint.ANTI_ALIAS_FLAG);
        border.setStyle(Paint.Style.STROKE);
        border.setStrokeWidth(hovered ? 5f : 2f);
        border.setColor(hovered
                ? Color.rgb(0x6E, 0xD2, 0xFF) : Color.argb(0x50, 0x4A, 0x5E, 0x82));
        canvas.drawRoundRect(rect, 28, 28, border);

        if (hovered) {
            // 外圈光晕。
            Paint glow = new Paint(Paint.ANTI_ALIAS_FLAG);
            glow.setStyle(Paint.Style.STROKE);
            glow.setStrokeWidth(14f);
            glow.setColor(Color.argb(50, 0x5A, 0xC8, 0xFA));
            RectF glowRect = new RectF(rect);
            glowRect.inset(-9, -9);
            canvas.drawRoundRect(glowRect, 34, 34, glow);
        }

        float cx = rect.centerX();
        if (entry != null) {
            int iconSize = 148;
            Bitmap icon = AppCatalog.icon(canvas2Context(), entry.packageName, iconSize);
            float iconTop = top + 42;
            if (icon != null) {
                canvas.drawBitmap(icon, cx - iconSize / 2f, iconTop, null);
            } else {
                // 占位：圆底 + 首字母。
                Paint disc = new Paint(Paint.ANTI_ALIAS_FLAG);
                disc.setColor(Color.argb(0x88, 0x2E, 0x3A, 0x58));
                canvas.drawCircle(cx, iconTop + iconSize / 2f, iconSize / 2f, disc);
                Paint letter = text(56, Color.rgb(0xC8, 0xD8, 0xF2), true);
                String initial = entry.label.isEmpty() ? "?" : entry.label.substring(0, 1);
                canvas.drawText(initial, cx - letter.measureText(initial) / 2f,
                        iconTop + iconSize / 2f + 20, letter);
            }
            Paint label = text(30, Color.rgb(0xEC, 0xF1, 0xFA), false);
            drawCentered(canvas, entry.label, label, rect, iconTop + iconSize + 44);
        } else {
            // 「＋」添加格。
            Paint plusPaint = text(96, Color.rgb(0x5A, 0xC8, 0xFA), false);
            canvas.drawText("＋", cx - plusPaint.measureText("＋") / 2f,
                    rect.centerY() + 34, plusPaint);
            Paint hint = text(26, Color.rgb(0x7A, 0x8A, 0xAA), false);
            String text = "添加应用";
            canvas.drawText(text, cx - hint.measureText(text) / 2f,
                    rect.centerY() + 96, hint);
        }
    }

    /** HomeContent 没有成员上下文；画图标时用 presenter 缓存的应用上下文。 */
    private static Context canvas2Context() {
        return DesktopPresenter.get().appContext();
    }

    /** 名称居中（指定 y 基线），放不下就截断加省略号。 */
    private static void drawCentered(Canvas canvas, String text, Paint paint,
                                     RectF rect, float baseline) {
        String value = text == null ? "" : text;
        float maxWidth = rect.width() - 32;
        if (paint.measureText(value) > maxWidth) {
            while (paint.measureText(value + "…") > maxWidth && value.length() > 1) {
                value = value.substring(0, value.length() - 1);
            }
            value = value + "…";
        }
        canvas.drawText(value, rect.centerX() - paint.measureText(value) / 2f, baseline, paint);
    }

    // ---------------------------------------------------------------- 页脚

    private static void drawFooter(Canvas canvas, List<AppCatalog.Entry> apps) {
        Paint hint = text(24, Color.argb(0x88, 0x8E, 0x9C, 0xBC), false);
        String text = apps.isEmpty()
                ? "从「＋」添加应用 · 方向键选 · 确认键启动 · 长按确认键=校准画面"
                : "方向键选应用 · 确认键启动 · B收起指针 · 长按确认键=校准画面";
        canvas.drawText(text, 64, VrUi.PANEL_HEIGHT - 28, hint);
    }

    // ---------------------------------------------------------------- 指针

    private static void drawPointer(Canvas canvas, float x, float y, boolean visible) {
        if (!visible) {
            return;
        }
        Paint glow = new Paint(Paint.ANTI_ALIAS_FLAG);
        glow.setColor(Color.argb(80, 0x5A, 0xC8, 0xFA));
        canvas.drawCircle(x, y, 30, glow);

        Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        dot.setColor(Color.rgb(0xF2, 0xFA, 0xFF));
        canvas.drawCircle(x, y, 10, dot);

        Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
        ring.setStyle(Paint.Style.STROKE);
        ring.setStrokeWidth(4f);
        ring.setColor(Color.rgb(0x5A, 0xC8, 0xFA));
        canvas.drawCircle(x, y, 19, ring);
    }

    private static Paint text(float size, int color, boolean bold) {
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        paint.setTextSize(size);
        paint.setColor(color);
        paint.setTypeface(bold ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
        return paint;
    }
}
