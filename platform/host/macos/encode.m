// Video encode with VideoToolbox, and a small decoder for the tests.
//
// Default session (S7b, S8): EnableLowLatencyRateControl, EnableLTR, RealTime on,
// ExpectedFrameRate 1000, no frame reordering, no periodic keyframes. The low-latency
// path is the only one with long-term references; ExpectedFrameRate 1000 is what brings
// its encode time down to ~8 ms p99 at 1080p60. The regular encoder (RealTime off,
// IDR recovery only) is the fallback when the low-latency one cannot be created.
//
// `mh_enc_encode` is synchronous: it submits the frame and waits on a semaphore that the
// output callback signals. The low-latency encoder may drop a frame rather than
// overshoot (S7b finding 6); that comes back as `dropped`.
//
// Output is Annex B. VideoToolbox emits length-prefixed NAL units (AVCC/HVCC) with the
// parameter sets in the format description, so keyframes get them prepended.
//
// Reconfigure (the rate ladder in core/rate): `mh_enc_configure` keeps the session when
// only bitrate or frame rate change (AverageBitRate is set live, no keyframe), and makes
// a new one for a new codec, size or LTR setting. Frames that arrive at another size than
// the session's (capture not yet resized) are scaled with a VTPixelTransferSession.
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>
#include "mh_internal.h"

struct mh_enc {
    mh_enc_options opts;
    mh_enc_config cfg;
    VTCompressionSessionRef session;
    VTPixelTransferSessionRef transfer;
    void *done; // dispatch_semaphore_t, as a CF reference (plain C struct)
    // Frame in flight: the callback ignores output for any other (a frame that timed out).
    _Atomic uintptr_t frame_no;
    // Filled by the callback for the frame in flight.
    OSStatus status;
    uint32_t dropped, keyframe, has_token;
    int64_t token;
    uint8_t *buf;
    size_t len, cap;
    int64_t last_pts_us;
    uint64_t current_bps;
    mh_enc_info info;
};

static int reserve(struct mh_enc *e, size_t more) {
    if (e->len + more <= e->cap) return 1;
    size_t cap = e->cap ? e->cap : 1 << 16;
    while (cap < e->len + more) cap *= 2;
    uint8_t *b = realloc(e->buf, cap);
    if (!b) return 0;
    e->buf = b;
    e->cap = cap;
    return 1;
}

static int append_nal(struct mh_enc *e, const uint8_t *nal, size_t n) {
    if (!reserve(e, n + 4)) return 0;
    static const uint8_t sc[4] = {0, 0, 0, 1};
    memcpy(e->buf + e->len, sc, 4);
    memcpy(e->buf + e->len + 4, nal, n);
    e->len += n + 4;
    return 1;
}

static OSStatus append_parameter_sets(struct mh_enc *e, CMFormatDescriptionRef fd) {
    int hevc = CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC;
    size_t count = 0;
    OSStatus st = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, &count, NULL)
                       : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &count, NULL);
    if (st != noErr) return st;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *ps = NULL;
        size_t n = 0;
        st = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &ps, &n, NULL, NULL)
                  : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &ps, &n, NULL, NULL);
        if (st != noErr) return st;
        if (!append_nal(e, ps, n)) return kCMBlockBufferMemoryAllocationErr;
    }
    return noErr;
}

static OSStatus to_annex_b(struct mh_enc *e, CMSampleBufferRef sb) {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    int hevc = CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC;
    int header_len = 4;
    OSStatus st = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, NULL, &header_len)
                       : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, NULL, &header_len);
    if (st != noErr) return st;
    if (e->keyframe) {
        st = append_parameter_sets(e, fd);
        if (st != noErr) return st;
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t total = CMBlockBufferGetDataLength(bb);
    char *data = NULL;
    size_t contiguous = 0;
    uint8_t *copy = NULL;
    st = CMBlockBufferGetDataPointer(bb, 0, &contiguous, NULL, &data);
    if (st != noErr || contiguous < total) {
        copy = malloc(total);
        if (!copy) return kCMBlockBufferMemoryAllocationErr;
        st = CMBlockBufferCopyDataBytes(bb, 0, total, copy);
        if (st != noErr) {
            free(copy);
            return st;
        }
        data = (char *)copy;
    }
    const uint8_t *p = (const uint8_t *)data;
    size_t off = 0;
    while (off + (size_t)header_len <= total) {
        size_t n = 0;
        for (int i = 0; i < header_len; i++) n = (n << 8) | p[off + i];
        off += header_len;
        if (n > total - off) break;
        if (!append_nal(e, p + off, n)) {
            st = kCMBlockBufferMemoryAllocationErr;
            break;
        }
        off += n;
    }
    free(copy);
    return st;
}

static void on_output(void *ref, void *frame_ref, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    struct mh_enc *e = ref;
    if ((uintptr_t)frame_ref != e->frame_no) return;
    e->status = status;
    if (status == noErr && sb && CMSampleBufferDataIsReady(sb)) {
        CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
        CFDictionaryRef d = (att && CFArrayGetCount(att) > 0) ? CFArrayGetValueAtIndex(att, 0) : NULL;
        CFBooleanRef not_sync = d ? CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync) : NULL;
        e->keyframe = !(not_sync && CFBooleanGetValue(not_sync));
        CFNumberRef tok = d ? CFDictionaryGetValue(d, kVTSampleAttachmentKey_RequireLTRAcknowledgementToken) : NULL;
        if (tok) {
            e->has_token = 1;
            CFNumberGetValue(tok, kCFNumberSInt64Type, &e->token);
        }
        e->status = to_annex_b(e, sb);
    } else if (status == noErr) {
        e->dropped = 1; // no sample buffer: dropped by rate control (kVTEncodeInfo_FrameDropped)
    }
    (void)flags;
    dispatch_semaphore_signal((__bridge dispatch_semaphore_t)e->done);
}

static int set_prop(VTCompressionSessionRef s, CFStringRef key, CFTypeRef value, int required, const char *name) {
    OSStatus st = VTSessionSetProperty(s, key, value);
    if (st != noErr && required) return mh_fail(MH_ERR_UNSUPPORTED, "VTSessionSetProperty %s: %d", name, (int)st);
    return MH_OK;
}

#define SETP(key, val, req)                                                                              \
    do {                                                                                                 \
        int _rc = set_prop(s, key, (__bridge CFTypeRef)(val), req, #key);                                \
        if (_rc != MH_OK) {                                                                              \
            VTCompressionSessionInvalidate(s);                                                           \
            CFRelease(s);                                                                                \
            return _rc;                                                                                  \
        }                                                                                                \
    } while (0)

static void read_info(VTCompressionSessionRef s, mh_enc_info *info) {
    CFStringRef eid = NULL;
    info->encoder_id[0] = 0;
    if (VTSessionCopyProperty(s, kVTCompressionPropertyKey_EncoderID, NULL, &eid) == noErr && eid) {
        CFStringGetCString(eid, info->encoder_id, sizeof info->encoder_id, kCFStringEncodingUTF8);
        CFRelease(eid);
    }
    CFBooleanRef hw = NULL;
    info->hardware = 0;
    if (VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hw) == noErr && hw) {
        info->hardware = CFBooleanGetValue(hw) ? 1 : 0;
        CFRelease(hw);
    }
}

// Creates and sets up a session. `e` may be NULL for a probe (no callback target needed).
static int make_session(const mh_enc_options *o, const mh_enc_config *cfg, struct mh_enc *e, VTCompressionSessionRef *out,
                        mh_enc_info *info) {
    @autoreleasepool {
        CMVideoCodecType codec;
        switch (cfg->codec) {
        case MH_CODEC_H264: codec = kCMVideoCodecType_H264; break;
        case MH_CODEC_HEVC: codec = kCMVideoCodecType_HEVC; break;
        default: return mh_fail(MH_ERR_UNSUPPORTED, "codec %u", cfg->codec);
        }
        const int ll = o->mode != MH_ENC_REGULAR;
        NSMutableDictionary *spec = [NSMutableDictionary dictionary];
        if (ll) spec[(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
        if (o->require_hw)
            spec[(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = @YES;
        else
            spec[(__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = @YES;
        NSDictionary *src = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(cfg->width),
            (id)kCVPixelBufferHeightKey: @(cfg->height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        VTCompressionSessionRef s = NULL;
        OSStatus st = VTCompressionSessionCreate(NULL, (int32_t)cfg->width, (int32_t)cfg->height, codec, (__bridge CFDictionaryRef)spec,
                                                 (__bridge CFDictionaryRef)src, NULL, e ? on_output : NULL, e, &s);
        if (st != noErr || !s)
            return mh_fail(MH_ERR_UNSUPPORTED, "VTCompressionSessionCreate(%s%s, %ux%u): %d", cfg->codec == MH_CODEC_HEVC ? "HEVC" : "H.264",
                           ll ? ", low latency" : "", cfg->width, cfg->height, (int)st);
        SETP(kVTCompressionPropertyKey_RealTime, ll ? @YES : @NO, 0);
        SETP(kVTCompressionPropertyKey_AllowFrameReordering, @NO, 1);
        SETP(kVTCompressionPropertyKey_ProfileLevel,
             cfg->codec == MH_CODEC_H264 ? (__bridge NSString *)kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
                                         : (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel,
             0);
        SETP(kVTCompressionPropertyKey_AverageBitRate, @(cfg->bitrate_bps), 1);
        uint32_t expected = ll ? (o->expected_fps ? o->expected_fps : 1000) : (cfg->fps ? cfg->fps : 60);
        SETP(kVTCompressionPropertyKey_ExpectedFrameRate, @(expected), 0);
        SETP(kVTCompressionPropertyKey_MaxKeyFrameInterval, @(INT32_MAX), 0);
        SETP(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, @(0), 0);
        SETP(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, @YES, 0);
        SETP(kVTCompressionPropertyKey_MaximizePowerEfficiency, @NO, 0);
        if (cfg->ltr) SETP(kVTCompressionPropertyKey_EnableLTR, @YES, 1);
        st = VTCompressionSessionPrepareToEncodeFrames(s);
        if (st != noErr) {
            VTCompressionSessionInvalidate(s);
            CFRelease(s);
            return mh_fail(MH_ERR_UNSUPPORTED, "PrepareToEncodeFrames: %d", (int)st);
        }
        if (info) {
            read_info(s, info);
            info->low_latency = ll;
            info->ltr = cfg->ltr ? 1 : 0;
        }
        *out = s;
        return MH_OK;
    }
}

int mh_enc_create(const mh_enc_options *opts, mh_enc **out) {
    struct mh_enc *e = calloc(1, sizeof *e);
    if (!e) return mh_fail(MH_ERR_NOMEM, "out of memory");
    e->opts = *opts;
    e->done = (void *)CFBridgingRetain(dispatch_semaphore_create(0));
    e->last_pts_us = INT64_MIN;
    *out = e;
    return MH_OK;
}

int mh_enc_probe(const mh_enc_options *opts, uint32_t codec, uint32_t ltr, mh_enc_info *info) {
    mh_clear_error();
    mh_enc_config cfg = {.codec = codec, .width = 640, .height = 360, .fps = 60, .bitrate_bps = 2000000, .ltr = ltr};
    VTCompressionSessionRef s = NULL;
    mh_enc_info tmp;
    int rc = make_session(opts, &cfg, NULL, &s, info ? info : &tmp);
    if (rc != MH_OK) return rc;
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    return MH_OK;
}

static void drop_session(struct mh_enc *e) {
    if (e->session) {
        VTCompressionSessionCompleteFrames(e->session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(e->session);
        CFRelease(e->session);
        e->session = NULL;
    }
}

int mh_enc_configure(mh_enc *e, const mh_enc_config *cfg) {
    mh_clear_error();
    if (!cfg->width || !cfg->height || !cfg->bitrate_bps) return mh_fail(MH_ERR_UNSUPPORTED, "bad config");
    if (e->session && e->cfg.codec == cfg->codec && e->cfg.width == cfg->width && e->cfg.height == cfg->height && e->cfg.ltr == cfg->ltr) {
        // Same session: bitrate and frame rate change live, no keyframe.
        if (cfg->bitrate_bps != e->current_bps) {
            OSStatus st = VTSessionSetProperty(e->session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @(cfg->bitrate_bps));
            if (st != noErr) return mh_fail(MH_ERR, "AverageBitRate: %d", (int)st);
            e->current_bps = cfg->bitrate_bps;
        }
        if (e->opts.mode == MH_ENC_REGULAR && cfg->fps != e->cfg.fps)
            VTSessionSetProperty(e->session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef) @(cfg->fps));
        e->cfg = *cfg;
        return MH_OK;
    }
    drop_session(e);
    VTCompressionSessionRef s = NULL;
    int rc = make_session(&e->opts, cfg, e, &s, &e->info);
    if (rc != MH_OK) return rc;
    e->session = s;
    e->cfg = *cfg;
    e->current_bps = cfg->bitrate_bps;
    e->info.sessions++;
    return MH_OK;
}

static CVPixelBufferRef scaled(struct mh_enc *e, CVPixelBufferRef pb, int *rc) {
    if (!e->transfer) {
        OSStatus st = VTPixelTransferSessionCreate(NULL, &e->transfer);
        if (st != noErr) {
            *rc = mh_fail(MH_ERR, "VTPixelTransferSessionCreate: %d", (int)st);
            return NULL;
        }
        VTSessionSetProperty(e->transfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal);
    }
    CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(e->session);
    CVPixelBufferRef dst = NULL;
    if (!pool || CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &dst) != kCVReturnSuccess) {
        dst = mh_pixel_buffer_create(e->cfg.width, e->cfg.height, MH_FMT_NV12);
        if (!dst) {
            *rc = MH_ERR_NOMEM;
            return NULL;
        }
    }
    OSStatus st = VTPixelTransferSessionTransferImage(e->transfer, pb, dst);
    if (st != noErr) {
        CVPixelBufferRelease(dst);
        *rc = mh_fail(MH_ERR, "VTPixelTransferSessionTransferImage: %d", (int)st);
        return NULL;
    }
    return dst;
}

int mh_enc_encode(mh_enc *e, void *pixel_buffer, int64_t pts_us, const mh_enc_params *p, mh_enc_output *out) {
    @autoreleasepool {
        memset(out, 0, sizeof *out);
        if (!e->session) return mh_fail(MH_ERR_CLOSED, "encoder not configured");
        CVPixelBufferRef pb = (CVPixelBufferRef)pixel_buffer;
        if (p->bitrate_bps && p->bitrate_bps != e->current_bps) {
            OSStatus st = VTSessionSetProperty(e->session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @(p->bitrate_bps));
            if (st == noErr) {
                e->current_bps = p->bitrate_bps;
                e->cfg.bitrate_bps = p->bitrate_bps;
            }
        }
        CVPixelBufferRef owned = NULL;
        if (CVPixelBufferGetWidth(pb) != e->cfg.width || CVPixelBufferGetHeight(pb) != e->cfg.height) {
            int rc = MH_OK;
            owned = scaled(e, pb, &rc);
            if (!owned) return rc;
            pb = owned;
        }
        NSMutableDictionary *opts = nil;
        if (p->force != MH_FORCE_NONE || p->acked_ltr_count) {
            opts = [NSMutableDictionary dictionary];
            if (p->force == MH_FORCE_IDR) opts[(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame] = @YES;
            if (p->force == MH_FORCE_LTR_REFRESH) {
                if (e->cfg.ltr)
                    opts[(__bridge NSString *)kVTEncodeFrameOptionKey_ForceLTRRefresh] = @YES;
                else
                    opts[(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame] = @YES;
            }
            if (p->acked_ltr_count && e->cfg.ltr) {
                NSMutableArray *acks = [NSMutableArray arrayWithCapacity:p->acked_ltr_count];
                for (uint32_t i = 0; i < p->acked_ltr_count; i++) [acks addObject:@((int64_t)p->acked_ltr_tokens[i])];
                opts[(__bridge NSString *)kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acks;
            }
        }
        // Presentation times must increase; repeats of a frame carry its old capture time.
        if (pts_us <= e->last_pts_us) pts_us = e->last_pts_us + 1;
        e->last_pts_us = pts_us;
        uint32_t fps = e->cfg.fps ? e->cfg.fps : 60;
        e->len = 0;
        e->status = noErr;
        e->dropped = e->keyframe = e->has_token = 0;
        e->token = 0;
        dispatch_semaphore_t done = (__bridge dispatch_semaphore_t)e->done;
        VTEncodeInfoFlags flags = 0;
        CMTime pts = CMTimeMake(pts_us, 1000000);
        OSStatus st = VTCompressionSessionEncodeFrame(e->session, pb, pts, CMTimeMake(1, (int32_t)fps), (__bridge CFDictionaryRef)opts,
                                                      (void *)++e->frame_no, &flags);
        if (owned) CVPixelBufferRelease(owned);
        if (st != noErr) return mh_fail(MH_ERR_CODEC, "VTCompressionSessionEncodeFrame: %d", (int)st);
        if (MH_WAIT(done, 100) != 0) {
            // Not out yet: ask for everything up to this frame, then wait longer.
            VTCompressionSessionCompleteFrames(e->session, pts);
            if (MH_WAIT(done, 2000) != 0) return mh_fail(MH_ERR_CODEC, "encoder produced no output for the frame");
        }
        if (e->status != noErr) return mh_fail(MH_ERR_CODEC, "encode callback status %d", (int)e->status);
        if (e->dropped || e->len == 0) {
            out->dropped = 1;
            return MH_OK;
        }
        out->data = e->buf;
        out->len = e->len;
        out->keyframe = e->keyframe;
        out->has_ltr_token = e->has_token;
        out->ltr_token = (uint64_t)e->token;
        out->ltr_refresh = (p->force == MH_FORCE_LTR_REFRESH && e->cfg.ltr && !e->keyframe) ? 1 : 0;
        return MH_OK;
    }
}

void mh_enc_get_info(mh_enc *e, mh_enc_info *out) { *out = e->info; }

void mh_enc_destroy(mh_enc *e) {
    if (!e) return;
    drop_session(e);
    if (e->transfer) {
        VTPixelTransferSessionInvalidate(e->transfer);
        CFRelease(e->transfer);
    }
    mh_cf_release(e->done);
    free(e->buf);
    free(e);
}

size_t mh_enc_list(char *buf, size_t cap) {
    @autoreleasepool {
        if (cap == 0) return 0;
        buf[0] = 0;
        CFArrayRef list = NULL;
        if (VTCopyVideoEncoderList(NULL, &list) != noErr || !list) return 0;
        size_t len = 0;
        for (NSDictionary *d in (__bridge NSArray *)list) {
            NSString *name = d[(__bridge NSString *)kVTVideoEncoderList_EncoderName];
            NSString *eid = d[(__bridge NSString *)kVTVideoEncoderList_EncoderID];
            NSNumber *hw = d[(__bridge NSString *)kVTVideoEncoderList_IsHardwareAccelerated];
            NSNumber *codec = d[(__bridge NSString *)kVTVideoEncoderList_CodecType];
            uint32_t c = codec.unsignedIntValue;
            int n = snprintf(buf + len, cap - len, "%c%c%c%c %s (%s)%s\n", (char)(c >> 24), (char)(c >> 16), (char)(c >> 8), (char)c,
                             name.UTF8String ?: "?", eid.UTF8String ?: "?", hw.boolValue ? " hardware" : "");
            if (n < 0 || (size_t)n >= cap - len) break;
            len += (size_t)n;
        }
        CFRelease(list);
        return len;
    }
}

// ---------------------------------------------------------------------------
// Decoder for tests: Annex B in, luma hash out.

struct mh_dec {
    uint32_t codec;
    CMVideoFormatDescriptionRef fd;
    VTDecompressionSessionRef session;
    OSStatus status;
    uint64_t hash;
};

static void on_decoded(void *ref, void *frame_ref, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef img, CMTime pts,
                       CMTime dur) {
    struct mh_dec *d = ref;
    d->status = status;
    d->hash = 0;
    if (status != noErr || !img) return;
    CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(img, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(img, 0), h = CVPixelBufferGetHeightOfPlane(img, 0),
           w = CVPixelBufferGetWidthOfPlane(img, 0);
    uint64_t hv = 1469598103934665603ull;
    for (size_t j = 0; j < h; j++)
        for (size_t x = 0; x < w; x += 4) {
            hv ^= y[j * ys + x];
            hv *= 1099511628211ull;
        }
    CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    d->hash = hv;
}

int mh_dec_create(uint32_t codec, mh_dec **out) {
    struct mh_dec *d = calloc(1, sizeof *d);
    if (!d) return mh_fail(MH_ERR_NOMEM, "out of memory");
    d->codec = codec;
    *out = d;
    return MH_OK;
}

typedef struct {
    const uint8_t *p;
    size_t n;
} nal_t;

static size_t split_annex_b(const uint8_t *data, size_t len, nal_t *nals, size_t max) {
    size_t count = 0, i = 0, start = SIZE_MAX;
    while (i + 3 <= len) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (start != SIZE_MAX && count < max) {
                size_t end = i;
                while (end > start && data[end - 1] == 0) end--;
                nals[count++] = (nal_t){data + start, end - start};
            }
            i += 3;
            start = i;
        } else {
            i++;
        }
    }
    if (start != SIZE_MAX && start < len && count < max) nals[count++] = (nal_t){data + start, len - start};
    return count;
}

static int is_param_set(uint32_t codec, uint8_t h) {
    if (codec == MH_CODEC_HEVC) {
        uint8_t t = (h >> 1) & 0x3f;
        return t == 32 || t == 33 || t == 34;
    }
    uint8_t t = h & 0x1f;
    return t == 7 || t == 8;
}

int mh_dec_decode(mh_dec *d, const uint8_t *data, size_t len, uint64_t *hash) {
    @autoreleasepool {
        nal_t nals[64];
        size_t n = split_annex_b(data, len, nals, 64);
        const uint8_t *ps[8];
        size_t ps_len[8], nps = 0;
        size_t payload = 0;
        for (size_t i = 0; i < n; i++) {
            if (nals[i].n == 0) continue;
            if (is_param_set(d->codec, nals[i].p[0])) {
                if (nps < 8) {
                    ps[nps] = nals[i].p;
                    ps_len[nps++] = nals[i].n;
                }
            } else {
                payload += 4 + nals[i].n;
            }
        }
        OSStatus st;
        if (nps > 0) {
            CMVideoFormatDescriptionRef fd = NULL;
            st = d->codec == MH_CODEC_HEVC ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, nps, ps, ps_len, 4, NULL, &fd)
                                           : CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, nps, ps, ps_len, 4, &fd);
            if (st != noErr) return st;
            if (!d->fd || !CMFormatDescriptionEqual(d->fd, fd)) {
                if (d->session) {
                    VTDecompressionSessionInvalidate(d->session);
                    CFRelease(d->session);
                    d->session = NULL;
                }
                if (d->fd) CFRelease(d->fd);
                d->fd = fd;
                VTDecompressionOutputCallbackRecord cb = {on_decoded, d};
                NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
                st = VTDecompressionSessionCreate(NULL, d->fd, NULL, (__bridge CFDictionaryRef)attrs, &cb, &d->session);
                if (st != noErr) return st;
            } else {
                CFRelease(fd);
            }
        }
        if (!d->session) return -1;
        if (payload == 0) return -2;
        uint8_t *avcc = malloc(payload);
        if (!avcc) return -3;
        size_t off = 0;
        for (size_t i = 0; i < n; i++) {
            if (nals[i].n == 0 || is_param_set(d->codec, nals[i].p[0])) continue;
            uint32_t be = (uint32_t)nals[i].n;
            avcc[off] = (uint8_t)(be >> 24);
            avcc[off + 1] = (uint8_t)(be >> 16);
            avcc[off + 2] = (uint8_t)(be >> 8);
            avcc[off + 3] = (uint8_t)be;
            memcpy(avcc + off + 4, nals[i].p, nals[i].n);
            off += 4 + nals[i].n;
        }
        CMBlockBufferRef bb = NULL;
        st = CMBlockBufferCreateWithMemoryBlock(NULL, avcc, payload, kCFAllocatorMalloc, NULL, 0, payload, 0, &bb);
        if (st != noErr) {
            free(avcc);
            return st;
        }
        CMSampleBufferRef sb = NULL;
        const size_t sizes[1] = {payload};
        st = CMSampleBufferCreateReady(NULL, bb, d->fd, 1, 0, NULL, 1, sizes, &sb);
        CFRelease(bb);
        if (st != noErr) return st;
        d->status = -12909; // kVTVideoDecoderBadDataErr until the callback says otherwise
        d->hash = 0;
        VTDecodeInfoFlags fl = 0;
        st = VTDecompressionSessionDecodeFrame(d->session, sb, 0, NULL, &fl);
        if (st == noErr) VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        CFRelease(sb);
        if (st != noErr) return st;
        *hash = d->hash;
        return d->status;
    }
}

void mh_dec_destroy(mh_dec *d) {
    if (!d) return;
    if (d->session) {
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session);
    }
    if (d->fd) CFRelease(d->fd);
    free(d);
}
