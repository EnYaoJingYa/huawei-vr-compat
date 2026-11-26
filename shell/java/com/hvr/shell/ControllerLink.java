package com.hvr.shell;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;

import java.util.List;
import java.util.UUID;

/**
 * 华为 CF20 手柄链路（r29 按实机协议重写）。
 *
 * <p>协议依据 vrremote 项目的实测记录：
 * <ul>
 *   <li>厂商服务 {@code 622f5b2a-…}，真正的输入通道只有 {@code ffb4a651-…} 一路，
 *       订它就是约 100 包/秒的持续上报；同服务下 233827e5 一包数据都没有。</li>
 *   <li>HID 服务那三路 0x2A4D 的 CCCD 写在这个固件上会把 ATT 队列挂死
 *       （r17~r28 全都卡在这里），所以一律不碰。</li>
 *   <li>手柄不做系统配对（createBond 必然 auth_failure），特征也不要求加密，
 *       因此不请求绑定、不请求更大 MTU。</li>
 * </ul>
 *
 * <p>报文固定 20 字节：按键位、四元数、六轴、触控板绝对坐标、电量。
 */
final class ControllerLink {

    private static final UUID VENDOR_SERVICE =
            UUID.fromString("622f5b2a-60da-4484-929a-69e3a9140258");
    /** 唯一输入通道：订阅后约 100 包/秒。 */
    private static final UUID INPUT_CHANNEL =
            UUID.fromString("ffb4a651-c224-420b-a134-13d3aba313fb");
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    private static final String PREFS = "controller";
    private static final String KEY_MAC = "controller_mac";

    private static final String NAME_PREFIX = "HUAWEI CF20";
    private static final int FRAME_SIZE = 20;

    /* 报文 byte0 低 6 位的按键（高两位 0xC0 是帧标记，判断前要掩掉）。 */
    private static final int BTN_TRIGGER = 0x01;
    private static final int BTN_CONFIRM = 0x02;
    private static final int BTN_VOL_DOWN = 0x04;
    private static final int BTN_VOL_UP = 0x08;
    private static final int BTN_HOME = 0x10;
    private static final int BTN_BACK = 0x20;

    private static final long SCAN_WINDOW_MS = 12_000L;
    private static final long RECONNECT_MS = 3_000L;
    /** 每 100 包/秒都重绘整张 HUD 会拖死渲染，指针按位移与时间双重节流。 */
    private static final float POINTER_STEP_PX = 6f;
    private static final long POINTER_MIN_INTERVAL_MS = 60L;

    private static ControllerLink instance;

    private final Context context;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final SharedPreferences prefs;

    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private boolean scanning;
    private boolean running;

    private BluetoothGatt gatt;
    private boolean subscribed;

    private int frameCount;
    private int lastMask;
    private long lastLogAt;
    private long lastPointerAt;
    private float lastPx = -1f;
    private float lastPy = -1f;

    private ControllerLink(Context context) {
        this.context = context;
        this.prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static void start(Context context) {
        if (context == null) {
            return;
        }
        synchronized (ControllerLink.class) {
            if (instance == null) {
                instance = new ControllerLink(context.getApplicationContext());
            }
        }
        instance.begin();
    }

    static void stop() {
        synchronized (ControllerLink.class) {
            if (instance == null) {
                return;
            }
        }
        instance.end();
    }

    // ---------------------------------------------------------------- 生命周期

    private void begin() {
        if (running) {
            return;
        }
        running = true;
        BluetoothManager manager =
                (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = manager == null ? null : manager.getAdapter();
        if (adapter == null) {
            ShellState.controllerNote = "本机没有蓝牙适配器";
            running = false;
            return;
        }
        if (!ensureEnabled()) {
            running = false;
            return;
        }
        String saved = prefs.getString(KEY_MAC, null);
        if (saved != null) {
            ShellState.controllerNote = "手柄重连：" + saved;
            connectSaved(saved);
        }
        startScan();
        handler.postDelayed(scanTimeout, SCAN_WINDOW_MS);
    }

    private void end() {
        if (!running) {
            return;
        }
        running = false;
        handler.removeCallbacksAndMessages(null);
        stopScan();
        closeGatt();
        ShellState.controllerNote = "手柄已停止";
    }

    private boolean ensureEnabled() {
        try {
            if (adapter.isEnabled()) {
                return true;
            }
            ShellState.event("蓝牙未开启，正在请求打开");
            ShellState.controllerNote = "蓝牙未开启";
            android.content.Intent intent = new android.content.Intent(
                    BluetoothAdapter.ACTION_REQUEST_ENABLE);
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
        } catch (Throwable error) {
            ShellState.event("请求打开蓝牙失败", error);
        }
        return false;
    }

    // ------------------------------------------------------------------ 扫描

    private void startScan() {
        if (!running || scanning || gatt != null) {
            return;
        }
        try {
            scanner = adapter.getBluetoothLeScanner();
            if (scanner == null) {
                ShellState.event("蓝牙扫描器不可用（蓝牙可能还没开）");
                return;
            }
            ScanSettings settings = new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build();
            scanner.startScan(null, settings, callback);
            scanning = true;
            ShellState.controllerNote = "正在扫描手柄";
        } catch (Throwable error) {
            ShellState.event("启动扫描失败", error);
        }
    }

    private void stopScan() {
        if (!scanning) {
            return;
        }
        scanning = false;
        try {
            if (scanner != null) {
                scanner.stopScan(callback);
            }
        } catch (Throwable ignored) {
            // 蓝牙状态刚变化时 stopScan 会抛，忽略。
        }
    }

    private final Runnable scanTimeout = new Runnable() {
        @Override
        public void run() {
            if (!running || gatt != null) {
                return;
            }
            stopScan();
            ShellState.controllerNote = "未发现手柄，20 秒后重扫";
            handler.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (!running || gatt != null) {
                        return;
                    }
                    if (!ensureEnabled()) {
                        return;
                    }
                    startScan();
                    handler.postDelayed(scanTimeout, SCAN_WINDOW_MS);
                }
            }, 20_000L);
        }
    };

    private final ScanCallback callback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            onFound(result);
        }

        @Override
        public void onBatchScanResults(List<ScanResult> results) {
            for (ScanResult result : results) {
                onFound(result);
            }
        }

        @Override
        public void onScanFailed(int errorCode) {
            scanning = false;
            ShellState.event("蓝牙扫描失败，错误码 " + errorCode);
        }
    };

    private void onFound(ScanResult result) {
        if (gatt != null || !running || result == null || result.getDevice() == null) {
            return;
        }
        BluetoothDevice device = result.getDevice();
        if (!looksLikeController(device, result)) {
            return;
        }
        ShellState.event("发现手柄 " + safeName(device) + " " + device.getAddress());
        stopScan();
        connect(device);
    }

    /** 名称前缀或广播里的厂商服务 UUID，任一命中即认。 */
    private static boolean looksLikeController(BluetoothDevice device, ScanResult result) {
        String name = safeName(device);
        if (name != null && name.startsWith(NAME_PREFIX)) {
            return true;
        }
        try {
            if (result.getScanRecord() != null
                    && result.getScanRecord().getServiceUuids() != null) {
                String uuids = result.getScanRecord().getServiceUuids().toString().toLowerCase();
                return uuids.contains(VENDOR_SERVICE.toString().toLowerCase());
            }
        } catch (Throwable ignored) {
            // 扫描记录可能为 null
        }
        return false;
    }

    private static String safeName(BluetoothDevice device) {
        try {
            return device.getName();
        } catch (Throwable error) {
            return null;
        }
    }

    private void connectSaved(String address) {
        try {
            BluetoothDevice device = adapter.getRemoteDevice(address);
            connect(device);
        } catch (Throwable error) {
            ShellState.event("按地址重连失败 " + address, error);
            startScan();
        }
    }

    private void connect(BluetoothDevice device) {
        if (gatt != null) {
            return;
        }
        try {
            gatt = device.connectGatt(context, false, gattCallback,
                    BluetoothDevice.TRANSPORT_LE);
            if (gatt == null) {
                ShellState.event("connectGatt 返回空");
                return;
            }
            subscribed = false;
            prefs.edit().putString(KEY_MAC, device.getAddress()).apply();
            ShellState.controllerNote = "连接手柄中";
        } catch (Throwable error) {
            ShellState.event("connectGatt 失败", error);
            gatt = null;
        }
    }

    private void closeGatt() {
        BluetoothGatt open = gatt;
        gatt = null;
        subscribed = false;
        if (open == null) {
            return;
        }
        try {
            open.disconnect();
        } catch (Throwable ignored) {
            // 已断开
        }
        try {
            open.close();
        } catch (Throwable ignored) {
            // 已关闭
        }
    }

    // ------------------------------------------------------------------- GATT

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                ShellState.event("GATT 已连接，发现服务");
                ShellState.controllerNote = "手柄已连接，发现服务";
                try {
                    g.discoverServices();
                } catch (Throwable error) {
                    ShellState.event("discoverServices 失败", error);
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                ShellState.event("GATT 断开 status=" + status + "，本次共 " + frameCount + " 包");
                closeGatt();
                if (running) {
                    handler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            if (!running || gatt != null) {
                                return;
                            }
                            String saved = prefs.getString(KEY_MAC, null);
                            if (saved != null) {
                                ShellState.controllerNote = "手柄重连中";
                                connectSaved(saved);
                            } else {
                                startScan();
                            }
                        }
                    }, RECONNECT_MS);
                }
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                ShellState.event("服务发现失败 status=" + status);
                return;
            }
            BluetoothGattService service = g.getService(VENDOR_SERVICE);
            if (service == null) {
                ShellState.event("没有厂商服务（手柄可能没进入 VR 模式）");
                ShellState.controllerNote = "手柄无厂商服务";
                return;
            }
            BluetoothGattCharacteristic input = service.getCharacteristic(INPUT_CHANNEL);
            if (input == null) {
                ShellState.event("厂商服务里没有输入通道 ffb4a651");
                return;
            }
            if (!g.setCharacteristicNotification(input, true)) {
                ShellState.event("开启本地通知失败");
                return;
            }
            BluetoothGattDescriptor cccd = input.getDescriptor(CCCD);
            if (cccd == null) {
                ShellState.event("输入通道没有 CCCD 描述符");
                return;
            }
            try {
                cccd.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                if (!g.writeDescriptor(cccd)) {
                    ShellState.event("CCCD 写入被拒（GATT 忙）");
                }
            } catch (Throwable error) {
                ShellState.event("CCCD 写入异常", error);
            }
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor descriptor,
                                      int status) {
            if (descriptor == null || !CCCD.equals(descriptor.getUuid())) {
                return;
            }
            if (status != BluetoothGatt.GATT_SUCCESS) {
                ShellState.event("CCCD 订阅失败 status=" + status);
                return;
            }
            subscribed = true;
            frameCount = 0;
            lastMask = 0;
            lastPx = -1f;
            lastPy = -1f;
            ShellState.event("手柄已就绪，等待上报");
            ShellState.controllerNote = "手柄已连接";
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g,
                                            BluetoothGattCharacteristic characteristic) {
            if (characteristic == null
                    || !INPUT_CHANNEL.equals(characteristic.getUuid())) {
                return;
            }
            byte[] data = characteristic.getValue();
            if (data != null) {
                handleFrame(data);
            }
        }
    };

    // ------------------------------------------------------------------- 报文

    /** 20 字节报文：按键位 + 四元数 + 六轴 + 触控板 + 电量。 */
    private void handleFrame(byte[] data) {
        if (data.length != FRAME_SIZE) {
            if (frameCount == 0) {
                ShellState.event("报文长度异常 " + data.length + "：" + hex(data));
            }
            return;
        }
        frameCount++;

        int mask = data[0] & 0x3F;
        int touchX = data[15] & 0xFF;
        int touchY = data[16] & 0xFF;
        int level = data[17] & 0xFF;

        long now = System.currentTimeMillis();
        if (frameCount <= 3 || now - lastLogAt >= 2000L) {
            lastLogAt = now;
            boolean touched = touchX != 0 || touchY != 0;
            ShellState.event("手柄帧 #" + frameCount
                    + " 键=0x" + Integer.toHexString(data[0] & 0xFF)
                    + " 触控=" + touchX + "," + touchY + (touched ? "" : "（离开）")
                    + " 电量=" + level + "%"
                    + (frameCount <= 3 ? " 原始=" + hex(data) : ""));
            ShellState.controllerNote = "手柄已连接（" + frameCount + " 包，电量 " + level + "%）";
        }

        // 触控板绝对坐标 → 面板指针（(0,0) 表示手指离开）。
        if (touchX != 0 || touchY != 0) {
            movePointer(touchX / 255f, touchY / 255f);
        }

        if (mask != lastMask) {
            dispatchButtons(lastMask, mask);
            lastMask = mask;
        }
    }

    /** 按键位是「持续状态」，边沿检测后交给桌面统一路由（与触屏/无障碍同一条路）。 */
    private void dispatchButtons(int previous, int current) {
        emitKey(previous, current, BTN_TRIGGER, KeyEvent.KEYCODE_BUTTON_A);
        emitKey(previous, current, BTN_CONFIRM, KeyEvent.KEYCODE_ENTER);
        emitKey(previous, current, BTN_BACK, KeyEvent.KEYCODE_BACK);
        emitKey(previous, current, BTN_HOME, KeyEvent.KEYCODE_HOME);
        // 音量键留给系统，只记录不拦截。
    }

    private void emitKey(int previous, int current, int bit, int keyCode) {
        boolean wasDown = (previous & bit) != 0;
        boolean isDown = (current & bit) != 0;
        if (wasDown == isDown) {
            return;
        }
        DesktopPresenter.get().handleKey(context, isDown, keyCode);
    }

    /**
     * 触控板绝对坐标驱动指针。
     *
     * <p>桌面每帧重绘整张 HUD 位图，100Hz 直推会把渲染线程堵死，所以位移和
     * 时间都做节流。
     */
    private void movePointer(float nx, float ny) {
        long now = System.currentTimeMillis();
        if (now - lastPointerAt < POINTER_MIN_INTERVAL_MS) {
            return;
        }
        float px = VrUi.toPanelX(nx * 2f - 1f);
        float py = VrUi.toPanelY(ny * 2f - 1f);
        if (lastPx >= 0f
                && Math.abs(px - lastPx) < POINTER_STEP_PX
                && Math.abs(py - lastPy) < POINTER_STEP_PX) {
            return;
        }
        lastPointerAt = now;
        lastPx = px;
        lastPy = py;
        DesktopPresenter.get().setPointer(context, px, py, true);
    }

    private static String hex(byte[] data) {
        if (data == null) {
            return "null";
        }
        StringBuilder builder = new StringBuilder(data.length * 3);
        for (byte b : data) {
            if (builder.length() > 0) {
                builder.append(' ');
            }
            builder.append(String.format("%02X", b & 0xFF));
        }
        return builder.toString();
    }
}
