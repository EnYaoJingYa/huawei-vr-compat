#!/usr/bin/env python3
"""生成一份最小的 1920x1080@60 EDID（仅 base block，128 字节）。

用途：RK3566 盒子上被 hvrglass 模块写入了「只有 3200x1600@70」的假 EDID，
接普通屏幕时无法锁定时序导致黑屏。这里造一份只声明 1080p 的 EDID，
写回 /sys/kernel/debug/dri/0/HDMI-A-1/edid_override 即可把画面救回来。

1080p60 的 TMDS 时钟 148.5MHz < 165MHz，不需要 CEA 扩展块。
"""
import struct
import sys


def dtd_1920x1080p60():
    """18 字节 Detailed Timing Descriptor。"""
    pixclk = 14850          # 10kHz 单位
    h_act, h_blank = 1920, 280
    h_fp, h_sw = 88, 44
    v_act, v_blank = 1080, 45
    v_fp, v_sw = 4, 5
    flags = 0x1E            # 数字分离同步，H/V 均为正极性

    b = bytearray(18)
    struct.pack_into("<H", b, 0, pixclk)
    b[2] = h_act & 0xFF
    b[3] = h_blank & 0xFF
    b[4] = ((h_act >> 8) & 0x0F) << 4 | ((h_blank >> 8) & 0x0F)
    b[5] = v_act & 0xFF
    b[6] = v_blank & 0xFF
    b[7] = ((v_act >> 8) & 0x0F) << 4 | ((v_blank >> 8) & 0x0F)
    b[8] = h_fp & 0xFF
    b[9] = h_sw & 0xFF
    b[10] = ((v_fp & 0x0F) << 4) | (v_sw & 0x0F)
    b[11] = (((h_fp >> 8) & 0x03) << 6 | ((h_sw >> 8) & 0x03) << 4 |
             ((v_fp >> 4) & 0x03) << 2 | ((v_sw >> 4) & 0x03))
    b[12] = 0               # 水平图像尺寸 mm（0 = 未定义，按 16:9 推算）
    b[13] = 0
    b[14] = 0x00
    b[15] = 0
    b[16] = 0
    b[17] = flags
    return bytes(b)


def build(width=1920, height=1080):
    e = bytearray(128)
    e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    # 厂商 ID "HVR" -> 0x0AC3 之类，这里用 0x1E6D（示例），产品码 0x1080
    mfg = ((ord('H') - 64) << 10) | ((ord('V') - 64) << 5) | (ord('R') - 64)
    struct.pack_into(">H", e, 8, mfg)
    struct.pack_into("<H", e, 10, 0x1080)      # 产品码
    struct.pack_into("<I", e, 12, 0x00000001)  # 序列号
    e[16] = 1                                   # 生产周
    e[17] = 2024 - 1990                         # 生产年
    e[18] = 1                                   # EDID 1.4
    e[19] = 4
    e[20] = 0xA3   # 输入：数字，8bit/color，HDMI-a
    e[21] = 0x34   # 屏幕尺寸 cm（52x29，约 23.8"）
    e[22] = 0x20
    e[23] = 120    # gamma 2.2
    e[24] = 0x0A   # 支持 DPMS 待机/挂起/关闭
    # 色度坐标（sRGB 常用值）
    e[25:35] = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])
    # 已建立时序：仅 640x480@60 保底
    e[35] = 0x20
    e[36] = 0x00
    e[37] = 0x00
    # 标准时序 8 组，全部填 0x01 0x01（未使用）
    for i in range(8):
        e[38 + i * 2] = 0x01
        e[39 + i * 2] = 0x01
    # 首选时序 DTD
    e[54:72] = dtd_1920x1080p60()
    # 后面三个描述符填显示器名 "HVR1080"
    def name_desc(text: str) -> bytes:
        d = bytearray(18)
        d[0:5] = b"\x00\x00\x00\xfc\x00"
        raw = text.encode("ascii")[:13]
        d[5:5 + len(raw)] = raw
        if len(raw) < 13:
            d[5 + len(raw)] = 0x0A
        return bytes(d)

    e[72:90] = name_desc("HVR1080P")
    # 范围限制描述符
    r = bytearray(18)
    r[0:5] = b"\x00\x00\x00\xfd\x00"
    r[5] = 48    # 最低场频
    r[6] = 75    # 最高场频
    r[7] = 30    # 最低行频 kHz
    r[8] = 90    # 最高行频 kHz
    r[9] = 15    # 最大像素时钟 150MHz
    r[10] = 0x00
    e[90:108] = bytes(r)
    e[108:126] = b"\x00" * 18   # 填充
    e[126] = 0                   # 无扩展块
    e[127] = (-sum(e[:127])) & 0xFF
    return bytes(e)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "edid_1080p.bin"
    data = build()
    with open(out, "wb") as fp:
        fp.write(data)
    print("写入 %s，%d 字节，校验和 0x%02X" % (out, len(data), data[127]))
    # 自检：整块 128 字节累加应为 0
    assert sum(data) & 0xFF == 0, "校验和错误"


if __name__ == "__main__":
    main()
