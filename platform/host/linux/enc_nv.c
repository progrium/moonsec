/* NVENC behind the Linux host's mlh_enc dispatch (enc.c): an mlh_enc_ops adapter over
 * enc_nvenc.c (nvenc_linux.h), which itself sits on the NVENC core shared with the Windows
 * host (platform/nvenc).
 *
 * Input: a dma-buf is handed to CUDA (cuImportExternalMemory). When CUDA refuses it (a
 * buffer another driver exported, which is the usual case on a hybrid machine), the
 * frame is mapped from the CPU (dmabuf.c) and uploaded instead, and later frames skip the
 * import. Pixels in memory are uploaded.
 *
 * Compile-only like enc_nvenc.c: no NVIDIA hardware is planned for this project, so on
 * this project's machines create returns MLH_E_NOTFOUND and `auto` moves on. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "enc_internal.h"
#include "nvenc_linux.h"

/* The two headers' codes and codec numbers are the same values; the casts below rely on it. */
_Static_assert(MLH_NV_OK == MLH_OK && MLH_NV_E_FAIL == MLH_E_FAIL && MLH_NV_E_UNSUPPORTED == MLH_E_UNSUPPORTED &&
                   MLH_NV_E_NOMEM == MLH_E_NOMEM && MLH_NV_E_NOTFOUND == MLH_E_NOTFOUND &&
                   MLH_NV_E_DEVICE_LOST == MLH_E_DEVICE_LOST && MLH_NV_E_CODEC == MLH_E_CODEC,
               "nvenc_linux.h and mlh_enc.h error codes differ");
_Static_assert(MLH_NV_CODEC_H264 == MLH_CODEC_H264 && MLH_NV_CODEC_HEVC == MLH_CODEC_HEVC, "codec numbers differ");

typedef struct nv_enc {
    mlh_enc base;
    mlh_nvenc *nv;
    int no_import; /* CUDA refused a dma-buf: map and upload from now on */
} nv_enc;

static int nv_err(int rc, const char *what) {
    return mlh_fail(rc, "NVENC: %s: %s", what, mlh_nvenc_last_error());
}

static void nv_caps(const mlh_enc *e, mlh_enc_caps *out) {
    const nv_enc *n = (const nv_enc *)e;
    mlh_nvenc_caps c;
    mlh_nvenc_caps_get(n->nv, &c);
    out->h264 = c.h264;
    out->hevc = c.hevc;
    out->ltr = c.ltr;
    out->max_slices = c.max_slices ? c.max_slices : 1;
    out->gpu_input = 1;
    out->cpu_input = 1;
    out->nv12_input = 1;
}

static int nv_configure(mlh_enc *e, const mlh_enc_config *cfg) {
    nv_enc *n = (nv_enc *)e;
    if (cfg->codec != MLH_CODEC_H264 && cfg->codec != MLH_CODEC_HEVC) return mlh_fail(MLH_E_UNSUPPORTED, "NVENC: codec %u", cfg->codec);
    if (cfg->lossless) return mlh_fail(MLH_E_UNSUPPORTED, "NVENC: lossless is the software encoder's (tests only)");
    const mlh_nvenc_config c = {
        .codec = cfg->codec,
        .width = cfg->width,
        .height = cfg->height,
        .fps = cfg->fps,
        .bitrate_bps = cfg->bitrate_bps,
        .slices = cfg->slices,
        .ltr = cfg->ltr,
    };
    const int rc = mlh_nvenc_configure(n->nv, &c);
    return rc ? nv_err(rc, "configure") : MLH_OK;
}

/* The dma-buf as one CUDA import: single plane, or NV12 with both planes contiguous in
 * one buffer (what NVENC's NV12 input expects). */
static int importable(const mlh_dmabuf *d) {
    if (d->num_planes == 1) return 1;
    return d->num_planes == 2 && d->fd[1] == d->fd[0] && d->pitch[1] == d->pitch[0] &&
           d->offset[1] == d->offset[0] + d->pitch[0] * d->height;
}

/* Encodes one picture and appends the access unit. A refused dma-buf import comes back
 * as MLH_E_UNSUPPORTED (nothing else here returns it once configured). */
static int run(nv_enc *n, const mlh_nvenc_input *in, uint64_t time_us, const mlh_nvenc_params *p, mlh_enc_output *out) {
    mlh_nvenc_output o;
    const int rc = mlh_nvenc_encode(n->nv, in, time_us, p, &o);
    if (rc) return nv_err(rc, "encode");
    if (o.dropped || o.len == 0) return MLH_OK; /* nothing appended: enc.c reports a drop */
    const int arc = mlh_enc_append(&n->base, o.data, o.len);
    if (arc) return mlh_fail(arc, "NVENC: output buffer");
    out->keyframe = o.keyframe;
    out->has_ltr_token = o.has_ltr_token;
    out->ltr_token = o.ltr_token;
    out->ltr_refresh = o.ltr_refresh;
    return MLH_OK;
}

static int nv_encode(mlh_enc *e, const mlh_enc_input *in, uint64_t time_us, const mlh_enc_params *p, mlh_enc_output *out) {
    nv_enc *n = (nv_enc *)e;
    const mlh_nvenc_params np = {
        .force = p->force,
        .bitrate_bps = p->bitrate_bps,
        .acked_ltr_tokens = p->acked_ltr_tokens,
        .acked_ltr_count = p->acked_ltr_count,
    };
    if (in->dmabuf && !n->no_import && importable(in->dmabuf) && in->dmabuf->width == e->cfg.width &&
        in->dmabuf->height == e->cfg.height) {
        const mlh_dmabuf *d = in->dmabuf;
        const mlh_nvenc_input ni = {
            .fd = d->fd[0],
            .fourcc = d->fourcc,
            .modifier = d->modifier,
            .offset = d->offset[0],
            .pitch = d->pitch[0],
            .width = d->width,
            .height = d->height,
        };
        const int rc = run(n, &ni, time_us, &np, out);
        if (rc != MLH_E_UNSUPPORTED) return rc;
        mlh_log("NVENC: copying dma-buf frames through memory from now on");
        n->no_import = 1;
    }
    mlh_nvenc_input ni = {.fd = -1};
    void *cookie = NULL;
    if (in->dmabuf) {
        uint32_t format;
        const int rc = mlh_dmabuf_map(in->dmabuf, &ni.data, &ni.stride, &format, &cookie);
        if (rc) return rc;
        ni.nv12 = format == MLH_FMT_NV12;
        ni.width = in->dmabuf->width;
        ni.height = in->dmabuf->height;
    } else {
        if (in->format != MLH_FMT_BGRA && in->format != MLH_FMT_NV12) return mlh_fail(MLH_E_UNSUPPORTED, "NVENC: input format %u", in->format);
        ni.data = in->data;
        ni.stride = in->stride;
        ni.nv12 = in->format == MLH_FMT_NV12;
        ni.width = in->width;
        ni.height = in->height;
    }
    const int rc = run(n, &ni, time_us, &np, out);
    if (cookie) mlh_dmabuf_unmap(cookie);
    return rc;
}

static void nv_destroy(mlh_enc *e) {
    nv_enc *n = (nv_enc *)e;
    mlh_nvenc_destroy(n->nv);
    free(n);
}

static const mlh_enc_ops nv_ops = {nv_caps, nv_configure, nv_encode, nv_destroy};

int mlh_enc_nvenc_create(const char *device, mlh_enc **out) {
    /* `device` is the DRM render node for VAAPI; NVENC takes a CUDA ordinal, so a plain
     * number picks one and anything else (or nothing) means device 0. */
    int ordinal = 0;
    if (device) {
        char *end;
        const long v = strtol(device, &end, 10);
        if (*device && !*end && v >= 0 && v < 64) ordinal = (int)v;
    }
    mlh_nvenc *nv = NULL;
    const int rc = mlh_nvenc_create(ordinal, &nv);
    if (rc) return nv_err(rc, "open");
    nv_enc *n = calloc(1, sizeof *n);
    if (!n) {
        mlh_nvenc_destroy(nv);
        return MLH_E_NOMEM;
    }
    n->base.ops = &nv_ops;
    n->nv = nv;
    mlh_nvenc_caps c;
    mlh_nvenc_caps_get(nv, &c);
    snprintf(n->base.describe, sizeof n->base.describe, "nvenc (CUDA device %d%s%s%s)", ordinal, c.h264 ? ", H.264" : "",
             c.hevc ? ", HEVC" : "", c.ltr ? ", long-term references" : "");
    *out = &n->base;
    return MLH_OK;
}
