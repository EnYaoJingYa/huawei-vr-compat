package com.huawei.android.media;

import android.content.Context;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.huawei.vrservice.compat.CompatAppContext;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executor;

/**
 * Huawei's AudioManager extension, limited to the audio-mode callback the
 * original code uses.
 *
 * The original VrAudioMonitor subscribes here to be told when the audio mode
 * changes (it then moves the volume between the phone and the helmet). The
 * common-Android equivalent is the public AudioManager#addOnModeChangedListener,
 * available from API 31. Below that the callback cannot be delivered and this
 * class says so in the log rather than firing made-up events.
 *
 * The constructor takes no Context (that is the original signature); the context
 * comes from the compat provider in this process, see CompatAppContext.
 */
public class AudioManagerEx {

    private static final String TAG = "HvrAudioManagerEx";

    private final Map<IAudioModeCallback, Object> registered =
            new HashMap<IAudioModeCallback, Object>();

    public AudioManagerEx() {
    }

    public void registerAudioModeCallback(final IAudioModeCallback callback, Handler handler) {
        if (callback == null) {
            return;
        }
        Context context = CompatAppContext.get();
        if (context == null) {
            Log.w(TAG, "no application context yet; audio mode callback not registered");
            return;
        }
        if (Build.VERSION.SDK_INT < 31) {
            Log.w(TAG, "addOnModeChangedListener needs API 31+; audio mode callback not registered");
            return;
        }
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (manager == null) {
            Log.w(TAG, "AudioManager unavailable");
            return;
        }
        // OnModeChangedListener 是 API 31 新增接口，编译目标只有 android-30，
        // 用反射 + Proxy 注册：编译期不引用符号，运行时（API 31+）仍走官方路径。
        final Executor executor = executorFor(handler);
        Object listener;
        try {
            Class<?> listenerClass = Class.forName("android.media.AudioManager$OnModeChangedListener");
            listener = java.lang.reflect.Proxy.newProxyInstance(
                    AudioManager.class.getClassLoader(), new Class<?>[]{listenerClass},
                    new java.lang.reflect.InvocationHandler() {
                        @Override
                        public Object invoke(Object proxy, java.lang.reflect.Method method,
                                             Object[] args) {
                            if ("onModeChanged".equals(method.getName())
                                    && args != null && args.length == 1) {
                                callback.onAudioModeChanged((Integer) args[0]);
                            }
                            return null;
                        }
                    });
            java.lang.reflect.Method add = AudioManager.class.getMethod(
                    "addOnModeChangedListener", java.util.concurrent.Executor.class, listenerClass);
            add.invoke(manager, executor, listener);
        } catch (Throwable error) {
            Log.w(TAG, "addOnModeChangedListener failed", error);
            return;
        }
        synchronized (registered) {
            registered.put(callback, listener);
        }
    }

    public void unregisterAudioModeCallback(IAudioModeCallback callback) {
        if (callback == null) {
            return;
        }
        Object listener;
        synchronized (registered) {
            listener = registered.remove(callback);
        }
        if (listener == null) {
            return;
        }
        Context context = CompatAppContext.get();
        if (context == null) {
            return;
        }
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (manager == null) {
            return;
        }
        try {
            Class<?> listenerClass = Class.forName("android.media.AudioManager$OnModeChangedListener");
            java.lang.reflect.Method remove = AudioManager.class.getMethod(
                    "removeOnModeChangedListener", listenerClass);
            remove.invoke(manager, listener);
        } catch (Throwable error) {
            Log.w(TAG, "removeOnModeChangedListener failed", error);
        }
    }

    private static Executor executorFor(Handler handler) {
        if (handler != null) {
            final Handler target = handler;
            return new Executor() {
                @Override
                public void execute(Runnable command) {
                    target.post(command);
                }
            };
        }
        // The original call passes a null Handler; deliver on the main looper.
        final Handler main = new Handler(Looper.getMainLooper());
        return new Executor() {
            @Override
            public void execute(Runnable command) {
                main.post(command);
            }
        };
    }
}