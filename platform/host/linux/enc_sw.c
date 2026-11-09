/* Software H.264 through libavcodec: libx264 when libavcodec has it, OpenH264 otherwise.
 * The fallback for CI and GPU-less hosts, so the whole Linux host runs in a container.
 *
 * x264 settings are the design's low-latency ones: tune zerolatency (no lookahead, no
 * frame threads, sliced threads), no B-frames, no periodic keyframes or scene cuts, VBV of
 * one frame at the target bitrate, parameter sets on every IDR, `slices` slices. A new
 * bitrate goes through x264_encoder_reconfig (libavcodec does this when bit_rate changes)
 * without a keyframe. No long-term references: recovery is an IDR (caps.ltr = 0). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/opt.h>

#include "enc_internal.h"

typedef struct sw_enc {
    mlh_enc base;
    const AVCodec *codec;
    int x264;
    AVCodecContext *ctx;
    AVFrame *frame;
    AVPacket *pkt;
    int64_t pts;
    uint64_t bitrate;
} sw_enc;

static int av_fail(int code, const char *what, int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof buf);
    return mlh_fail(code, "software encoder: %s: %s", what, buf);
}

static void sw_caps(const mlh_enc *e, mlh_enc_caps *out) {
    (void)e;
    out->h264 = 1;
    out->ltr = 0;
    out->max_slices = 8;
    out->cpu_input = 1;
    out->gpu_input = 1; /* linear dma-bufs are read through a mapping */
    out->nv12_input = 1;
}

static void sw_close(sw_enc *s) {
    avcodec_free_context(&s->ctx);
    av_frame_free(&s->frame);
}

static void set_rate(AVCodecContext *ctx, uint64_t bps, uint32_t fps) {
    ctx->bit_rate = (int64_t)bps;
    ctx->rc_max_rate = (int64_t)bps;
    ctx->rc_buffer_size = (int)(bps / fps); /* one frame */
    ctx->rc_initial_buffer_occupancy = ctx->rc_buffer_size;
}

static int sw_configure(mlh_enc *e, const mlh_enc_config *cfg) {
    sw_enc *s = (sw_enc *)e;
    if (cfg->codec != MLH_CODEC_H264) return mlh_fail(MLH_E_UNSUPPORTED, "software encoder: H.264 only");
    sw_close(s);
    AVCodecContext *ctx = avcodec_alloc_context3(s->codec);
    if (!ctx) return MLH_E_NOMEM;
    s->ctx = ctx;
    ctx->width = (int)cfg->width;
    ctx->height = (int)cfg->height;
    ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    ctx->time_base = (AVRational){1, (int)cfg->fps};
    ctx->framerate = (AVRational){(int)cfg->fps, 1};
    ctx->max_b_frames = 0;
    ctx->gop_size = -1;
    ctx->color_range = AVCOL_RANGE_MPEG;
    ctx->colorspace = AVCOL_SPC_BT709;
    ctx->color_primaries = AVCOL_PRI_BT709;
    ctx->color_trc = AVCOL_TRC_BT709;
    ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    const uint32_t slices = cfg->slices ? cfg->slices : 1;
    ctx->slices = (int)slices;
    s->bitrate = cfg->bitrate_bps;
    if (s->x264) {
        av_opt_set(ctx->priv_data, "preset", "superfast", 0);
        av_opt_set(ctx->priv_data, "tune", "zerolatency", 0);
        av_opt_set_int(ctx->priv_data, "forced-idr", 1, 0);
        char params[256];
        if (cfg->lossless) {
            /* Tests: qp 0 is lossless (High 4:4:4 Predictive), so a round trip is bit exact. */
            av_opt_set(ctx->priv_data, "profile", "high444", 0);
            snprintf(params, sizeof params, "qp=0:keyint=infinite:scenecut=0:repeat-headers=1:bframes=0:slices=%u", slices);
        } else {
            set_rate(ctx, cfg->bitrate_bps, cfg->fps);
            snprintf(params, sizeof params,
                     "keyint=infinite:scenecut=0:repeat-headers=1:bframes=0:rc-lookahead=0:sync-lookahead=0:"
                     "slices=%u:vbv-init=1.0",
                     slices);
        }
        av_opt_set(ctx->priv_data, "x264-params", params, 0);
        ctx->thread_count = 0; /* zerolatency: sliced threads */
    } else {
        set_rate(ctx, cfg->bitrate_bps, cfg->fps);
        av_opt_set(ctx->priv_data, "rc_mode", "bitrate", 0);
        av_opt_set_int(ctx->priv_data, "allow_skip_frames", 0, 0);
        ctx->thread_count = 1;
    }
    int err = avcodec_open2(ctx, s->codec, NULL);
    if (err < 0) {
        sw_close(s);
        return av_fail(MLH_E_UNSUPPORTED, "open", err);
    }
    s->frame = av_frame_alloc();
    if (!s->frame) return MLH_E_NOMEM;
    s->frame->format = AV_PIX_FMT_YUV420P;
    s->frame->width = ctx->width;
    s->frame->height = ctx->height;
    err = av_frame_get_buffer(s->frame, 0);
    if (err < 0) return av_fail(MLH_E_NOMEM, "frame", err);
    s->pts = 0;
    return MLH_OK;
}

/* Fills s->frame from the input: BGRA converted, NV12 de-interleaved. */
static int fill_frame(sw_enc *s, const uint8_t *data, uint32_t stride, uint32_t format, uint32_t w, uint32_t h) {
    int err = av_frame_make_writable(s->frame);
    if (err < 0) return av_fail(MLH_E_NOMEM, "frame", err);
    AVFrame *f = s->frame;
    if (w != (uint32_t)f->width || h != (uint32_t)f->height)
        return mlh_fail(MLH_E_UNSUPPORTED, "software encoder: frame %ux%u, configured %dx%d", w, h, f->width, f->height);
    if (format == MLH_FMT_BGRA) {
        /* mlh_bgra_to_i420 writes tightly packed planes; libavcodec's may be padded. */
        if (f->linesize[0] == (int)w && f->linesize[1] == (int)w / 2 && f->linesize[2] == (int)w / 2) {
            mlh_bgra_to_i420(data, stride, w, h, f->data[0], f->data[1], f->data[2]);
        } else {
            uint8_t *tmp = malloc((size_t)w * h * 3 / 2);
            if (!tmp) return MLH_E_NOMEM;
            uint8_t *ty = tmp, *tu = tmp + (size_t)w * h, *tv = tu + (size_t)w * h / 4;
            mlh_bgra_to_i420(data, stride, w, h, ty, tu, tv);
            for (uint32_t r = 0; r < h; r++) memcpy(f->data[0] + (size_t)r * f->linesize[0], ty + (size_t)r * w, w);
            for (uint32_t r = 0; r < h / 2; r++) {
                memcpy(f->data[1] + (size_t)r * f->linesize[1], tu + (size_t)r * w / 2, w / 2);
                memcpy(f->data[2] + (size_t)r * f->linesize[2], tv + (size_t)r * w / 2, w / 2);
            }
            free(tmp);
        }
    } else if (format == MLH_FMT_NV12) {
        for (uint32_t r = 0; r < h; r++) memcpy(f->data[0] + (size_t)r * f->linesize[0], data + (size_t)r * stride, w);
        const uint8_t *uv = data + (size_t)h * stride;
        for (uint32_t r = 0; r < h / 2; r++)
            for (uint32_t c = 0; c < w / 2; c++) {
                f->data[1][(size_t)r * f->linesize[1] + c] = uv[(size_t)r * stride + 2 * c];
                f->data[2][(size_t)r * f->linesize[2] + c] = uv[(size_t)r * stride + 2 * c + 1];
            }
    } else {
        return mlh_fail(MLH_E_UNSUPPORTED, "software encoder: pixel format %u", format);
    }
    return MLH_OK;
}


static int sw_encode(mlh_enc *e, const mlh_enc_input *in, uint64_t time_us, const mlh_enc_params *p,
                     mlh_enc_output *out) {
    sw_enc *s = (sw_enc *)e;
    (void)time_us;
    int rc;
    if (in->dmabuf) {
        const uint8_t *data;
        uint32_t stride, format;
        void *cookie;
        rc = mlh_dmabuf_map(in->dmabuf, &data, &stride, &format, &cookie);
        if (rc) return rc;
        rc = fill_frame(s, data, stride, format, in->dmabuf->width, in->dmabuf->height);
        mlh_dmabuf_unmap(cookie);
    } else {
        rc = fill_frame(s, in->data, in->stride, in->format, in->width, in->height);
    }
    if (rc) return rc;

    if (p->bitrate_bps && p->bitrate_bps != s->bitrate && !e->cfg.lossless) {
        s->bitrate = p->bitrate_bps;
        set_rate(s->ctx, p->bitrate_bps, e->cfg.fps); /* libx264.c reconfigures, no keyframe */
    }
    /* No long-term references: a refresh is an IDR. */
    const int idr = p->force != MLH_FORCE_NONE;
    s->frame->pict_type = idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    s->frame->pts = s->pts++;
    int err = avcodec_send_frame(s->ctx, s->frame);
    if (err < 0) return av_fail(MLH_E_CODEC, "send", err);
    for (;;) {
        err = avcodec_receive_packet(s->ctx, s->pkt);
        if (err == AVERROR(EAGAIN)) break; /* buffered: a drop (not with zerolatency) */
        if (err < 0) return av_fail(MLH_E_CODEC, "receive", err);
        rc = mlh_enc_append(e, s->pkt->data, (size_t)s->pkt->size);
        if (s->pkt->flags & AV_PKT_FLAG_KEY) out->keyframe = 1;
        av_packet_unref(s->pkt);
        if (rc) return rc;
    }
    return MLH_OK;
}

static void sw_destroy(mlh_enc *e) {
    sw_enc *s = (sw_enc *)e;
    sw_close(s);
    av_packet_free(&s->pkt);
    free(s);
}

static const mlh_enc_ops sw_ops = {sw_caps, sw_configure, sw_encode, sw_destroy};

int mlh_enc_sw_create(mlh_enc **out) {
    const AVCodec *codec = avcodec_find_encoder_by_name("libx264");
    int x264 = codec != NULL;
    if (!codec) codec = avcodec_find_encoder_by_name("libopenh264");
    if (!codec) return mlh_fail(MLH_E_NOTFOUND, "software encoder: libavcodec has neither libx264 nor libopenh264");
    sw_enc *s = calloc(1, sizeof *s);
    if (!s) return MLH_E_NOMEM;
    s->base.ops = &sw_ops;
    s->codec = codec;
    s->x264 = x264;
    s->pkt = av_packet_alloc();
    if (!s->pkt) {
        free(s);
        return MLH_E_NOMEM;
    }
    snprintf(s->base.describe, sizeof s->base.describe, "software %s (libavcodec %s)", codec->name, av_version_info());
    *out = &s->base;
    return MLH_OK;
}
