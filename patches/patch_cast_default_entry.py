"""让投屏应用点开图标就直接进免 root 投屏。

`Vr2dStartUpActivity` 是投屏包的 LAUNCHER 入口（帮助页）。这里在它的
`onCreate` 最前面插入一次调用：

    HvrMirrorEntry.start(Activity)
        -> 眼镜在位时，启动 HvrMirrorActivity（系统弹一次录屏授权），
           由 HvrMirrorService 用 MediaProjection 把手机默认屏镜像到眼镜副屏；
        -> 眼镜不在位时什么都不做，原帮助页原样保留。

只加一次静态调用，不改原帮助页的任何逻辑。

用法：python patches/patch_cast_default_entry.py [仓库根]
"""

import io
import sys
from pathlib import Path

MODULE = "com.huawei.vrvirtualscreen"
SMALI = "smali/com/huawei/vrvirtualscreen/main/view/Vr2dStartUpActivity.smali"

ANCHOR = (
    "    invoke-super {p0, p1}, Landroid/app/Activity;"
    "->onCreate(Landroid/os/Bundle;)V\n"
)

INJECTED = ANCHOR + (
    "\n"
    "    # 默认投屏入口：眼镜在位时直接进免 root 投屏（MediaProjection + 眼镜副屏）；\n"
    "    # 见 patches/patch_cast_default_entry.py。\n"
    "    invoke-static {p0}, Lcom/huawei/vrvirtualscreen/mirror/HvrMirrorEntry;"
    "->start(Landroid/app/Activity;)V\n"
    "\n"
)


def main(root):
    path = Path(root) / "decode" / MODULE / SMALI
    if not path.exists():
        raise SystemExit("missing %s" % path)
    raw = io.open(path, encoding="utf-8", newline="").read()
    eol = "\r\n" if "\r\n" in raw else "\n"
    text = raw.replace("\r\n", "\n")
    if "HvrMirrorEntry;->start" in text:
        print("已经补过默认投屏入口，跳过")
        return
    if text.count(ANCHOR) != 1:
        raise SystemExit("锚点匹配 %d 次，期望 1 次" % text.count(ANCHOR))
    patched = text.replace(ANCHOR, INJECTED)
    if eol != "\n":
        patched = patched.replace("\n", eol)
    path.write_text(patched, encoding="utf-8", newline="")
    print("已补上默认投屏入口：%s" % SMALI)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parents[1]))
