"""给投屏包补上免 root 投屏需要的组件与权限。

只做三件事：

  * 声明 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PROJECTION`
    （MediaProjection 在 Android 10+ 要求一条 `mediaProjection` 类型的前台服务）；
  * 注册 `HvrMirrorActivity`（申请一次录屏授权，透明主题，不占最近任务）；
  * 注册 `HvrMirrorService`（`foregroundServiceType="mediaProjection"`）。

不改任何原有组件、权限或 intent-filter。重复执行会跳过。

用法：python patches/patch_mirror_entry.py [仓库根]
"""

import io
import re
import sys
from pathlib import Path

MODULE = "com.huawei.vrvirtualscreen"
MANIFEST = "AndroidManifest.xml"

PERMISSION_ANCHOR = (
    '    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>\n'
)
PERMISSIONS = PERMISSION_ANCHOR + (
    '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n'
    '    <uses-permission '
    'android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"/>\n'
)

COMPONENTS = (
    '        <activity '
    'android:name="com.huawei.vrvirtualscreen.mirror.HvrMirrorActivity" '
    'android:exported="false" android:excludeFromRecents="true" '
    'android:theme="@android:style/Theme.Translucent.NoTitleBar"/>\n'
    '        <service '
    'android:name="com.huawei.vrvirtualscreen.mirror.HvrMirrorService" '
    'android:exported="false" android:foregroundServiceType="mediaProjection"/>\n'
)

APPLICATION = re.compile(r'(<application\b[^>]*>\n)')


def main(root):
    path = Path(root) / "decode" / MODULE / MANIFEST
    if not path.exists():
        raise SystemExit("missing %s" % path)
    raw = io.open(path, encoding="utf-8", newline="").read()
    eol = "\r\n" if "\r\n" in raw else "\n"
    text = raw.replace("\r\n", "\n")
    if "HvrMirrorActivity" in text:
        print("已经补过免 root 投屏组件，跳过")
        return
    if PERMISSION_ANCHOR not in text:
        raise SystemExit("找不到 SYSTEM_ALERT_WINDOW 锚点")
    text = text.replace(PERMISSION_ANCHOR, PERMISSIONS, 1)
    text, count = APPLICATION.subn(r'\1' + COMPONENTS, text, count=1)
    if count != 1:
        raise SystemExit("application 锚点匹配 %d 次，期望 1 次" % count)
    if eol != "\n":
        text = text.replace("\n", eol)
    path.write_text(text, encoding="utf-8", newline="")
    print("已补上免 root 投屏组件：%s" % MANIFEST)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parents[1]))
