/* Encoder dispatch: one mlh_enc API over the VAAPI and software backends, plus the pieces
 * they share (output buffer, slice split, error reporting, BGRA to I420). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "enc_internal.h"

/* mlh_last_error, mlh_fail and mlh_log: enc_errors.c, or mlh_common.c when the encoders
 * are linked into the host backend with the capture side. */

int mlh_enc_create(uint32_t kind, const char *device, mlh_enc **out) {
    *out = NULL;
    mlh_clear_error();
    switch (kind) {
    case MLH_ENC_VAAPI: return mlh_enc_vaapi_create(device, out);
    case MLH_ENC_SOFTWARE: return mlh_enc_sw_create(out);
    case MLH_ENC_NVENC:
        /* The Linux NVENC backend is built on the shared NVENC core (platform/nvenc) and
         * joins this dispatch once that lands next to this file. */
        return mlh_fail(MLH_E_NOTFOUND, "NVENC: not built into this host");
    default: return mlh_fail(MLH_E_UNSUPPORTED, "encoder kind %u", kind);
    }
}

void mlh_enc_caps_get(const mlh_enc *e, mlh_enc_caps *out) {
    memset(out, 0, sizeof *out);
    e->ops->caps(e, out);
}

int mlh_enc_configure(mlh_enc *e, const mlh_enc_config *cfg) {
    if (cfg->width == 0 || cfg->height == 0 || cfg->fps == 0 || cfg->bitrate_bps == 0)
        return mlh_fail(MLH_E_UNSUPPORTED, "configure: zero size, rate or bitrate");
    if (cfg->width % 2 || cfg->height % 2) return mlh_fail(MLH_E_UNSUPPORTED, "configure: odd size %ux%u", cfg->width, cfg->height);
    int rc = e->ops->configure(e, cfg);
    if (rc == MLH_OK) {
        e->cfg = *cfg;
        e->configured = 1;
    }
    return rc;
}

int mlh_enc_encode(mlh_enc *e, const mlh_enc_input *in, uint64_t time_us, const mlh_enc_params *p, mlh_enc_output *out) {
    memset(out, 0, sizeof *out);
    if (!e->configured) return mlh_fail(MLH_E_FAIL, "encode before configure");
    e->out_len = 0;
    int rc = e->ops->encode(e, in, time_us, p, out);
    if (rc != MLH_OK) return rc;
    out->data = e->out;
    out->len = e->out_len;
    if (out->len == 0) {
        out->dropped = 1;
        out->has_ltr_token = 0;
        out->ltr_refresh = 0;
        out->keyframe = 0;
    } else {
        mlh_split_slices(e->out, e->out_len, e->cfg.codec, out);
    }
    return MLH_OK;
}

const char *mlh_enc_describe(const mlh_enc *e) { return e->describe; }

void mlh_enc_destroy(mlh_enc *e) {
    if (!e) return;
    uint8_t *buf = e->out;
    e->ops->destroy(e); /* frees the backend struct, which embeds *e */
    free(buf);
}

int mlh_enc_append(mlh_enc *e, const void *data, size_t len) {
    if (e->out_len + len > e->out_cap) {
        size_t cap = e->out_cap ? e->out_cap : 256 * 1024;
        while (cap < e->out_len + len) cap *= 2;
        uint8_t *n = realloc(e->out, cap);
        if (!n) return MLH_E_NOMEM;
        e->out = n;
        e->out_cap = cap;
    }
    memcpy(e->out + e->out_len, data, len);
    e->out_len += len;
    return MLH_OK;
}

void mlh_split_slices(const uint8_t *data, size_t len, uint32_t codec, mlh_enc_output *out) {
    out->num_slices = 0;
    size_t pending = 0; /* where the non-slice NAL units before the next slice started */
    int have_pending = 0;
    for (size_t i = 0; i + 3 < len; i++) {
        if (!(data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)) continue;
        const size_t start = i > 0 && data[i - 1] == 0 ? i - 1 : i;
        int slice;
        if (codec == MLH_CODEC_HEVC) {
            const int t = (data[i + 3] >> 1) & 0x3F;
            slice = t <= 31; /* VCL */
        } else {
            const int t = data[i + 3] & 0x1F;
            slice = t >= 1 && t <= 5;
        }
        if (!have_pending) {
            pending = start;
            have_pending = 1;
        }
        if (slice) {
            if (out->num_slices < MLH_MAX_SLICES) {
                out->slice_offsets[out->num_slices++] = (uint32_t)pending;
            }
            /* else: the rest goes into the last slice entry */
            have_pending = 0;
        }
        i += 3;
    }
    if (out->num_slices == 0) {
        out->slice_offsets[0] = 0;
        out->num_slices = 1;
    }
    out->slice_offsets[0] = 0; /* anything before the first start code goes with slice 0 */
}

/* BT.709 limited range, 8-bit fixed point (x 256), rounded. */
static inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

void mlh_bgra_to_i420(const uint8_t *bgra, uint32_t stride, uint32_t width, uint32_t height, uint8_t *y, uint8_t *u,
                      uint8_t *v) {
    for (uint32_t r = 0; r < height; r++) {
        const uint8_t *s = bgra + (size_t)r * stride;
        uint8_t *d = y + (size_t)r * width;
        for (uint32_t c = 0; c < width; c++) {
            const int b = s[4 * c], g = s[4 * c + 1], R = s[4 * c + 2];
            d[c] = clamp8(((47 * R + 157 * g + 16 * b + 128) >> 8) + 16);
        }
    }
    const uint32_t cw = width / 2, ch = height / 2;
    for (uint32_t r = 0; r < ch; r++) {
        const uint8_t *s0 = bgra + (size_t)(2 * r) * stride, *s1 = s0 + stride;
        for (uint32_t c = 0; c < cw; c++) {
            int b = 0, g = 0, R = 0;
            for (int k = 0; k < 2; k++) {
                b += s0[8 * c + 4 * k] + s1[8 * c + 4 * k];
                g += s0[8 * c + 4 * k + 1] + s1[8 * c + 4 * k + 1];
                R += s0[8 * c + 4 * k + 2] + s1[8 * c + 4 * k + 2];
            }
            /* averages of four, folded into the coefficients (x 1024) */
            u[(size_t)r * cw + c] = clamp8(((-26 * R - 87 * g + 112 * b + 512) >> 10) + 128);
            v[(size_t)r * cw + c] = clamp8(((112 * R - 102 * g - 10 * b + 512) >> 10) + 128);
        }
    }
}
