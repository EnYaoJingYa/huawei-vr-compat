/* hwvr-activate.c — 向华为 VR 眼镜控制接口发送「激活设备」feature report
 *
 * 协议（见 docs/HELMET_HID_PROTOCOL.md）：
 *   ioActiveDev : HIDIOCSFEATURE(5), buf[0]=5, buf[1..4]=DEVICE_TYPE & 0x7E
 *   ioDeactive  : HIDIOCSFEATURE(5), buf[0]=6
 *
 * 用法:
 *   hwvr-activate /dev/hidraw0 5 <type>      # type 缺省 1
 *   hwvr-activate /dev/hidraw0 6 <type>      # 去激活
 *   hwvr-activate /dev/hidraw0 scan          # 扫 type 0..0x7E 步进2
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/hidraw.h>

static int send_feat(int fd, unsigned char rid, unsigned char type)
{
    unsigned char buf[5] = { rid, (unsigned char)(type & 0x7E), 0, 0, 0 };
    int res = ioctl(fd, HIDIOCSFEATURE(5), buf);
    printf("  SET feat rid=%u type=0x%02x -> %d %s\n",
           rid, buf[1], res, res < 0 ? strerror(errno) : "");
    return res;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s NODE {5|6|scan} [type]\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", argv[1], strerror(errno)); return 1; }

    struct hidraw_devinfo info;
    if (ioctl(fd, HIDIOCGRAWINFO, &info) == 0)
        printf("node %s: bust=%04x vendor=%04x product=%04x\n",
               argv[1], info.bustype, (unsigned short)info.vendor, (unsigned short)info.product);

    if (strcmp(argv[2], "scan") == 0) {
        for (unsigned t = 0; t <= 0x7E; t += 2)
            if (send_feat(fd, 5, (unsigned char)t) >= 0)
                usleep(120000);
    } else {
        unsigned type = argc > 3 ? (unsigned)strtoul(argv[3], 0, 0) : 1;
        send_feat(fd, (unsigned char)strtoul(argv[2], 0, 0), (unsigned char)type);
    }
    close(fd);
    return 0;
}
