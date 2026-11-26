/*
 * hwvr-activate: 向 VR 眼镜控制接口补发激活指令 HIDIOCSFEATURE(5)。
 *
 * 协议见 docs/HELMET_HID_PROTOCOL.md 第 1.2 节：
 *   WalleCommon::ioActiveDev(DEVICE_TYPE) -> ioctl(0xC0054806)
 *   buf[0]=5 (report id), buf[1..4]=DEVICE_TYPE & 0x7E
 * 成功时 libWalleDev 打印 "active device(2) OK"。
 *
 * 为什么需要它（2026-11-08 真机取证）：
 *   WalleDev.cpp ThreadLoop 在 read error 后把 glass 置 STATUS_FAULT，
 *   然后每 100ms 重复 closeDevice -> openDevice success，来不及走到
 *   ioActiveDev，眼镜始终停在未激活态（黑屏）。手册 4.3 记载眼镜的
 *   激活态是「粘性」的，一次成功的 HIDIOCSFEATURE(5) 就能让它保持点亮。
 *   由 Magisk 模块低频补发，绕开 SDK 的死循环，不改任何 Java/native 代码。
 *
 * 用法：hwvr-activate [节点] [DEVICE_TYPE] [spread]
 *   /dev/hwvr1 2 0   -> 05 02 00 00 00（小端 int 写法，默认）
 *   /dev/hwvr1 2 1   -> 05 02 02 02 02（按手册字面「buf[1..4]=」写法）
 * 返回：0 成功 / 3 打不开节点 / 4 ioctl 失败
 *
 * 编译（NDK r26）：
 *   aarch64-linux-android29-clang -static -O2 -o hwvr-activate hwvr-activate.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>

#define HIDIOCS_FEATURE(len) _IOC(_IOC_WRITE | _IOC_READ, 'H', 0x06, len)

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/hwvr1";
    int type = argc > 2 ? atoi(argv[2]) : 2;
    int spread = argc > 3 ? atoi(argv[3]) : 0;
    int rc, i;

    int fd = open(dev, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
        return 3;
    }

    unsigned char buf[8];
    memset(buf, 0, sizeof(buf));
    buf[0] = 5;                       /* report id: ioActiveDev */
    if (spread) {
        for (i = 1; i < 5; i++) buf[i] = (unsigned char)(type & 0x7E);
    } else {
        buf[1] = (unsigned char)(type & 0x7E);
    }

    rc = ioctl(fd, HIDIOCS_FEATURE(5), buf);
    if (rc < 0) {
        fprintf(stderr, "HIDIOCSFEATURE(5) failed: %s\n", strerror(errno));
    } else {
        printf("active device(%d) sent, ret=%d, payload=%02x%02x%02x%02x%02x\n",
               type, rc, buf[0], buf[1], buf[2], buf[3], buf[4]);
    }
    close(fd);
    return rc < 0 ? 4 : 0;
}
