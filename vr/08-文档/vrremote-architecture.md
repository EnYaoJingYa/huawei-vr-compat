# 架构与数据流

## 模块

| 模块 | 内容 | 依赖 |
| --- | --- | --- |
| `:protocol` | 20 字节报文解析、按键位、体感解码 | 纯 Kotlin + JUnit |
| `:remote` | 四种模式的映射引擎、每 App 配置、编码解码、前台判断 | 纯 Kotlin + JUnit |
| `:app` | 蓝牙传输、Shizuku 注入、前台服务、界面 | Android |

前两个模块不依赖 Android，因此所有映射规则都能在 JVM 上直接跑测试。

## 数据流

```
手柄
  │ BLE 通知（20 字节，约 100 包/秒）
  ▼
BleControllerTransport        连接、扫描、重连、状态机
  │ ByteArray
  ▼
ControllerFrameParser         长度校验 → ControllerFrame
  ▼
RemoteEngine                  模式规则 → List<RemoteAction>
  ▼
RemoteCore                    模式切换、提示、前台应用轮询
  ▼
InputBridge                   坐标换算、按键拆分
  │ AIDL（oneway）
  ▼
InputService                  Shizuku 用户服务，shell 身份
  ├── UHID：虚拟键盘 / 消费者控制 / 相对鼠标
  └── /system/bin/input：屏幕手势（swipe / tap / long press）
  ▼
Android 输入子系统
```

## 线程模型

- **主线程**：Activity、GATT 回调、状态流、映射引擎与 `InputBridge` 调用。每帧工作很
  小，动作都是 oneway binder 调用，不会阻塞。
- **IO**：仅在「跟随应用」模式下列出前台包名，每 400 ms 一次 binder 调用。
- **用户服务内单线程执行器**：手势和 `input keyevent` 串行执行，避免两个合成触摸
  重叠。
- **测试页**：报文解析放在 `Dispatchers.Default`，用锁保护快照，UI 以 50/200 ms
  节奏合并刷新。

## 状态

- `ConnectionState`：Idle / Scanning / Connecting / Discovering / Subscribing /
  Ready / Disconnected / Failed，界面任何时刻只显示一个。
- 模式：`RemoteMode`，扳机键按下沿触发切换，300 ms 防抖。
- 前台包名：只在跟随应用模式下跟踪；读不到时清空，不沿用上一个 App。

## 存储

全部在 `SharedPreferences`（文件名 `remote`）：

- 模式、遥控开关、模式提示开关
- 方向键步长、指尖鼠标灵敏度、体感鼠标灵敏度与死区、手势幅度
- `app_profiles`：每 App 配置，一行一条，字段用制表符分隔、条目用换行分隔；
  编码时会清洗标签里的制表符和换行，解码时跳过不认识的触发和动作。

## 注入细节

UHID 设备在 Shizuku 用户服务进程里创建（shell 身份，可直接打开 `/dev/uhid`）：

- 键盘：标准 8 字节报告，方向键、回车、上下翻页
- 消费者控制：两字节位图，音量、静音、主页、返回、播放/暂停、上下曲、快进/快退、
  菜单、最近任务
- 鼠标：四字节报告，按键位 + 相对 X/Y

这些用法经过内核 `hid-input` 翻译成 Linux 键码，再由设备自带的按键布局翻译成安卓
键值；`dumpsys input` 输出的 KeyBitmask 可以逐项核对。

屏幕手势不在 UHID 链路上，直接调用系统自带的 `input` 命令，坐标按当前显示尺寸
计算（竖向行程为屏高 30%，横向为屏宽 40%，时长 200 ms）。
