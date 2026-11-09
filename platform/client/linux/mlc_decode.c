/* libavcodec decoder: VAAPI when a device opens and takes the codec, software otherwise
 * (see mlc.h). Low-delay settings: no frame threads (they add a frame of delay each),
 * slice threads only, AV_CODEC_FLAG_LOW_DELAY, so a picture comes out of the call that
 * fed its access unit. */
#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>

#include "mlc_internal.h"

struct mlc_decoder {
    AVCodecContext *ctx;
    AVBufferRef *hw;
    AVPacket *pkt;
    AVFrame *frame;
    /* A VAAPI surface the presenter cannot import (P010, 4:4:4), copied to memory. */
    AVFrame *sw;
    int hardware;
    int held;
};

static enum AVCodecID codec_id(uint32_t c) {
    switch (c) {
    case MLC_CODEC_H264: return AV_CODEC_ID_H264;
    case MLC_CODEC_HEVC: return AV_CODEC_ID_HEVC;
    case MLC_CODEC_AV1: return AV_CODEC_ID_AV1;
    default: return AV_CODEC_ID_NONE;
    }
}

static int av_fail(int code, const char *what, int err) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, buf, sizeof buf);
    return mlc_fail(code, "%s: %s", what, buf);
}

int mlc_decoder_supported(uint32_t codec) {
    enum AVCodecID id = codec_id(codec);
    return id != AV_CODEC_ID_NONE && avcodec_find_decoder(id) != NULL;
}

/* What libavcodec's software decoders take (VAAPI falls back to them per stream, see
 * pick_vaapi) and the presenter draws: 4:4:4 as three planes, 10-bit reduced to 8 for
 * GLES, PQ tone-mapped. H.264 stops at 8-bit 4:4:4: High 10 has no HDR10 signalling
 * anyone encodes and no encoder of ours makes it. */
uint32_t mlc_decoder_formats(uint32_t codec) {
    if (!mlc_decoder_supported(codec)) return 0;
    switch (codec) {
    case MLC_CODEC_H264: return MLC_FMT_420_8 | MLC_FMT_444_8;
    case MLC_CODEC_HEVC: return MLC_FMT_420_8 | MLC_FMT_420_10 | MLC_FMT_444_8 | MLC_FMT_444_10 | MLC_FMT_HDR10;
    case MLC_CODEC_AV1: {
        /* libavcodec's own "av1" decodes through hwaccels only; dav1d and libaom are
         * software and take every profile we send (Main 8/10, High 4:4:4). */
        const AVCodec *c = avcodec_find_decoder(AV_CODEC_ID_AV1);
        if (strcmp(c->name, "libdav1d") == 0 || strcmp(c->name, "libaom-av1") == 0)
            return MLC_FMT_420_8 | MLC_FMT_420_10 | MLC_FMT_444_8 | MLC_FMT_444_10 | MLC_FMT_HDR10;
        return MLC_FMT_420_8;
    }
    default: return 0;
    }
}

static enum AVPixelFormat pick_vaapi(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VAAPI) return *p;
    /* The hardware can't take this stream: let libavcodec decode it in software. */
    mlc_log("VAAPI cannot decode this stream; software decode");
    (void)ctx;
    return fmts[0] == AV_PIX_FMT_VAAPI ? fmts[1] : fmts[0];
}

/* Whether the VAAPI device has a decode entrypoint for `id` (any profile of it). */
static int vaapi_has_codec(AVBufferRef *hw, enum AVCodecID id) {
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec) return 0;
    for (int i = 0;; i++) {
        const AVCodecHWConfig *c = avcodec_get_hw_config(codec, i);
        if (!c) return 0;
        if (c->device_type == AV_HWDEVICE_TYPE_VAAPI && (c->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) break;
    }
    /* libavcodec checks the profile against the driver when the first frame comes; a
     * device with no decode entrypoint at all is caught here. */
    AVHWDeviceContext *dev = (AVHWDeviceContext *)hw->data;
    AVVAAPIDeviceContext *va = dev->hwctx;
    int n = vaMaxNumProfiles(va->display);
    VAProfile *profiles = calloc((size_t)(n > 0 ? n : 1), sizeof *profiles);
    if (!profiles) return 0;
    int found = 0;
    if (vaQueryConfigProfiles(va->display, profiles, &n) == VA_STATUS_SUCCESS) {
        for (int i = 0; i < n && !found; i++) {
            VAProfile p = profiles[i];
            /* Any profile of the codec: a stream in a profile the device lacks (Main10,
             * 4:4:4) falls back to software in pick_vaapi when its first frame comes. */
            int match = (id == AV_CODEC_ID_H264 && (p == VAProfileH264ConstrainedBaseline || p == VAProfileH264Main || p == VAProfileH264High)) ||
                        (id == AV_CODEC_ID_HEVC && (p == VAProfileHEVCMain || p == VAProfileHEVCMain10 || p == VAProfileHEVCMain444 || p == VAProfileHEVCMain444_10)) ||
                        (id == AV_CODEC_ID_AV1 && (p == VAProfileAV1Profile0 || p == VAProfileAV1Profile1));
            if (!match) continue;
            int ne = vaMaxNumEntrypoints(va->display);
            VAEntrypoint *eps = calloc((size_t)(ne > 0 ? ne : 1), sizeof *eps);
            if (eps && vaQueryConfigEntrypoints(va->display, p, eps, &ne) == VA_STATUS_SUCCESS)
                for (int k = 0; k < ne; k++)
                    if (eps[k] == VAEntrypointVLD) found = 1;
            free(eps);
        }
    }
    free(profiles);
    return found;
}

static int open_ctx(mlc_decoder *d, const AVCodec *codec, AVBufferRef *hw) {
    d->ctx = avcodec_alloc_context3(codec);
    if (!d->ctx) return MLC_E_NOMEM;
    d->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    d->ctx->flags2 |= AV_CODEC_FLAG2_FAST;
    if (hw) {
        d->ctx->hw_device_ctx = av_buffer_ref(hw);
        d->ctx->get_format = pick_vaapi;
        d->ctx->thread_count = 1;
    } else {
        /* Slice threads only: frame threading delays each picture by a frame per thread. */
        d->ctx->thread_type = FF_THREAD_SLICE;
        d->ctx->thread_count = 0;
    }
    int err = avcodec_open2(d->ctx, codec, NULL);
    if (err < 0) {
        avcodec_free_context(&d->ctx);
        return av_fail(MLC_E_FAIL, "avcodec_open2", err);
    }
    return MLC_OK;
}

int mlc_decoder_create(uint32_t codec_c, int hardware, const char *device, mlc_decoder **out) {
    *out = NULL;
    enum AVCodecID id = codec_id(codec_c);
    const AVCodec *codec = id == AV_CODEC_ID_NONE ? NULL : avcodec_find_decoder(id);
    if (!codec) return mlc_fail(MLC_E_UNSUPPORTED, "libavcodec has no decoder for codec %u", codec_c);
    mlc_decoder *d = calloc(1, sizeof *d);
    if (!d) return MLC_E_NOMEM;
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    d->sw = av_frame_alloc();
    if (!d->pkt || !d->frame || !d->sw) {
        mlc_decoder_destroy(d);
        return MLC_E_NOMEM;
    }
    if (hardware) {
        int err = av_hwdevice_ctx_create(&d->hw, AV_HWDEVICE_TYPE_VAAPI, device, NULL, 0);
        if (err < 0) {
            av_fail(MLC_E_NODEVICE, "VAAPI device", err);
            mlc_log("no VAAPI device; software decode");
        } else if (!vaapi_has_codec(d->hw, id)) {
            mlc_log("VAAPI device has no %s decoder; software decode", codec->name);
            av_buffer_unref(&d->hw);
        }
    }
    int rc = open_ctx(d, codec, d->hw);
    if (rc != MLC_OK && d->hw) {
        mlc_log("VAAPI decoder failed to open; software decode");
        av_buffer_unref(&d->hw);
        rc = open_ctx(d, codec, NULL);
    }
    if (rc != MLC_OK) {
        mlc_decoder_destroy(d);
        return rc;
    }
    d->hardware = d->hw != NULL;
    *out = d;
    return MLC_OK;
}

void mlc_decoder_destroy(mlc_decoder *d) {
    if (!d) return;
    if (d->ctx) avcodec_free_context(&d->ctx);
    if (d->hw) av_buffer_unref(&d->hw);
    av_packet_free(&d->pkt);
    av_frame_free(&d->frame);
    av_frame_free(&d->sw);
    free(d);
}

int mlc_decoder_is_hardware(const mlc_decoder *d) { return d->hardware; }

/* Colour description and HDR metadata from the frame (the bitstream's VUI / sequence
 * header, SEI and metadata OBUs, which libavcodec turns into side data). */
static void fill_color(const AVFrame *f, mlc_frame *out) {
    switch (f->colorspace) {
    case AVCOL_SPC_BT709: out->bt709 = 1; break;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL: out->bt2020 = 1; break;
    case AVCOL_SPC_UNSPECIFIED: out->bt709 = f->height >= 720; break;
    default: out->bt709 = 0; break;
    }
    if (f->color_primaries == AVCOL_PRI_BT2020 && f->colorspace == AVCOL_SPC_UNSPECIFIED) out->bt2020 = 1;
    out->full_range = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P || f->format == AV_PIX_FMT_YUVJ444P;
    out->transfer = f->color_trc == AVCOL_TRC_SMPTE2084      ? MLC_TRANSFER_PQ
                    : f->color_trc == AVCOL_TRC_ARIB_STD_B67 ? MLC_TRANSFER_HLG
                                                             : MLC_TRANSFER_SDR;
    const AVFrameSideData *sd = av_frame_get_side_data(f, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    if (sd) {
        const AVMasteringDisplayMetadata *m = (const AVMasteringDisplayMetadata *)sd->data;
        if (m->has_luminance) {
            out->has_mastering = 1;
            out->max_luminance = (uint32_t)(av_q2d(m->max_luminance) * 10000.0 + 0.5);
            out->min_luminance = (uint32_t)(av_q2d(m->min_luminance) * 10000.0 + 0.5);
        }
    }
    sd = av_frame_get_side_data(f, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    if (sd) {
        const AVContentLightMetadata *l = (const AVContentLightMetadata *)sd->data;
        out->max_cll = (uint16_t)l->MaxCLL;
        out->max_fall = (uint16_t)l->MaxFALL;
    }
}

static int fill(mlc_decoder *d, const AVFrame *f, mlc_frame *out) {
    memset(out, 0, sizeof *out);
    out->width = (uint32_t)f->width;
    out->height = (uint32_t)f->height;
    out->pts = f->pts;
    out->priv = (void *)f;
    out->bit_depth = 8;
    fill_color(f, out);
    if (f->format == AV_PIX_FMT_VAAPI) {
        AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
        AVVAAPIDeviceContext *va = fc->device_ctx->hwctx;
        if (fc->sw_format == AV_PIX_FMT_NV12) {
            out->kind = MLC_FRAME_VAAPI;
            out->va_display = va->display;
            out->va_surface = (uint32_t)(uintptr_t)f->data[3];
            return MLC_OK;
        }
        /* P010 (Main10), 4:4:4 surfaces: the presenter's dma-buf import takes NV12 only,
         * so copy the picture to memory. A copy per frame at 10-bit; zero-copy P010 needs
         * R16/GR1616 dma-buf imports (untested without a GPU). */
        av_frame_unref(d->sw);
        int err = av_hwframe_transfer_data(d->sw, f, 0);
        if (err < 0) return av_fail(MLC_E_UNSUPPORTED, "VAAPI surface download", err);
        d->sw->pts = f->pts;
        f = d->sw;
    }
    switch (f->format) {
    case AV_PIX_FMT_NV12:
        out->kind = MLC_FRAME_NV12;
        break;
    case AV_PIX_FMT_P010:
        out->kind = MLC_FRAME_P010;
        out->bit_depth = 10;
        break;
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_YUVJ420P:
        out->kind = MLC_FRAME_I420;
        break;
    case AV_PIX_FMT_YUV420P10:
        out->kind = MLC_FRAME_I420;
        out->bit_depth = 10;
        break;
    case AV_PIX_FMT_YUV444P:
    case AV_PIX_FMT_YUVJ444P:
        out->kind = MLC_FRAME_I444;
        break;
    case AV_PIX_FMT_YUV444P10:
        out->kind = MLC_FRAME_I444;
        out->bit_depth = 10;
        break;
    default:
        return mlc_fail(MLC_E_UNSUPPORTED, "decoded format %s (want 4:2:0 or 4:4:4, 8 or 10-bit)", av_get_pix_fmt_name(f->format));
    }
    for (int i = 0; i < 3; i++) {
        out->planes[i] = f->data[i];
        out->strides[i] = f->linesize[i] > 0 ? (uint32_t)f->linesize[i] : 0;
    }
    return MLC_OK;
}

int mlc_decoder_decode(mlc_decoder *d, const uint8_t *data, size_t len, int64_t pts, mlc_frame *out, int *got) {
    *got = 0;
    if (d->held) return mlc_fail(MLC_E_FAIL, "decode before the previous frame was released");
    /* The packet references the caller's buffer for the duration of the call; libavcodec
     * copies what it keeps (no AV_INPUT_BUFFER_PADDING_SIZE guarantee otherwise). */
    uint8_t *copy = av_malloc(len + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!copy) return MLC_E_NOMEM;
    memcpy(copy, data, len);
    memset(copy + len, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    int err = av_packet_from_data(d->pkt, copy, (int)len);
    if (err < 0) {
        av_free(copy);
        return av_fail(MLC_E_NOMEM, "av_packet_from_data", err);
    }
    d->pkt->pts = pts;
    err = avcodec_send_packet(d->ctx, d->pkt);
    av_packet_unref(d->pkt);
    if (err < 0 && err != AVERROR(EAGAIN)) return av_fail(MLC_E_CODEC, "avcodec_send_packet", err);
    /* Take the newest picture that is ready; drop any older ones. */
    int have = 0;
    for (;;) {
        AVFrame *f = av_frame_alloc();
        if (!f) return MLC_E_NOMEM;
        err = avcodec_receive_frame(d->ctx, f);
        if (err < 0) {
            av_frame_free(&f);
            break;
        }
        if (f->decode_error_flags || (f->flags & AV_FRAME_FLAG_CORRUPT)) {
            av_frame_free(&f);
            if (have) av_frame_unref(d->frame);
            return mlc_fail(MLC_E_CODEC, "decoder flagged the picture corrupt");
        }
        if (have) av_frame_unref(d->frame);
        av_frame_move_ref(d->frame, f);
        av_frame_free(&f);
        have = 1;
    }
    if (err != AVERROR(EAGAIN) && err != AVERROR_EOF && err < 0) {
        if (have) av_frame_unref(d->frame);
        return av_fail(MLC_E_CODEC, "avcodec_receive_frame", err);
    }
    if (!have) return MLC_OK;
    int rc = fill(d, d->frame, out);
    if (rc != MLC_OK) {
        av_frame_unref(d->frame);
        av_frame_unref(d->sw);
        return rc;
    }
    d->held = 1;
    *got = 1;
    return MLC_OK;
}

void mlc_decoder_release_frame(mlc_decoder *d, mlc_frame *f) {
    if (!d || !d->held) return;
    av_frame_unref(d->frame);
    av_frame_unref(d->sw);
    d->held = 0;
    if (f) f->kind = MLC_FRAME_NONE;
}

int mlc_decoder_flush(mlc_decoder *d) {
    mlc_decoder_release_frame(d, NULL);
    avcodec_flush_buffers(d->ctx);
    return MLC_OK;
}
