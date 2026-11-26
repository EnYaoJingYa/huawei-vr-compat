package com.hvr.shell.render;

import android.opengl.GLES20;
import android.opengl.Matrix;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * 演示场景：一块网格地面 + 8 根柱体 + 正前方一块青色标记。
 *
 * <p>目的不是好看，而是让「转头」和「前后位移」在画面里立刻可见：
 * 正前方标记在 -Z，柱体均匀分布在周围，地平线在 y=-1.6（眼高 1.6m）。</p>
 */
public final class Scene implements Renderable {

    private static final String VERTEX_LIT =
            "uniform mat4 uMvp;\n"
                    + "uniform mat4 uModel;\n"
                    + "attribute vec3 aPosition;\n"
                    + "attribute vec3 aNormal;\n"
                    + "varying vec3 vNormal;\n"
                    + "void main() {\n"
                    + "    vNormal = (uModel * vec4(aNormal, 0.0)).xyz;\n"
                    + "    gl_Position = uMvp * vec4(aPosition, 1.0);\n"
                    + "}\n";

    private static final String FRAGMENT_LIT =
            "precision mediump float;\n"
                    + "uniform vec3 uColor;\n"
                    + "varying vec3 vNormal;\n"
                    + "void main() {\n"
                    + "    vec3 n = normalize(vNormal);\n"
                    + "    vec3 light = normalize(vec3(0.35, 0.9, 0.25));\n"
                    + "    float diffuse = max(dot(n, light), 0.0);\n"
                    + "    gl_FragColor = vec4(uColor * (0.30 + 0.70 * diffuse), 1.0);\n"
                    + "}\n";

    private static final String VERTEX_COLOR =
            "uniform mat4 uMvp;\n"
                    + "attribute vec3 aPosition;\n"
                    + "void main() {\n"
                    + "    gl_Position = uMvp * vec4(aPosition, 1.0);\n"
                    + "}\n";

    private static final String FRAGMENT_COLOR =
            "precision mediump float;\n"
                    + "uniform vec3 uColor;\n"
                    + "void main() {\n"
                    + "    gl_FragColor = vec4(uColor, 1.0);\n"
                    + "}\n";

    /** 眼高 1.6m；地面放在 y=-1.6，相机在原点。 */
    private static final float FLOOR_HEIGHT = -1.6f;
    private static final int OBJECT_COUNT = 9;

    private final float[][] models = new float[OBJECT_COUNT][16];
    private final float[][] colors = new float[OBJECT_COUNT][3];
    private final float[] mvp = new float[16];

    private int litProgram;
    private int litPosition;
    private int litNormal;
    private int litMvp;
    private int litModel;
    private int litColor;

    private int colorProgram;
    private int colorPosition;
    private int colorMvp;
    private int colorColor;

    private int cubeBuffer;
    private int cubeVertexCount;
    private int gridBuffer;
    private int gridVertexCount;

    private boolean ready;

    public void init() {
        litProgram = GlUtil.linkProgram(VERTEX_LIT, FRAGMENT_LIT);
        litPosition = GLES20.glGetAttribLocation(litProgram, "aPosition");
        litNormal = GLES20.glGetAttribLocation(litProgram, "aNormal");
        litMvp = GLES20.glGetUniformLocation(litProgram, "uMvp");
        litModel = GLES20.glGetUniformLocation(litProgram, "uModel");
        litColor = GLES20.glGetUniformLocation(litProgram, "uColor");

        colorProgram = GlUtil.linkProgram(VERTEX_COLOR, FRAGMENT_COLOR);
        colorPosition = GLES20.glGetAttribLocation(colorProgram, "aPosition");
        colorMvp = GLES20.glGetUniformLocation(colorProgram, "uMvp");
        colorColor = GLES20.glGetUniformLocation(colorProgram, "uColor");

        buildCube();
        buildGrid();
        buildObjects();
        ready = true;
    }

    public void draw(float[] viewProjection) {
        if (!ready) {
            return;
        }

        GLES20.glUseProgram(colorProgram);
        GLES20.glUniformMatrix4fv(colorMvp, 1, false, viewProjection, 0);
        GLES20.glUniform3f(colorColor, 0.16f, 0.24f, 0.20f);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, gridBuffer);
        GLES20.glEnableVertexAttribArray(colorPosition);
        GLES20.glVertexAttribPointer(colorPosition, 3, GLES20.GL_FLOAT, false, 12, 0);
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, gridVertexCount);
        GLES20.glDisableVertexAttribArray(colorPosition);

        GLES20.glUseProgram(litProgram);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, cubeBuffer);
        GLES20.glEnableVertexAttribArray(litPosition);
        GLES20.glEnableVertexAttribArray(litNormal);
        GLES20.glVertexAttribPointer(litPosition, 3, GLES20.GL_FLOAT, false, 24, 0);
        GLES20.glVertexAttribPointer(litNormal, 3, GLES20.GL_FLOAT, false, 24, 12);

        for (int i = 0; i < OBJECT_COUNT; i++) {
            Matrix.multiplyMM(mvp, 0, viewProjection, 0, models[i], 0);
            GLES20.glUniformMatrix4fv(litMvp, 1, false, mvp, 0);
            GLES20.glUniformMatrix4fv(litModel, 1, false, models[i], 0);
            GLES20.glUniform3fv(litColor, 1, colors[i], 0);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, cubeVertexCount);
        }

        GLES20.glDisableVertexAttribArray(litPosition);
        GLES20.glDisableVertexAttribArray(litNormal);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);
    }

    public void release() {
        if (litProgram != 0) {
            GLES20.glDeleteProgram(litProgram);
            litProgram = 0;
        }
        if (colorProgram != 0) {
            GLES20.glDeleteProgram(colorProgram);
            colorProgram = 0;
        }
        int[] buffers = new int[]{cubeBuffer, gridBuffer};
        GLES20.glDeleteBuffers(2, buffers, 0);
        cubeBuffer = 0;
        gridBuffer = 0;
        ready = false;
    }

    private void buildCube() {
        float h = 0.5f;
        float[][] normals = {
                {1f, 0f, 0f}, {-1f, 0f, 0f},
                {0f, 1f, 0f}, {0f, -1f, 0f},
                {0f, 0f, 1f}, {0f, 0f, -1f}
        };
        float[][][] corners = {
                {{h, -h, -h}, {h, -h, h}, {h, h, h}, {h, h, -h}},
                {{-h, -h, h}, {-h, -h, -h}, {-h, h, -h}, {-h, h, h}},
                {{-h, h, -h}, {h, h, -h}, {h, h, h}, {-h, h, h}},
                {{-h, -h, h}, {h, -h, h}, {h, -h, -h}, {-h, -h, -h}},
                {{-h, -h, h}, {h, -h, h}, {h, h, h}, {-h, h, h}},
                {{h, -h, -h}, {-h, -h, -h}, {-h, h, -h}, {h, h, -h}}
        };
        int[][] triangles = {{0, 1, 2}, {0, 2, 3}};

        float[] data = new float[6 * 6 * 6];
        int cursor = 0;
        for (int face = 0; face < 6; face++) {
            for (int[] triangle : triangles) {
                for (int index : triangle) {
                    data[cursor++] = corners[face][index][0];
                    data[cursor++] = corners[face][index][1];
                    data[cursor++] = corners[face][index][2];
                    data[cursor++] = normals[face][0];
                    data[cursor++] = normals[face][1];
                    data[cursor++] = normals[face][2];
                }
            }
        }
        cubeVertexCount = 36;
        cubeBuffer = upload(data);
    }

    private void buildGrid() {
        int half = 10;
        float[] data = new float[(half * 2 + 1) * 4 * 3];
        int cursor = 0;
        for (int i = -half; i <= half; i++) {
            data[cursor++] = i;
            data[cursor++] = FLOOR_HEIGHT;
            data[cursor++] = -half;
            data[cursor++] = i;
            data[cursor++] = FLOOR_HEIGHT;
            data[cursor++] = half;

            data[cursor++] = -half;
            data[cursor++] = FLOOR_HEIGHT;
            data[cursor++] = i;
            data[cursor++] = half;
            data[cursor++] = FLOOR_HEIGHT;
            data[cursor++] = i;
        }
        gridVertexCount = data.length / 3;
        gridBuffer = upload(data);
    }

    private void buildObjects() {
        for (int i = 0; i < 8; i++) {
            double angle = i * Math.PI / 4.0;
            float x = (float) (Math.cos(angle) * 3.6);
            float z = (float) (Math.sin(angle) * 3.6);
            Matrix.setIdentityM(models[i], 0);
            Matrix.translateM(models[i], 0, x, -1.0f, z);
            Matrix.scaleM(models[i], 0, 1.2f, 1.2f, 1.2f);

            float t = i / 8f;
            colors[i][0] = 0.30f + 0.55f * t;
            colors[i][1] = 0.55f - 0.30f * t;
            colors[i][2] = 0.35f + 0.45f * (1f - t);
        }

        // 正前方标记：位于 -Z，用来确认 yaw 的零点和正负方向。
        Matrix.setIdentityM(models[8], 0);
        Matrix.translateM(models[8], 0, 0f, -0.4f, -5.5f);
        Matrix.scaleM(models[8], 0, 2.4f, 2.4f, 0.35f);
        colors[8][0] = 0.20f;
        colors[8][1] = 0.90f;
        colors[8][2] = 1.00f;
    }

    private static int upload(float[] data) {
        FloatBuffer buffer = ByteBuffer.allocateDirect(data.length * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer();
        buffer.put(data).position(0);

        int[] ids = new int[1];
        GLES20.glGenBuffers(1, ids, 0);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, ids[0]);
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, data.length * 4, buffer,
                GLES20.GL_STATIC_DRAW);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);
        return ids[0];
    }
}
