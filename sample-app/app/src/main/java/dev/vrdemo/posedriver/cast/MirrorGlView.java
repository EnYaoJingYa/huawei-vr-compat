package dev.vrdemo.posedriver.cast;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

import dev.vrdemo.posedriver.render.GlUtil;

/**
 * 把一路 MediaProjection 画面同时铺到左右眼。
 *
 * <p>为什么不是两个 {@code SurfaceView}：从 Android 13 起，同一个
 * {@code MediaProjection} 创建多个 {@code VirtualDisplay} 时只有最后一个能出图，
 * Android 14 更是直接限制复用 token。所以正确做法是
 * <b>只建一个 VirtualDisplay → 一个 SurfaceTexture → GL 里画两次</b>。</p>
 *
 * <p>管线：</p>
 * <pre>
 *   MediaProjection.createVirtualDisplay(AUTO_MIRROR, Surface)
 *     → SurfaceTexture(GL_TEXTURE_EXTERNAL_OES)
 *     → 左右两个 viewport 各画一次全屏 quad
 * </pre>
 *
 * <p>画面宽高比在 {@link #mirror(int, int, InputSurfaceListener)} 里确定，
 * 每只眼按比例居中，多余区域留黑。这里不做桶形畸变：平面镜像本来就只是
 * 「把手机画面搬到眼镜上」，畸变参数见 {@code LensProfile}，需要时可以在
 * fragment shader 里复用同一套公式。</p>
 */
public final class MirrorGlView extends GLSurfaceView implements SurfaceTexture.OnFrameAvailableListener {

    private static final String TAG = "MirrorGlView";

    public interface InputSurfaceListener {
        /**
         * GL 上下文就绪，可以把 Surface 交给 {@code createVirtualDisplay}。
         * 会在主线程回调；上下文重建时会再次回调。
         */
        void onInputSurface(Surface surface, int width, int height);
    }

    private static final String VERTEX_QUAD =
            "attribute vec2 aPosition;\n"
                    + "attribute vec2 aUv;\n"
                    + "uniform vec2 uScale;\n"
                    + "varying vec2 vUv;\n"
                    + "void main() {\n"
                    + "    vUv = aUv;\n"
                    + "    gl_Position = vec4(aPosition * uScale, 0.0, 1.0);\n"
                    + "}\n";

    private static final String FRAGMENT_OES =
            "#extension GL_OES_EGL_image_external : require\n"
                    + "precision mediump float;\n"
                    + "uniform samplerExternalOES uTexture;\n"
                    + "uniform mat4 uTexMatrix;\n"
                    + "varying vec2 vUv;\n"
                    + "void main() {\n"
                    + "    vec2 uv = (uTexMatrix * vec4(vUv, 0.0, 1.0)).xy;\n"
                    + "    gl_FragColor = texture2D(uTexture, uv);\n"
                    + "}\n";

    private final Renderer renderer = new Renderer();

    /** 由主线程写、GL 线程读，必须 volatile。 */
    private volatile int contentWidth = 1;
    private volatile int contentHeight = 1;
    private volatile InputSurfaceListener listener;

    private int viewWidth = 1;
    private int viewHeight = 1;

    public MirrorGlView(Context context) {
        super(context);
        setEGLContextClientVersion(2);
        setPreserveEGLContextOnPause(true);
        setRenderer(renderer);
        setRenderMode(RENDERMODE_WHEN_DIRTY);
    }

    /**
     * 指定要镜像的画面尺寸（虚拟屏分辨率），并等待 GL 的输入 Surface。
     * 必须在把 view 挂到窗口之前调用。
     */
    public void mirror(int width, int height, InputSurfaceListener listener) {
        contentWidth = Math.max(1, width);
        contentHeight = Math.max(1, height);
        this.listener = listener;
        requestRender();
    }

    @Override
    public void onFrameAvailable(SurfaceTexture surfaceTexture) {
        requestRender();
    }

    private void notifyInputSurface(Surface surface, int width, int height) {
        InputSurfaceListener current = listener;
        if (current == null || surface == null || !surface.isValid()) {
            return;
        }
        current.onInputSurface(surface, width, height);
    }

    private final class Renderer implements GLSurfaceView.Renderer {

        private int program;
        private int aPosition;
        private int aUv;
        private int uTexture;
        private int uTexMatrix;
        private int uScale;
        private FloatBuffer quad;

        private int textureId;
        private SurfaceTexture surfaceTexture;
        private Surface inputSurface;
        private final float[] texMatrix = new float[16];
        private boolean ready;

        @Override
        public void onSurfaceCreated(GL10 gl, EGLConfig config) {
            releaseGl();
            GLES20.glClearColor(0f, 0f, 0f, 1f);

            int[] textures = new int[1];
            GLES20.glGenTextures(1, textures, 0);
            textureId = textures[0];
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0);

            surfaceTexture = new SurfaceTexture(textureId);
            surfaceTexture.setDefaultBufferSize(contentWidth, contentHeight);
            surfaceTexture.setOnFrameAvailableListener(MirrorGlView.this);
            inputSurface = new Surface(surfaceTexture);

            program = GlUtil.linkProgram(VERTEX_QUAD, FRAGMENT_OES);
            aPosition = GLES20.glGetAttribLocation(program, "aPosition");
            aUv = GLES20.glGetAttribLocation(program, "aUv");
            uTexture = GLES20.glGetUniformLocation(program, "uTexture");
            uTexMatrix = GLES20.glGetUniformLocation(program, "uTexMatrix");
            uScale = GLES20.glGetUniformLocation(program, "uScale");

            float[] data = {
                    -1f, -1f, 0f, 0f,
                    1f, -1f, 1f, 0f,
                    -1f, 1f, 0f, 1f,
                    1f, 1f, 1f, 1f
            };
            quad = ByteBuffer.allocateDirect(data.length * 4)
                    .order(ByteOrder.nativeOrder())
                    .asFloatBuffer();
            quad.put(data).position(0);

            ready = true;
            Log.i(TAG, "GL ready, input " + contentWidth + "x" + contentHeight);
            post(() -> notifyInputSurface(inputSurface, contentWidth, contentHeight));
            requestRender();
        }

        @Override
        public void onSurfaceChanged(GL10 gl, int width, int height) {
            viewWidth = Math.max(1, width);
            viewHeight = Math.max(1, height);
            GLES20.glViewport(0, 0, viewWidth, viewHeight);
            requestRender();
        }

        @Override
        public void onDrawFrame(GL10 gl) {
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            if (!ready || surfaceTexture == null) {
                return;
            }
            try {
                surfaceTexture.updateTexImage();
                surfaceTexture.getTransformMatrix(texMatrix);
            } catch (Throwable error) {
                Log.w(TAG, "updateTexImage 失败: " + error);
                return;
            }

            int eyeWidth = Math.max(1, viewWidth / 2);
            float eyeAspect = (float) eyeWidth / (float) viewHeight;
            float contentAspect = (float) contentWidth / (float) contentHeight;
            float scaleX = 1f;
            float scaleY = 1f;
            if (contentAspect > eyeAspect) {
                scaleY = eyeAspect / contentAspect;
            } else {
                scaleX = contentAspect / eyeAspect;
            }

            GLES20.glUseProgram(program);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId);
            GLES20.glUniform1i(uTexture, 0);
            GLES20.glUniformMatrix4fv(uTexMatrix, 1, false, texMatrix, 0);
            GLES20.glUniform2f(uScale, scaleX, scaleY);

            GLES20.glEnableVertexAttribArray(aPosition);
            GLES20.glEnableVertexAttribArray(aUv);
            quad.position(0);
            GLES20.glVertexAttribPointer(aPosition, 2, GLES20.GL_FLOAT, false, 16, quad);
            quad.position(2);
            GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 16, quad);

            for (int eye = 0; eye < 2; eye++) {
                GLES20.glViewport(eye * eyeWidth, 0, eyeWidth, viewHeight);
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            }

            GLES20.glDisableVertexAttribArray(aPosition);
            GLES20.glDisableVertexAttribArray(aUv);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0);
            GLES20.glViewport(0, 0, viewWidth, viewHeight);
        }

        private void releaseGl() {
            ready = false;
            if (program != 0) {
                GLES20.glDeleteProgram(program);
                program = 0;
            }
            if (surfaceTexture != null) {
                surfaceTexture.setOnFrameAvailableListener(null);
                surfaceTexture.release();
                surfaceTexture = null;
            }
            if (inputSurface != null) {
                inputSurface.release();
                inputSurface = null;
            }
            if (textureId != 0) {
                GLES20.glDeleteTextures(1, new int[]{textureId}, 0);
                textureId = 0;
            }
        }
    }
}
