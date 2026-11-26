#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""让 HUAWEI VR Display 在 VR 桌面进程启动时就建好（显示承载链第 ①/② 环）。

背景（2026-11-08 第五轮，见 fix/README.md 11.13 / 分析文档第十三章）：

  原实现把「建 Presentation + 建虚拟屏」挂在
      HvrDisplayRouter.applyVrDisplay()  ->  HvrVrPanelPresenter.start()
  里，而 applyVrDisplay() 只在桌面内部 z0/c.B(Context, Class) 打开页面时
  被调用。这有两个硬伤：

    1. applyVrDisplay() 依赖 ContextEx.currentApplication()；该值在某些进程
       为 null（现场日志 HvrServiceManagerEx: no application context），
       于是 `if (context != null && start(context))` 直接短路 —— 这正好解释
       为什么全库 grep 不到任何一条 `HvrVrPanel` 日志。
    2. 就算 start() 跑起来，SurfaceView 的 surfaceCreated 是**异步**回调，
       同一次调用里 HvrVrVirtualDisplay.displayId() 必然还是 -1，于是当次
       打印 `HUAWEI VR Display not up yet`，应用落到 displayId=0。
       用户每点一次图标都在「第一次」，永远看不到面板。

修法：把建屏时机前移到进程启动。HvrContextProvider 是平台实例化的
ContentProvider，onCreate() 时 getContext() 一定非 null，且已先调用了
ContextEx.setApplication()。这里只给 **com.huawei.vrlauncherx** 进程
（也就是 z0/c.B() 发起 setLaunchDisplayId 的那个 uid）补一次
HvrVrPanelPresenter.start(context)：

    Presentation.show() 返回后，surface 回调异步触发
      -> HvrVrVirtualDisplay.ensure() 建 3200x1600 `HUAWEI VR Display`
      -> 之后任何一次 applyVrDisplay() 读 displayId() 都 >= 0
      -> setLaunchDisplayId 真正生效，VR 应用出现在桌面 3D 空间里

归属很关键：屏由启动方自己创建，isCallerAllowedToLaunchOnDisplay 放行同
uid，因此这条路径不依赖 LSPosed 的 trusted-display hook（那条是为「Runtime
建屏、桌面启动」的跨进程场景准备的）。

只改 classes4.dex 里的 HvrContextProvider，不动原版任何业务逻辑。
用法：
    python fix_panel_bootstrap.py <smali_dir>       # 幂等
"""
import sys
from pathlib import Path

REL = "com/huawei/vrframework/compat/HvrContextProvider.smali"
MARKER = "panel-bootstrap"

CALL_ANCHOR = (
    "    invoke-static {v0}, "
    "Lcom/huawei/vrframework/compat/HvrContextProvider;"
    "->startVrEnvironment(Landroid/content/Context;)V\n"
)
CALL_INSERT = (
    "\n    # panel-bootstrap: 进程启动即预建 VR 承载屏（仅 launcherx）\n"
    "    invoke-static {v0}, "
    "Lcom/huawei/vrframework/compat/HvrContextProvider;"
    "->maybeStartVrPanel(Landroid/content/Context;)V\n"
)

NEW_METHOD = r"""
.method private static maybeStartVrPanel(Landroid/content/Context;)V
    .registers 5

    if-eqz p0, :cond_done

    const-string v0, "com.huawei.vrlauncherx"

    invoke-virtual {p0}, Landroid/content/Context;->getPackageName()Ljava/lang/String;

    move-result-object v1

    invoke-virtual {v0, v1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :cond_done

    :try_start_boot
    # panel-bootstrap: 由启动方本进程建屏，绕过 ContextEx.currentApplication()
    invoke-static {p0}, Lcom/huawei/vrframework/compat/HvrVrPanelPresenter;->start(Landroid/content/Context;)Z

    move-result v0

    const-string v1, "HvrPanelBoot"

    const-string v2, "panel presenter bootstrapped at provider onCreate"

    invoke-static {v1, v2}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I
    :try_end_boot
    .catch Ljava/lang/Throwable; {:try_start_boot .. :try_end_boot} :catch_boot

    goto :cond_done

    :catch_boot
    move-exception v0

    const-string v1, "HvrPanelBoot"

    const-string v2, "panel bootstrap failed"

    invoke-static {v1, v2, v0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    :cond_done
    return-void
.end method
"""


def patch_smali(root):
    f = Path(root) / REL
    if not f.is_file():
        raise SystemExit(f"[FATAL] 找不到 {f}")
    text = f.read_text(encoding="utf-8").replace("\r\n", "\n")
    if MARKER in text:
        print("[=] 已打过 panel-bootstrap 补丁，跳过（幂等）")
        return
    if CALL_ANCHOR not in text:
        raise SystemExit("[FATAL] 找不到 onCreate 里的 startVrEnvironment 调用（smali 版本不匹配）")
    text = text.replace(CALL_ANCHOR, CALL_ANCHOR + CALL_INSERT, 1)
    text = text.rstrip("\n") + "\n" + NEW_METHOD
    f.write_text(text, encoding="utf-8")
    print(f"[+] 已 patch {f}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("用法: python fix_panel_bootstrap.py <smali_dir>")
    patch_smali(sys.argv[1])
