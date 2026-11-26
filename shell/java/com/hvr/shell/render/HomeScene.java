package com.hvr.shell.render;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.opengl.GLES20;
import android.opengl.GLUtils;
import android.opengl.Matrix;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * VR 主界面：一块贴在眼前 2 米处的面板，内容是 {@link Bitmap}（由 Canvas 画出来的
 * 文件列表与状态），双目各画一次，靠 {@link StereoRenderer} 的 IPD 偏移产生景深。
 *
 * 为什么用位图而不是 3D 文字：位图方案只需要一次 {@code Canvas.drawText}，
 * 换内容就是换一张图，不用引入字形图集、也不用为中文找字体文件。
 * 代价是文字是「印在面板上」的，不具备 3D 文字的遮挡关系——对这种平铺面板正合适。
 */
public final class HomeScene implements Renderable {

    /** 面板物理尺寸（米）。r20 拉近到 1.5 米并放大到 1.9 米宽（约 64° 视场）。 */
    private static final float PANEL_WIDTH = 1.9f;
    private static final float PANEL_HEIGHT = 1.06875f; // 保持 16:9
    private static final float PANEL_DISTANCE = 1.5f;

    /** r18：用户要求纯黑背景，星空幕布关闭。 */
    private static final boolean SHOW_BACKDROP = false;

    /** 背景幕布：远在面板身后的大 quad，铺满视场，转头时有空间纵深。 */
    private static final float BACKDROP_WIDTH = 14f;
    private static final float BACKDROP_HEIGHT = 8f;
    private static final float BACKDROP_DISTANCE = 5.5f;

    private static final String VERTEX_SHADER =
            "uniform mat4 uMvp;\n"
                    + "attribute vec4 aPosition;\n"
                    + "attribute vec2 aUv;\n"
                    + "varying vec2 vUv;\n"
                    + "void main() {\n"
                    + "    vUv = aUv;\n"
                    + "    gl_Position = uMvp * aPosition;\n"
                    + "}\n";

    private static final String FRAGMENT_SHADER =
            "precision mediump float;\n"
                    + "uniform sampler2D uTexture;\n"
                    + "varying vec2 vUv;\n"
                    + "void main() {\n"
                    + "    gl_FragColor = texture2D(uTexture, vUv);\n"
                    + "}\n";

    private final float[] model = new float[16];
    private final float[] mvp = new float[16];
    private final float[] backdropModel = new float[16];

    private int program;
    private int aPosition;
    private int aUv;
    private int uMvp;
    private int uTexture;
    private int texture;
    private int backdropTexture;
    private FloatBuffer vertexBuffer;
    private FloatBuffer uvBuffer;
    private FloatBuffer backdropVertexBuffer;
    private FloatBuffer backdropUvBuffer;

    /** 由界面线程写入，GL 线程消费。 */
    private Bitmap pending;
    private boolean uploadPending;

    public HomeScene() {
        // 面板正对 -Z，中心在眼前 PANEL_DISTANCE 处。
        Matrix.setIdentityM(model, 0);
        Matrix.translateM(model, 0, 0f, 0f, -PANEL_DISTANCE);
        // 背景幕布：更远、更大，世界锁定。
        Matrix.setIdentityM(backdropModel, 0);
        Matrix.translateM(backdropModel, 0, 0f, 0f, -BACKDROP_DISTANCE);
    }

    /** 换内容。可以在任意线程调用，真正的上传发生在下一帧。 */
    public void setContent(Bitmap bitmap) {
        synchronized (this) {
            if (pending != null) {
                // 上一张还没被 GL 线程接手就又被替换了，直接回收旧的，避免泄漏。
                pending.recycle();
            }
            pending = bitmap;
            uploadPending = bitmap != null;
        }
    }

    @Override
    public void init() {
        program = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER);
        aPosition = GLES20.glGetAttribLocation(program, "aPosition");
        aUv = GLES20.glGetAttribLocation(program, "aUv");
        uMvp = GLES20.glGetUniformLocation(program, "uMvp");
        uTexture = GLES20.glGetUniformLocation(program, "uTexture");

        float halfW = PANEL_WIDTH / 2f;
        float halfH = PANEL_HEIGHT / 2f;
        // 三角带顺序：左下、右下、左上、右上。
        vertexBuffer = floats(new float[]{
                -halfW, -halfH, 0f,
                halfW, -halfH, 0f,
                -halfW, halfH, 0f,
                halfW, halfH, 0f,
        });
        uvBuffer = floats(new float[]{
                0f, 1f,
                1f, 1f,
                0f, 0f,
                1f, 0f,
        });

        int[] handle = new int[1];
        GLES20.glGenTextures(1, handle, 0);
        texture = handle[0];
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);

        // 背景幕布的顶点与星空纹理。
        float bHalfW = BACKDROP_WIDTH / 2f;
        float bHalfH = BACKDROP_HEIGHT / 2f;
        backdropVertexBuffer = floats(new float[]{
                -bHalfW, -bHalfH, 0f,
                bHalfW, -bHalfH, 0f,
                -bHalfW, bHalfH, 0f,
                bHalfW, bHalfH, 0f,
        });
        backdropUvBuffer = floats(new float[]{
                0f, 1f,
                1f, 1f,
                0f, 0f,
                1f, 0f,
        });
        GLES20.glGenTextures(1, handle, 0);
        backdropTexture = handle[0];
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backdropTexture);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0,
                SHOW_BACKDROP ? makeStarfield() : makeBlackPixel(), 0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
    }

    /** r18：纯黑背景用的 1x1 像素（幕布关闭时替代星空图）。 */
    private static Bitmap makeBlackPixel() {
        Bitmap bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888);
        bitmap.setPixel(0, 0, android.graphics.Color.BLACK);
        return bitmap;
    }

    /** 程序生成的深空星野位图（确定性种子，只生成一次）。 */
    private static Bitmap makeStarfield() {
        int width = 2048;
        int height = 1024;
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        android.graphics.Paint gradient = new android.graphics.Paint();
        gradient.setShader(new android.graphics.LinearGradient(0, 0, 0, height,
                android.graphics.Color.rgb(0x08, 0x0D, 0x1E),
                android.graphics.Color.rgb(0x01, 0x02, 0x06),
                android.graphics.Shader.TileMode.CLAMP));
        canvas.drawPaint(gradient);
        // 地平辉光：底部一点深蓝，像有大气。
        gradient.setShader(new android.graphics.RadialGradient(
                width / 2f, height * 1.15f, height * 0.9f,
                android.graphics.Color.argb(70, 0x14, 0x2C, 0x5A),
                android.graphics.Color.TRANSPARENT,
                android.graphics.Shader.TileMode.CLAMP));
        canvas.drawPaint(gradient);

        java.util.Random random = new java.util.Random(20261101L);
        android.graphics.Paint star = new android.graphics.Paint(
                android.graphics.Paint.ANTI_ALIAS_FLAG);
        for (int i = 0; i < 420; i++) {
            float x = random.nextFloat() * width;
            float y = random.nextFloat() * height * 0.92f;
            float size = 1.2f + random.nextFloat() * 3.2f;
            int alpha = 70 + random.nextInt(160);
            star.setColor(android.graphics.Color.argb(alpha, 0xDE, 0xE8, 0xFF));
            canvas.drawCircle(x, y, size, star);
        }
        // 十几颗亮星带十字光芒。
        android.graphics.Paint ray = new android.graphics.Paint(
                android.graphics.Paint.ANTI_ALIAS_FLAG);
        ray.setStrokeWidth(2f);
        for (int i = 0; i < 14; i++) {
            float x = random.nextFloat() * width;
            float y = random.nextFloat() * height * 0.8f;
            float arm = 8f + random.nextFloat() * 14f;
            ray.setColor(android.graphics.Color.argb(120, 0xE8, 0xF2, 0xFF));
            canvas.drawLine(x - arm, y, x + arm, y, ray);
            canvas.drawLine(x, y - arm, x, y + arm, ray);
        }
        return bitmap;
    }

    @Override
    public void draw(float[] viewProjection) {
        if (program == 0) {
            return;
        }
        uploadIfNeeded();
        GLES20.glUseProgram(program);
        GLES20.glUniform1i(uTexture, 0);
        GLES20.glEnableVertexAttribArray(aPosition);
        GLES20.glEnableVertexAttribArray(aUv);

        // 先画背景幕布（更远，被深度测试自然排在面板后面）。
        Matrix.multiplyMM(mvp, 0, viewProjection, 0, backdropModel, 0);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backdropTexture);
        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0);
        GLES20.glVertexAttribPointer(aPosition, 3, GLES20.GL_FLOAT, false, 0,
                backdropVertexBuffer);
        GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 0, backdropUvBuffer);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);

        // 再画桌面面板。
        Matrix.multiplyMM(mvp, 0, viewProjection, 0, model, 0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0);
        GLES20.glVertexAttribPointer(aPosition, 3, GLES20.GL_FLOAT, false, 0, vertexBuffer);
        GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 0, uvBuffer);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);

        GLES20.glDisableVertexAttribArray(aPosition);
        GLES20.glDisableVertexAttribArray(aUv);
    }

    private void uploadIfNeeded() {
        Bitmap bitmap;
        synchronized (this) {
            if (!uploadPending) {
                return;
            }
            bitmap = pending;
            pending = null;
            uploadPending = false;
        }
        if (bitmap == null || bitmap.isRecycled()) {
            return;
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0);
        // r20：纹理是 2880x1620，屏上只占 ~1400px，必须开 mipmap 才不会糊/闪。
        GLES20.glGenerateMipmap(GLES20.GL_TEXTURE_2D);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR_MIPMAP_LINEAR);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
        bitmap.recycle();
    }

    @Override
    public void release() {
        if (texture != 0) {
            GLES20.glDeleteTextures(1, new int[]{texture}, 0);
            texture = 0;
        }
        if (backdropTexture != 0) {
            GLES20.glDeleteTextures(1, new int[]{backdropTexture}, 0);
            backdropTexture = 0;
        }
        if (program != 0) {
            GLES20.glDeleteProgram(program);
            program = 0;
        }
    }

    private static FloatBuffer floats(float[] values) {
        FloatBuffer buffer = ByteBuffer.allocateDirect(values.length * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer();
        buffer.put(values).position(0);
        return buffer;
    }

    private static int buildProgram(String vertex, String fragment) {
        int vs = compile(GLES20.GL_VERTEX_SHADER, vertex);
        int fs = compile(GLES20.GL_FRAGMENT_SHADER, fragment);
        int program = GLES20.glCreateProgram();
        GLES20.glAttachShader(program, vs);
        GLES20.glAttachShader(program, fs);
        GLES20.glLinkProgram(program);
        int[] status = new int[1];
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0);
        if (status[0] != GLES20.GL_TRUE) {
            throw new IllegalStateException("链接着色器失败: "
                    + GLES20.glGetProgramInfoLog(program));
        }
        GLES20.glDeleteShader(vs);
        GLES20.glDeleteShader(fs);
        return program;
    }

    private static int compile(int type, String source) {
        int shader = GLES20.glCreateShader(type);
        GLES20.glShaderSource(shader, source);
        GLES20.glCompileShader(shader);
        int[] status = new int[1];
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0);
        if (status[0] != GLES20.GL_TRUE) {
            throw new IllegalStateException("编译着色器失败: "
                    + GLES20.glGetShaderInfoLog(shader));
        }
        return shader;
    }
}
