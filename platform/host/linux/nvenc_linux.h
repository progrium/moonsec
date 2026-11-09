/* NVENC on Linux (enc_nvenc.c), as the Linux host's encoder dispatch sees it. No system
 * or NVIDIA headers here.
 *
 * libnvidia-encode.so.1 and libcuda.so.1 are loaded at run time, so the host starts on
 * machines without an NVIDIA driver. Input is CUDA device memory: a linear dma-buf
 * (XRGB8888/ARGB8888 or NV12) imported with cuImportExternalMemory, or pixels in memory
 * copied into a pitched device buffer. The session, settings and long-term references are
 * platform/nvenc/nvenc_core.c, shared with the Windows host.
 *
 * Compile-only: no NVIDIA hardware is planned for this project, so beyond "not available"
 * none of this has run. Return codes are the Linux host's MLH_* values. */
#ifndef NVENC_LINUX_H
#define NVENC_LINUX_H

#include <stddef.h>
#include <stdint.h>

#define MLH_NV_OK 0
#define MLH_NV_E_FAIL (-1)
#define MLH_NV_E_UNSUPPORTED (-2)
#define MLH_NV_E_NOMEM (-3)
#define MLH_NV_E_NOTFOUND (-4)
#define MLH_NV_E_DEVICE_LOST (-5)
#define MLH_NV_E_CODEC (-6)

#define MLH_NV_CODEC_H264 1
#define MLH_NV_CODEC_HEVC 2

/* The input picture: a dma-buf (fd >= 0) or memory (data). */
typedef struct mlh_nvenc_input {
    int fd;
    uint32_t fourcc;   /* DRM_FORMAT_XRGB8888, ARGB8888 or NV12 */
    uint64_t modifier; /* must be linear (0) or invalid */
    uint32_t offset, pitch;
    const uint8_t *data; /* BGRA (or NV12 with the UV plane at height * stride) */
    uint32_t stride;
    uint32_t nv12;     /* data is NV12 */
    uint32_t width, height;
} mlh_nvenc_input;

typedef struct mlh_nvenc_caps {
    uint32_t h264, hevc, ltr, max_slices;
} mlh_nvenc_caps;

typedef struct mlh_nvenc_config {
    uint32_t codec;
    uint32_t width, height, fps;
    uint64_t bitrate_bps;
    uint32_t slices;
    uint32_t ltr;
} mlh_nvenc_config;

typedef struct mlh_nvenc_params {
    uint32_t force; /* 0 none, 1 long-term refresh, 2 IDR */
    uint64_t bitrate_bps;
    const uint64_t *acked_ltr_tokens;
    uint32_t acked_ltr_count;
} mlh_nvenc_params;

typedef struct mlh_nvenc_output {
    const uint8_t *data; /* Annex B access unit, valid until the next encode */
    size_t len;
    uint32_t keyframe, dropped;
    uint32_t has_ltr_token;
    uint64_t ltr_token;
    uint32_t ltr_refresh;
} mlh_nvenc_output;

typedef struct mlh_nvenc mlh_nvenc;

/* CUDA device `ordinal`. MLH_NV_E_NOTFOUND without the NVIDIA libraries or an
 * NVENC-capable GPU. */
int mlh_nvenc_create(int ordinal, mlh_nvenc **out);
void mlh_nvenc_caps_get(const mlh_nvenc *e, mlh_nvenc_caps *out);
int mlh_nvenc_configure(mlh_nvenc *e, const mlh_nvenc_config *cfg);
int mlh_nvenc_encode(mlh_nvenc *e, const mlh_nvenc_input *in, uint64_t time_us, const mlh_nvenc_params *p,
                     mlh_nvenc_output *out);
/* The last error message on this thread. */
const char *mlh_nvenc_last_error(void);
void mlh_nvenc_destroy(mlh_nvenc *e);

#endif
