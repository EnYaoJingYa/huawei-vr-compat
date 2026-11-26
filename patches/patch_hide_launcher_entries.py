"""去掉五个原包的桌面图标，只留总控一个图标。

口径（用户 2026-10-31 明确要求）：「整合这几个 app 为 1 个」。
工程上七个包不能真的合并（三个 Unity 包各自带 libunity.so，一个 APK 放不下两套
Unity 播放器；七个资源表 ID 也互撞），所以采用「总控 App 唯一入口 + 原包降级为
后台引擎」：包还在、组件还在、能被显式启动，只是桌面上看不见、用户不需要碰。

做法只删一样东西：``<intent-filter>`` 里同时含
``android.intent.action.MAIN`` 与 ``android.intent.category.LAUNCHER`` 的那个
过滤器。**不删组件、不改 exported、不删权限**，所以：

* 总控仍然可以显式启动 ``com.huawei.vrlauncherx/.activity.Vr2dStartUpActivity``；
* 原版之间的显式组件调用、签名级权限校验、Provider 全部不变；
* 用户在「设置 → 应用」里仍然看得到这些包（只是没有桌面入口）。

为什么不改包名或合并 dex：三个 Unity 包的 ``assets/bin/Data`` 是按包内固定路径
加载的，且 ``libunity.so`` 同名不同构建，合并等于重写三个 Unity 播放器。

只处理文本清单：真正带图标的五个包清单都是文本 XML（apktool 正常解码的产物）。
另外两个（hvrsdkserverapp / vrservice）是二进制清单，本来就没有 LAUNCHER 入口，
不在处理范围；真遇到二进制会直接报错，不静默跳过。
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# 带桌面入口的五个包（第七个 vrservice 与 Runtime 包没有入口）。
TARGETS = (
    "com.huawei.appmarket.vr",
    "com.huawei.vrlauncherx",
    "com.huawei.himovie.vr",
    "com.huawei.vrvirtualscreen",
    "com.huawei.vrhandle",
)

MAIN = "android.intent.action.MAIN"
LAUNCHER = "android.intent.category.LAUNCHER"

INTENT_FILTER = re.compile(r"[ \t]*<intent-filter\b.*?</intent-filter>[ \t]*\r?\n?", re.S)


def is_launcher_filter(block):
    return MAIN in block and LAUNCHER in block


def patch(path):
    data = path.read_bytes()
    if data[:2] != b"<?":
        raise SystemExit(
            "%s 不是文本清单（二进制开头 %r）。本补丁只处理文本清单，"
            "遇到二进制请改用 axml_edit 版本。" % (path, data[:4]))

    # 按字节读写：Path.read_text/write_text 会把 CRLF 统一成 LF，
    # 那样整个清单每一行都算「改过」，diff 里看不出到底动了什么。
    text = data.decode("utf-8")
    before_activities = len(re.findall(r"<activity\b", text))
    before_filters = len(re.findall(r"<intent-filter\b", text))

    removed = []

    def drop(match):
        block = match.group(0)
        if is_launcher_filter(block):
            removed.append(block.strip().splitlines()[0].strip())
            return ""
        return block

    patched = INTENT_FILTER.sub(drop, text)

    # 断言 1：改完之后不允许再有任何 MAIN+LAUNCHER 组合。
    for block in INTENT_FILTER.findall(patched):
        if is_launcher_filter(block):
            raise SystemExit("%s 仍然存在桌面入口过滤器，替换没生效" % path)

    # 断言 2：只删了 intent-filter，活动数量必须一个不差。
    after_activities = len(re.findall(r"<activity\b", patched))
    if after_activities != before_activities:
        raise SystemExit(
            "%s 的 activity 数量变了（%d -> %d），说明删超范围了"
            % (path, before_activities, after_activities))

    after_filters = len(re.findall(r"<intent-filter\b", patched))
    if after_filters != before_filters - len(removed):
        raise SystemExit(
            "%s 的 intent-filter 数量对不上（%d - %d != %d）"
            % (path, before_filters, len(removed), after_filters))

    if not removed:
        print("%s: 本来就没有桌面入口，跳过" % path.parent.name)
        return

    path.write_bytes(patched.encode("utf-8"))
    print("%s: 去掉 %d 个桌面入口过滤器，activity 仍为 %d 个"
          % (path.parent.name, len(removed), after_activities))


def main():
    targets = sys.argv[1:] or list(TARGETS)
    for name in targets:
        manifest = REPO / "decode" / name / "AndroidManifest.xml"
        if not manifest.is_file():
            raise SystemExit("找不到清单：%s" % manifest)
        patch(manifest)


if __name__ == "__main__":
    main()
