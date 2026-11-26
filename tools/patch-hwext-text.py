#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 apktool 文本解码树里对 EMUI 扩展资源包 androidhwext 的引用清掉。

背景见 patches/patch_hwext_attr_refs.py 与 patches/patch_emui_theme_parents.py：
`androidhwext`（资源包 id 0x02）只在 EMUI 固件里作为共享库加载，AOSP/RK3566 上
不存在。引用它会有两种后果：

    ?androidhwext:textSizeBody2        -> 运行时属性查不到，0x8 原样透传，
                                          TextView 读 textAppearance 直接抛
                                          UnsupportedOperationException
    parent="@androidhwext:style/..."   -> aapt2 链接期就报 resource not found

这个脚本按文件类型分别处理，只动「指向」，不动样式名、条目、文案、布局结构：

    res/layout*/**.xml        删掉取值以 ?androidhwext: 开头的属性
    res/values*/**.xml        把 @androidhwext:style/Theme.Emui* 父级换成 AOSP 同源主题

用法：
    python tools/patch-hwext-text.py <解码树目录>
    python tools/patch-hwext-text.py decode/com.huawei.vrvirtualscreen --dry-run
"""

import argparse
import io
import re
import sys
from pathlib import Path

# EMUI 主题 -> AOSP 同源主题（与原包色系一致，都带 NoActionBar）
THEME_MAP = {
    "Theme.Emui": "@android:style/Theme.Holo.Light.NoActionBar",
    "Theme.Emui.Dark": "@android:style/Theme.Holo.NoActionBar",
    "Theme.Emui.Dark.Emphasize": "@android:style/Theme.Holo.NoActionBar",
    "Theme.Emui.NoActionBar": "@android:style/Theme.Holo.NoActionBar",
    "Theme.Emui.Light.NoActionBar": "@android:style/Theme.Holo.Light.NoActionBar",
    "Theme.Emui.Dialog.Alert": "@android:style/Theme.Holo.Dialog.Alert",
    "Theme.Emui.Dialog": "@android:style/Theme.Holo.Dialog",
}

# 形如 android:textSize="?androidhwext:textSizeBody2" 的整个属性
ATTR_RE = re.compile(r'\s+[\w:.\-]+="\?androidhwext:[^"]*"')
# 同时覆盖 parent="@androidhwext:style/X" 与 android:theme="@androidhwext:style/X"
STYLE_REF_RE = re.compile(r'@androidhwext:style/([^"<>\s]+)')
OTHER_REF_RE = re.compile(r'[@?]androidhwext:[\w./]+')


def patch_layout(text):
    """删掉属性引用；返回 (新文本, 删除处数)。"""
    new, n = ATTR_RE.subn("", text)
    return new, n


def patch_values(text):
    """替换主题引用（样式父级与清单里的 android:theme）；返回 (新文本, 替换处数)。"""
    def repl(match):
        name = match.group(1)
        if name not in THEME_MAP:
            raise SystemExit("未知的 EMUI 主题：%s（请在 THEME_MAP 里补上）" % name)
        return THEME_MAP[name]

    new, n = STYLE_REF_RE.subn(repl, text)
    return new, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tree", help="apktool 解码树目录")
    ap.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    args = ap.parse_args()

    tree = Path(args.tree)
    if not (tree / "res").is_dir():
        raise SystemExit("不是解码树（没有 res/）：%s" % tree)

    total_attrs = 0
    total_parents = 0
    touched = 0
    leftovers = []

    for path in sorted((tree / "res").rglob("*.xml")) + [tree / "AndroidManifest.xml"]:
        if not path.exists():
            continue
        rel = path.relative_to(tree).as_posix()
        text = io.open(path, encoding="utf-8", newline="").read()
        if "androidhwext" not in text:
            continue
        if "/layout" in rel or rel.startswith("res/xml"):
            new, n = patch_layout(text)
            total_attrs += n
        else:
            new, n = patch_values(text)
            total_parents += n
        if new != text:
            touched += 1
            if not args.dry_run:
                io.open(path, "w", encoding="utf-8", newline="").write(new)
        rest = OTHER_REF_RE.findall(new)
        if rest:
            leftovers.append((rel, sorted(set(rest))))

    verb = "将修改" if args.dry_run else "已修改"
    print("%s %d 个文件：删属性引用 %d 处，替换主题父级 %d 处"
          % (verb, touched, total_attrs, total_parents))
    for rel, refs in leftovers:
        print("  残留 %s: %s" % (rel, ", ".join(refs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
