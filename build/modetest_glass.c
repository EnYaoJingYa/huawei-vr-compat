/* modetest_glass.c - minimal DRM modeset, no libdrm dependency.
 * Finds the connected HDMI connector, sets its preferred mode (3200x1600),
 * fills a dumb buffer with color bars, keeps running until killed.
 * Build: aarch64-linux-android30-clang modetest_glass.c -o modetest_glass
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <stdint.h>

#include <linux/types.h>
#include <stdint.h>

#define DRM_IOCTL_BASE 'd'

struct drm_mode_modeinfo {
    __u32 clock;
    __u16 hdisplay, hsync_start, hsync_end, htotal, hskew;
    __u16 vdisplay, vsync_start, vsync_end, vtotal, vscan;
    __u32 vrefresh;
    __u32 flags;
    __u32 type;
    char name[32];
};

struct drm_mode_card_res {
    __u64 framebuffer_id_ptr; __u64 crtc_id_ptr;
    __u64 connector_id_ptr;   __u64 encoder_id_ptr;
    __u32 count_fbs; __u32 count_crtcs;
    __u32 count_connectors; __u32 count_encoders;
    __u32 min_width; __u32 max_width;
    __u32 min_height; __u32 max_height;
};

struct drm_mode_get_connector {
    __u64 encoders_ptr; __u64 modes_ptr;
    __u64 props_ptr;    __u64 prop_values_ptr;
    __u32 count_modes;  __u32 count_encoders; __u32 count_props;
    __u32 encoder_id;   __u32 connector_id;
    __u32 connector_type; __u32 connector_type_id;
    __u32 connection;   __u32 mm_width; __u32 mm_height;
    __u32 subpixel;     __u32 pad;
};

struct drm_mode_get_encoder {
    __u32 encoder_id; __u32 encoder_type; __u32 crtc_id;
    __u32 possible_crtcs; __u32 possible_clones; __u32 pad;
};

struct drm_mode_crtc {
    __u64 set_connectors_ptr;
    __u32 count_connectors;
    __u32 crtc_id;
    __u32 fb_id; __u32 x; __u32 y;
    __u32 gamma_size;
    __u32 mode_valid;
    struct drm_mode_modeinfo mode;
};

struct drm_mode_create_dumb {
    __u32 height; __u32 width; __u32 bpp; __u32 flags;
    __u32 handle; __u32 pitch; __u64 size;
};

struct drm_mode_map_dumb {
    __u32 handle; __u32 pad; __u64 offset;
};

struct drm_mode_fb_cmd {
    __u32 fb_id;
    __u32 width; __u32 height; __u32 pitch; __u32 bpp;
    __u32 depth; __u32 handle;
};

#define DRM_IOCTL_MODE_GETRESOURCES  _IOWR(DRM_IOCTL_BASE, 0xA0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETCRTC       _IOWR(DRM_IOCTL_BASE, 0xA1, struct drm_mode_crtc)
#define DRM_IOCTL_MODE_SETCRTC       _IOWR(DRM_IOCTL_BASE, 0xA2, struct drm_mode_crtc)
#define DRM_IOCTL_MODE_GETENCODER    _IOWR(DRM_IOCTL_BASE, 0xA6, struct drm_mode_get_encoder)
#define DRM_IOCTL_MODE_GETCONNECTOR  _IOWR(DRM_IOCTL_BASE, 0xA7, struct drm_mode_get_connector)
#define DRM_IOCTL_MODE_ADDFB         _IOWR(DRM_IOCTL_BASE, 0xAE, struct drm_mode_fb_cmd)
#define DRM_IOCTL_MODE_RMFB          _IOWR(DRM_IOCTL_BASE, 0xAF, unsigned int)
#define DRM_IOCTL_MODE_CREATE_DUMB   _IOWR(DRM_IOCTL_BASE, 0xB2, struct drm_mode_create_dumb)
#define DRM_IOCTL_MODE_MAP_DUMB      _IOWR(DRM_IOCTL_BASE, 0xB3, struct drm_mode_map_dumb)
#define DRM_IOCTL_MODE_DESTROY_DUMB  _IOWR(DRM_IOCTL_BASE, 0xB4, struct drm_mode_create_dumb)

static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

int main(int argc, char **argv) {
    const char *node = argc > 1 ? argv[1] : "/dev/dri/card0";
    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", node, strerror(errno)); return 1; }

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof(res));
    if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) {
        fprintf(stderr, "GETRESOURCES: %s\n", strerror(errno)); return 1;
    }
    uint32_t ncrtc = res.count_crtcs, nconn = res.count_connectors;
    printf("crtcs=%u connectors=%u min=%ux%u max=%ux%u\n",
           ncrtc, nconn, res.min_width, res.min_height, res.max_width, res.max_height);

    uint32_t *fb_ids = calloc(res.count_fbs ? res.count_fbs : 1, 4);
    uint32_t *crtc_ids = calloc(ncrtc ? ncrtc : 1, 4), *conn_ids = calloc(nconn ? nconn : 1, 4);
    uint32_t *enc_ids = calloc(res.count_encoders ? res.count_encoders : 1, 4);
    res.framebuffer_id_ptr = (uint64_t)(uintptr_t)fb_ids;
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtc_ids;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;
    res.encoder_id_ptr = (uint64_t)(uintptr_t)enc_ids;
    if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) {
        fprintf(stderr, "GETRESOURCES2: %s\n", strerror(errno)); return 1;
    }

    /* find connected connector with modes */
    int found = -1;
    struct drm_mode_get_connector c;
    static struct drm_mode_modeinfo modes[64];
    for (uint32_t i = 0; i < nconn; i++) {
        memset(&c, 0, sizeof(c));
        c.connector_id = conn_ids[i];
        c.modes_ptr = (uint64_t)(uintptr_t)modes;
        c.count_modes = 64;
        if (xioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) continue;
        printf("conn %u: type=%u.%u connection=%u modes=%u enc=%u\n",
               c.connector_id, c.connector_type, c.connector_type_id,
               c.connection, c.count_modes, c.encoder_id);
        if (c.connection == 1 && c.count_modes > 0 && found < 0) {
            found = (int)i; /* modes already copied into static array by this call */
        }
    }
    if (found < 0) { fprintf(stderr, "no connected connector\n"); return 2; }

    /* pick preferred mode, else first */
    int mi = 0;
    for (__u32 m = 0; m < c.count_modes; m++)
        if (modes[m].type & 8) { mi = m; break; }
    struct drm_mode_modeinfo *mode = &modes[mi];
    printf("picked conn %u mode %s %ux%u@%u clock=%ukHz flags=0x%x type=0x%x\n",
           c.connector_id, mode->name, mode->hdisplay, mode->vdisplay,
           mode->vrefresh, mode->clock, mode->flags, mode->type);
    /* no current encoder (encoder_id==0) is normal when nothing is bound;
     * the kernel assigns an encoder automatically in SETCRTC. */

    /* find a free crtc (no encoder possible_crtcs info; try all) */
    uint32_t crtc_id = 0;
    for (uint32_t i = 0; i < ncrtc; i++) {
        struct drm_mode_crtc tc;
        memset(&tc, 0, sizeof(tc));
        tc.crtc_id = crtc_ids[i];
        if (xioctl(fd, DRM_IOCTL_MODE_GETCRTC, &tc)) continue;
        printf("crtc %u: fb=%u active=%s\n", crtc_ids[i], tc.fb_id, tc.mode_valid ? "yes" : "no");
        if (!tc.mode_valid || tc.fb_id == 0) { crtc_id = crtc_ids[i]; break; }
        if (crtc_id == 0) crtc_id = crtc_ids[i]; /* fallback: first */
    }
    if (!crtc_id) { fprintf(stderr, "no usable crtc\n"); return 4; }
    printf("using crtc %u\n", crtc_id);

    /* dumb buffer + fb */
    struct drm_mode_create_dumb cd;
    memset(&cd, 0, sizeof(cd));
    cd.width = mode->hdisplay; cd.height = mode->vdisplay; cd.bpp = 32;
    if (xioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        fprintf(stderr, "CREATE_DUMB: %s\n", strerror(errno)); return 5;
    }
    printf("dumb: handle=%u pitch=%u size=%llu\n", cd.handle, cd.pitch, (unsigned long long)cd.size);

    struct drm_mode_map_dumb md;
    memset(&md, 0, sizeof(md));
    md.handle = cd.handle;
    if (xioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
        fprintf(stderr, "MAP_DUMB: %s\n", strerror(errno)); return 5;
    }
    uint8_t *map = mmap(0, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
    if (map == MAP_FAILED) { fprintf(stderr, "mmap: %s\n", strerror(errno)); return 5; }

    /* vertical color bars: white red green blue cyan magenta yellow */
    uint32_t colors[7] = {0xFFFFFFFF, 0xFF0000FF, 0xFF00FF00, 0xFFFF0000,
                          0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF};
    for (__u32 y = 0; y < mode->vdisplay; y++) {
        uint32_t *row = (uint32_t *)(map + (uint64_t)y * cd.pitch);
        for (__u32 x = 0; x < mode->hdisplay; x++)
            row[x] = colors[(x * 7) / mode->hdisplay];
    }

    struct drm_mode_fb_cmd fb;
    memset(&fb, 0, sizeof(fb));
    fb.width = mode->hdisplay; fb.height = mode->vdisplay;
    fb.pitch = cd.pitch; fb.bpp = 32; fb.depth = 24; fb.handle = cd.handle;
    if (xioctl(fd, DRM_IOCTL_MODE_ADDFB, &fb)) {
        fprintf(stderr, "ADDFB: %s\n", strerror(errno)); return 6;
    }
    printf("fb=%u\n", fb.fb_id);

    uint32_t conn_id = c.connector_id;
    struct drm_mode_crtc sc;
    memset(&sc, 0, sizeof(sc));
    sc.set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id;
    sc.count_connectors = 1;
    sc.crtc_id = crtc_id;
    sc.fb_id = fb.fb_id;
    sc.x = 0; sc.y = 0;
    sc.mode_valid = 1;
    sc.mode = *mode;
    if (xioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc)) {
        fprintf(stderr, "SETCRTC: %s\n", strerror(errno));
        return 7;
    }
    printf(">>> MODESET OK: crtc=%u fb=%u conn=%u mode=%s — glasses should light now\n",
           crtc_id, fb.fb_id, conn_id, mode->name);

    /* keep alive */
    int secs = argc > 2 ? atoi(argv[2]) : 3600;
    while (secs-- > 0) sleep(1);
    printf("exiting\n");
    return 0;
}
