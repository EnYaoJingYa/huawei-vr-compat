package com.hvr.shell;

/**
 * VR 面板的布局与命中判定：面板尺寸、应用格子位置、指针落在哪一格。
 *
 * 单独一个类的理由：**画的人**（{@link HomeContent}）和**判命中的人**
 * （{@link ShellActivity} 的触控板）必须用同一套坐标，否则会出现
 * 「看到的格子」和「点到的格子」差半格。这里做唯一来源。
 *
 * 坐标系是面板像素：(0,0) 左上，右下 (PANEL_WIDTH, PANEL_HEIGHT)。
 */
final class VrUi {

    static final int PANEL_WIDTH = 1440;
    static final int PANEL_HEIGHT = 810;

    static final int GRID_COLUMNS = 4;
    static final int GRID_ROWS = 2;
    static final int TILE_WIDTH = 300;
    static final int TILE_HEIGHT = 300;
    static final int TILE_GAP = 20;
    static final int GRID_LEFT = 90;
    static final int GRID_TOP = 160;

    /** 8 个格子；已钉的应用按顺序填，剩下的第一格画成「＋」。 */
    static final int SLOTS = GRID_COLUMNS * GRID_ROWS;

    private VrUi() {
    }

    static float tileLeft(int slot) {
        int column = slot % GRID_COLUMNS;
        return GRID_LEFT + column * (TILE_WIDTH + TILE_GAP);
    }

    static float tileTop(int slot) {
        int row = slot / GRID_COLUMNS;
        return GRID_TOP + row * (TILE_HEIGHT + TILE_GAP);
    }

    /**
     * 指针落在第几格。
     *
     * @param px 面板像素坐标
     * @return 0..7 命中格子；-1 没命中
     */
    static int slotAt(float px, float py) {
        for (int slot = 0; slot < SLOTS; slot++) {
            float left = tileLeft(slot);
            float top = tileTop(slot);
            if (px >= left && px <= left + TILE_WIDTH
                    && py >= top && py <= top + TILE_HEIGHT) {
                return slot;
            }
        }
        return -1;
    }

    /**
     * 触控板的归一化坐标（-1..1，左/上为负）转成面板像素。
     *
     * 触控板只映射到面板中央 80% 的区域：手指推到边缘时指针刚好到边界，
     * 不会因为手指比屏幕小而永远够不到角落。
     */
    static float toPanelX(float normalized) {
        float clamped = Math.max(-1f, Math.min(1f, normalized));
        return PANEL_WIDTH / 2f * (1f + clamped * 0.92f);
    }

    static float toPanelY(float normalized) {
        float clamped = Math.max(-1f, Math.min(1f, normalized));
        return PANEL_HEIGHT / 2f * (1f + clamped * 0.92f);
    }
}
