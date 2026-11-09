/*
 * The Linux host encoders' C side, as Zig sees it (platform/host/linux/encoder.zig). No
 * system headers here: libva, libavcodec and the NVENC/CUDA declarations stay in the .c
 * files, and translate-c only ever reads this file.
 *
 *   enc.c           dispatch, the output buffer, splitting the access unit into slices
 *   enc_vaapi.c     VAAPI through libva loaded at run time (dlopen): low-latency CBR with a
 *                   one-frame HRD buffer, our own packed H.264/HEVC headers so long-term
 *                   references and per-frame reference choice are ours (h26x.c)
 *   enc_sw.c        libavcodec's libx264 (or OpenH264): the software fallback for CI and
 *                   GPU-less hosts; IDR-only recovery
 *   testenc.c       PCM-and-skip H.264/HEVC test encoders on the same headers and planner as
 *                   enc_vaapi.c, so the tests check them through a real decoder
 *
 * Every function returns 0 on success and a negative MLH_E_* code otherwise; the C side
 * prints the detail (mlh_last_error has the last message).
 */
#ifndef MLH_ENC_H
#define MLH_ENC_H

#include <stddef.h>
#include <stdint.h>

#define MLH_OK 0
#define MLH_E_FAIL (-1)
#define MLH_E_UNSUPPORTED (-2)
#define MLH_E_NOMEM (-3)
/* The backend is not on this machine (no library, no device, no encode entrypoint). */
#define MLH_E_NOTFOUND (-4)
#define MLH_E_DEVICE_LOST (-5)
#define MLH_E_CODEC (-6)

/* The last error message on this thread (empty when none). */
const char *mlh_last_error(void);

/* ------------------------------------------------------------------------ */
/* Frames the encoders take. */

/* A dma-buf picture (what Linux capture hands over in `Image.gpu`): the PipeWire buffer's
 * planes, fds owned by the capture side and valid until the frame's release. */
typedef struct mlh_dmabuf {
    uint32_t width, height;
    uint32_t fourcc;   /* DRM_FORMAT_*: XRGB8888/ARGB8888 (BGRA in memory), NV12 */
    uint64_t modifier; /* DRM_FORMAT_MOD_*; DRM_FORMAT_MOD_INVALID when the producer gave none */
    uint32_t num_planes;
    int fd[4];
    uint32_t offset[4];
    uint32_t pitch[4];
} mlh_dmabuf;

#define MLH_FMT_BGRA 1
#define MLH_FMT_NV12 2

typedef struct mlh_enc_input {
    /* One of: a dma-buf, or pixels in memory (BGRA, or NV12 with the UV plane at
     * height * stride). */
    const mlh_dmabuf *dmabuf;
    const uint8_t *data;
    uint32_t stride;
    uint32_t format;
    uint32_t width, height;
} mlh_enc_input;

/* ------------------------------------------------------------------------ */
/* Encoders */

#define MLH_ENC_VAAPI 1
#define MLH_ENC_NVENC 2
#define MLH_ENC_SOFTWARE 3

#define MLH_CODEC_H264 1
#define MLH_CODEC_HEVC 2
#define MLH_CODEC_AV1 3

#define MLH_FORCE_NONE 0
#define MLH_FORCE_LTR_REFRESH 1
#define MLH_FORCE_IDR 2

typedef struct mlh_enc_caps {
    uint32_t h264, hevc, av1;
    uint32_t ltr;
    uint32_t max_slices;
    uint32_t gpu_input, cpu_input;
    uint32_t nv12_input;
} mlh_enc_caps;

typedef struct mlh_enc_config {
    uint32_t codec;
    uint32_t width, height, fps;
    uint64_t bitrate_bps;
    uint32_t slices;
    uint32_t ltr;
    /* Tests only: software backend encodes losslessly (x264 qp 0). */
    uint32_t lossless;
} mlh_enc_config;

typedef struct mlh_enc_params {
    uint32_t force;
    uint64_t bitrate_bps; /* 0 = unchanged */
    const uint64_t *acked_ltr_tokens;
    uint32_t acked_ltr_count;
} mlh_enc_params;

#define MLH_MAX_SLICES 64

typedef struct mlh_enc_output {
    /* Annex B access unit, owned by the encoder, valid until the next encode. */
    const uint8_t *data;
    size_t len;
    /* Byte offsets where each slice starts (parameter sets and SEI go with the slice
     * that follows them); slice i ends where i + 1 starts, the last at len. */
    uint32_t slice_offsets[MLH_MAX_SLICES];
    uint32_t num_slices;
    uint32_t keyframe;
    uint32_t dropped;
    uint32_t has_ltr_token;
    uint64_t ltr_token;
    uint32_t ltr_refresh;
} mlh_enc_output;

typedef struct mlh_enc mlh_enc;

/* `device`: DRM render node for VAAPI (NULL: the first one with an encode entrypoint).
 * MLH_E_NOTFOUND when the backend is not on this machine. */
int mlh_enc_create(uint32_t kind, const char *device, mlh_enc **out);
void mlh_enc_caps_get(const mlh_enc *e, mlh_enc_caps *out);
int mlh_enc_configure(mlh_enc *e, const mlh_enc_config *cfg);
/* Blocks until the access unit is out. `time_us` is the capture time. */
int mlh_enc_encode(mlh_enc *e, const mlh_enc_input *in, uint64_t time_us, const mlh_enc_params *p,
                   mlh_enc_output *out);
/* What the backend is ("VAAPI Intel iHD driver ... (renderD128, H.264 LP)", "libx264"). */
const char *mlh_enc_describe(const mlh_enc *e);
void mlh_enc_destroy(mlh_enc *e);

/* BGRA to I420 (BT.709, limited range), the software encoder's conversion; also used by
 * the tests to compare a lossless round trip bit for bit. Even width and height. */
void mlh_bgra_to_i420(const uint8_t *bgra, uint32_t stride, uint32_t width, uint32_t height, uint8_t *y,
                      uint8_t *u, uint8_t *v);

/* ------------------------------------------------------------------------ */
/* Test encoders (testenc.c): PCM and skip pictures through the h26x.c headers and
 * reference planner the VAAPI encoder uses, so a real decoder checks long-term marking,
 * reference choice and recovery after loss without a GPU. Width and height multiples
 * of 16; planes are I420 with strides width and width / 2. */

typedef struct mlh_testenc mlh_testenc;

int mlh_testenc_create(uint32_t codec, uint32_t width, uint32_t height, int ltr, mlh_testenc **out);
/* On an IDR every 16x16 block is sent as PCM; otherwise blocks with `changed[i]` set are
 * PCM and the rest are skipped (copied from the reference the planner chose). */
int mlh_testenc_encode(mlh_testenc *t, const uint8_t *y, const uint8_t *u, const uint8_t *v, const uint8_t *changed,
                       const mlh_enc_params *p, mlh_enc_output *out);
void mlh_testenc_destroy(mlh_testenc *t);

#endif
