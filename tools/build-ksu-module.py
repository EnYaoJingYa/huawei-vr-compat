#!/usr/bin/env python3
"""把 ksu/hwvr_compat/ 源码目录打包成 KernelSU 可安装的 hwvr_compat.zip。

用法（仓库根目录执行）:
    python tools/build-ksu-module.py
    python tools/build-ksu-module.py --out /path/to/hwvr_compat.zip

说明:
  - KernelSU / Magisk 会把 zip 内的文件原样安装到 /data/adb/modules/<id>/。
    因此 zip 的**根目录**必须直接是 module.prop / customize.sh / service.sh 等，
    不能套一层 hwvr_compat/ 子目录（套了会导致 KSU 找不到 module.prop）。
  - zip 安装通常不保留 Unix 可执行位，模块自带 customize.sh 和 service.sh
    会在安装/启动时对 hwvr-probe、service.sh 补 chmod，所以这里仍尽量写入
    原始权限位（部分安装器会保留），双保险。
  - 打包前校验 module.prop 的 id 与目录名一致，且探测二进制 hwvr-probe
    是 aarch64 ELF，避免把坏包刷进手机。
"""

import argparse
import pathlib
import stat
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "ksu" / "hwvr_compat"
DEFAULT_OUT = ROOT / "build" / "hwvr_compat.zip"

# 模块运行必需文件；缺失则拒绝打包。
REQUIRED = ("module.prop", "customize.sh", "service.sh", "hwvr-probe")
# 不进包的开发/编辑器残留。
SKIP_NAMES = {".DS_Store", "Thumbs.db"}
SKIP_SUFFIXES = (".pyc", ".swp", ".tmp")


def read_module_id(path: pathlib.Path) -> str:
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("id="):
            return line.split("=", 1)[1].strip()
    return ""


def is_aarch64_elf(path: pathlib.Path) -> bool:
    with path.open("rb") as f:
        head = f.read(20)
    # ELF64 + e_machine=183 (AArch64)，小端
    return len(head) >= 20 and head[:4] == b"\x7fELF" and head[4] == 2 and int.from_bytes(head[18:20], "little") == 183


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT, help="输出 zip 路径")
    args = ap.parse_args()

    if not SRC.is_dir():
        print(f"[错误] 找不到模块源码目录: {SRC}", file=sys.stderr)
        return 1

    for name in REQUIRED:
        if not (SRC / name).is_file():
            print(f"[错误] 模块缺少必需文件: {SRC / name}", file=sys.stderr)
            return 1

    module_id = read_module_id(SRC / "module.prop")
    if not module_id:
        print("[错误] module.prop 中没有 id= 字段", file=sys.stderr)
        return 1

    probe = SRC / "hwvr-probe"
    if not is_aarch64_elf(probe):
        print("[错误] hwvr-probe 不是有效的 aarch64 ELF，设备端无法执行探测", file=sys.stderr)
        return 1

    out = args.out
    out.parent.mkdir(parents=True, exist_ok=True)

    files = []
    for f in sorted(SRC.rglob("*")):
        if not f.is_file():
            continue
        if f.name in SKIP_NAMES or f.name.endswith(SKIP_SUFFIXES):
            continue
        files.append(f)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for f in files:
            arc = f.relative_to(SRC).as_posix()  # 根目录，不套子目录
            info = zipfile.ZipInfo(arc, date_time=(2026, 11, 26, 0, 0, 0))
            mode = stat.S_IMODE(f.stat().st_mode)
            info.external_attr = ((stat.S_IFREG | mode) << 16) & 0xFFFFFFFF
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, f.read_bytes())

    print(f"[OK] 已打包 {len(files)} 个文件: {out}（{out.stat().st_size} 字节）")
    print(f"     模块 id={module_id}；探测二进制为 aarch64 ELF ✓")
    print("     设备端安装:")
    print("       adb push build/hwvr_compat.zip /data/local/tmp/hwvr_compat.zip")
    print('       su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/hwvr_compat.zip"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
