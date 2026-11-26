/* modeinfo.c — 裸 DRM ioctl 打印 connector 全部模式的完整时序（无 libdrm 依赖） */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/ioctl.h>

/* --- 内核 UAPI 复刻（linux/drm_mode.h + drm.h） --- */
#define DRM_IOCTL_BASE 'd'
#define DRM_IO(nr)       _IO(DRM_IOCTL_BASE, nr)
#define DRM_IOW(nr, t)   _IOW(DRM_IOCTL_BASE, nr, t)
#define DRM_IOWR(nr, t)  _IOWR(DRM_IOCTL_BASE, nr, t)

struct drm_mode_card_res {
    uint64_t fb_id_ptr; uint64_t crtc_id_ptr;
    uint64_t connector_id_ptr; uint64_t encoder_id_ptr;
    uint32_t count_fbs, count_crtcs, count_connectors, count_encoders;
    uint32_t min_width, max_width, min_height, max_height;
};

struct drm_mode_modeinfo {
    uint32_t clock;
    uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
    uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
    uint32_t vrefresh, flags, type;
    char name[32];
};

struct drm_mode_get_connector {
    uint64_t encoders_ptr, modes_ptr, props_ptr, prop_values_ptr;
    uint32_t count_modes, count_encoders, count_props;
    uint32_t encoder_id, connector_id;
};

#define DRM_IOCTL_MODE_GETRESOURCES DRM_IOWR(0xA0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETCONNECTOR DRM_IOWR(0xA7, struct drm_mode_get_connector)

int main(void)
{
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) { perror("card0"); return 1; }

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof(res));
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("getres"); return 1; }
    printf("connectors=%u\n", res.count_connectors);

    uint32_t *conn_ids = calloc(res.count_connectors, 4);
    res.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;
    /* 只请求 connector 列表，其余 count 置 0 避免 EFAULT */
    res.count_fbs = 0; res.count_crtcs = 0; res.count_encoders = 0;
    res.fb_id_ptr = 0; res.crtc_id_ptr = 0; res.encoder_id_ptr = 0;
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("getres2"); return 1; }

    for (uint32_t i = 0; i < res.count_connectors; i++) {
        struct drm_mode_get_connector c;
        memset(&c, 0, sizeof(c));
        c.connector_id = conn_ids[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) { perror("getconn"); continue; }
        struct drm_mode_modeinfo *modes = calloc(c.count_modes ? c.count_modes : 1, sizeof(*modes));
        c.modes_ptr = (uint64_t)(uintptr_t)modes;
        /* 只请求 mode 列表，props/encoders 容量置 0 避免 EFAULT */
        c.count_props = 0; c.count_encoders = 0;
        c.props_ptr = 0; c.prop_values_ptr = 0; c.encoders_ptr = 0;
        if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) { perror("getconn2"); continue; }
        printf("connector %u: modes=%u\n", c.connector_id, c.count_modes);
        for (uint32_t m = 0; m < c.count_modes; m++) {
            struct drm_mode_modeinfo *mo = &modes[m];
            printf("MODE name=%-16s clock=%-7u h=%u/%u/%u/%u v=%u/%u/%u/%u "
                   "vrefresh=%u flags=0x%x type=0x%x\n",
                   mo->name, mo->clock,
                   mo->hdisplay, mo->hsync_start, mo->hsync_end, mo->htotal,
                   mo->vdisplay, mo->vsync_start, mo->vsync_end, mo->vtotal,
                   mo->vrefresh, mo->flags, mo->type);
        }
        free(modes);
    }
    close(fd);
    return 0;
}
