// moonsec macOS client: VideoToolbox decode (macc.h).
//
// Access units arrive as Annex B. Parameter sets (H.264 SPS/PPS, HEVC VPS/SPS/PPS)
// are taken out and kept: they make the CMVideoFormatDescription, and the session is
// (re)created from it when they change in a way the session can't take, or after a
// flush or an invalidated session. Everything else but access unit delimiters goes
// into the sample as 4-byte length-prefixed NAL units.
//
// Decoding is synchronous (no kVTDecodeFrame_EnableAsynchronousDecompression, no
// temporal processing): the output callback runs before VTDecompressionSessionDecode-
// Frame returns, with the picture of the access unit just fed, in decode order. Our
// streams have no B-frames, so that is display order too.

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "macc.h"
#include "macc_internal.h"

enum { MAX_PS = 3, MAX_PS_BYTES = 1024 };

typedef struct {
    uint8_t bytes[MAX_PS_BYTES];
    size_t len;
} param_set;

@interface MaccDecoderObj : NSObject {
  @public
    uint32_t codec;
    int hardware;
    // Latest parameter sets by slot: H.264 SPS, PPS; HEVC VPS, SPS, PPS.
    param_set ps[MAX_PS];
    int ps_dirty;
    CMVideoFormatDescriptionRef fd;
    VTDecompressionSessionRef session;
    // Set by the output callback.
    CVPixelBufferRef out;
    int64_t out_pts;
    OSStatus cb_status;
    int cb_called;
    // The frame handed to the caller.
    CVPixelBufferRef held;
}
@end

@implementation MaccDecoderObj
- (void)dropSession {
    if (session) {
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
        session = NULL;
    }
}
- (void)dealloc {
    [self dropSession];
    if (fd) CFRelease(fd);
    if (out) CVPixelBufferRelease(out);
    if (held) CVPixelBufferRelease(held);
}
@end

static MaccDecoderObj *D(macc_decoder *d) {
    return (__bridge MaccDecoderObj *)(void *)d;
}

static void output_cb(void *refcon, void *frame_refcon, OSStatus status, VTDecodeInfoFlags flags,
                      CVImageBufferRef image, CMTime pts, CMTime duration) {
    (void)frame_refcon;
    (void)duration;
    MaccDecoderObj *d = (__bridge MaccDecoderObj *)refcon;
    d->cb_called = 1;
    d->cb_status = status;
    if (status != noErr || !image || (flags & kVTDecodeInfo_FrameDropped)) return;
    if (d->out) CVPixelBufferRelease(d->out);
    d->out = CVPixelBufferRetain(image);
    d->out_pts = pts.value;
}

macc_status macc_decoder_create(uint32_t codec, int hardware, macc_decoder **out) {
    *out = NULL;
    if (codec != MACC_CODEC_H264 && codec != MACC_CODEC_HEVC) return MACC_E_UNSUPPORTED;
    MaccDecoderObj *d = [MaccDecoderObj new];
    d->codec = codec;
    d->hardware = hardware;
    *out = (__bridge_retained macc_decoder *)d;
    return MACC_OK;
}

void macc_decoder_destroy(macc_decoder *dec) {
    if (!dec) return;
    CFBridgingRelease(dec); // drops the reference create handed out
}

int macc_decoder_is_hardware(macc_decoder *dec) {
    MaccDecoderObj *d = D(dec);
    if (!d->session) return 0;
    CFBooleanRef v = NULL;
    OSStatus st = VTSessionCopyProperty(d->session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                        kCFAllocatorDefault, &v);
    int hw = st == noErr && v && CFBooleanGetValue(v);
    if (v) CFRelease(v);
    return hw;
}

void macc_decoder_flush(macc_decoder *dec) {
    MaccDecoderObj *d = D(dec);
    [d dropSession];
    if (d->out) {
        CVPixelBufferRelease(d->out);
        d->out = NULL;
    }
}

// ---------------------------------------------------------------------------
// Annex B

typedef struct {
    const uint8_t *p;
    size_t len;
} nal;

// Splits Annex B into NAL units (start codes and trailing zero bytes removed).
static size_t split_nals(const uint8_t *data, size_t len, nal *out, size_t max) {
    size_t n = 0, i = 0, start = SIZE_MAX;
    while (i + 2 < len) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (start != SIZE_MAX && n < max) {
                size_t end = i;
                while (end > start && data[end - 1] == 0) end--;
                if (end > start) out[n++] = (nal){data + start, end - start};
            }
            i += 3;
            start = i;
        } else {
            i++;
        }
    }
    if (start != SIZE_MAX && start < len && n < max) {
        size_t end = len;
        while (end > start && data[end - 1] == 0) end--;
        if (end > start) out[n++] = (nal){data + start, end - start};
    }
    return n;
}

// Parameter-set slot for a NAL, -1 when it is not one; *skip for NALs that stay out
// of the sample (parameter sets and access unit delimiters).
static int ps_slot(uint32_t codec, const nal *u, int *skip) {
    *skip = 0;
    if (codec == MACC_CODEC_H264) {
        uint8_t t = u->p[0] & 0x1F;
        if (t == 9) *skip = 1;
        if (t == 7) return 0;
        if (t == 8) return 1;
        return -1;
    }
    if (u->len < 2) {
        *skip = 1;
        return -1;
    }
    uint8_t t = (u->p[0] >> 1) & 0x3F;
    if (t == 35) *skip = 1;
    if (t == 32) return 0;
    if (t == 33) return 1;
    if (t == 34) return 2;
    return -1;
}

static OSStatus make_format(MaccDecoderObj *d) {
    size_t count = d->codec == MACC_CODEC_H264 ? 2 : 3;
    const uint8_t *ptrs[MAX_PS];
    size_t sizes[MAX_PS];
    for (size_t i = 0; i < count; i++) {
        if (d->ps[i].len == 0) return MACC_E_BAD_STREAM;
        ptrs[i] = d->ps[i].bytes;
        sizes[i] = d->ps[i].len;
    }
    CMVideoFormatDescriptionRef fd = NULL;
    OSStatus st;
    if (d->codec == MACC_CODEC_H264)
        st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count, ptrs, sizes, 4, &fd);
    else
        st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count, ptrs, sizes, 4, NULL, &fd);
    if (st != noErr) return st;
    if (d->session && !VTDecompressionSessionCanAcceptFormatDescription(d->session, fd)) [d dropSession];
    if (d->fd) CFRelease(d->fd);
    d->fd = fd;
    return noErr;
}

static OSStatus make_session(MaccDecoderObj *d) {
    NSDictionary *spec = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder : @(d->hardware != 0),
    };
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    VTDecompressionOutputCallbackRecord cb = {output_cb, (__bridge void *)d};
    VTDecompressionSessionRef s = NULL;
    OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, d->fd, (__bridge CFDictionaryRef)spec,
                                               (__bridge CFDictionaryRef)attrs, &cb, &s);
    if (st != noErr) return st;
    VTSessionSetProperty(s, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    d->session = s;
    return noErr;
}

uint32_t macc_matrix_of(void *buffer) {
    CVPixelBufferRef pb = (CVPixelBufferRef)buffer;
    CFTypeRef m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
    uint32_t r = MACC_MATRIX_BT709;
    if (m) {
        if (CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_601_4) || CFEqual(m, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995))
            r = MACC_MATRIX_BT601;
        else if (CFEqual(m, kCVImageBufferYCbCrMatrix_ITU_R_2020))
            r = MACC_MATRIX_BT2020;
        CFRelease(m);
    }
    return r;
}

static OSStatus decode_sample(MaccDecoderObj *d, CMSampleBufferRef sb) {
    d->cb_called = 0;
    d->cb_status = noErr;
    VTDecodeInfoFlags info = 0;
    OSStatus st = VTDecompressionSessionDecodeFrame(d->session, sb, 0, NULL, &info);
    if (st == noErr && d->cb_called && d->cb_status != noErr) st = d->cb_status;
    return st;
}

macc_status macc_decoder_decode(macc_decoder *dec, const uint8_t *data, size_t len, int64_t pts, macc_frame *frame,
                                int *got) {
    MaccDecoderObj *d = D(dec);
    *got = 0;
    if (d->held) return MACC_E_INVALID; // release first
    @autoreleasepool {
        nal nals[256];
        size_t n = split_nals(data, len, nals, 256);

        // Parameter sets first, and the size of the rest.
        size_t body = 0;
        for (size_t i = 0; i < n; i++) {
            int skip = 0;
            int slot = ps_slot(d->codec, &nals[i], &skip);
            if (slot >= 0) {
                if (nals[i].len > MAX_PS_BYTES) return MACC_E_BAD_STREAM;
                param_set *p = &d->ps[slot];
                if (p->len != nals[i].len || memcmp(p->bytes, nals[i].p, nals[i].len) != 0) {
                    memcpy(p->bytes, nals[i].p, nals[i].len);
                    p->len = nals[i].len;
                    d->ps_dirty = 1;
                }
            } else if (!skip) {
                body += 4 + nals[i].len;
            }
        }
        if (d->ps_dirty) {
            OSStatus st = make_format(d);
            if (st == MACC_E_BAD_STREAM && body == 0) return MACC_OK; // more parameter sets to come
            if (st != noErr) return st;
            d->ps_dirty = 0;
        }
        if (body == 0) return MACC_OK;
        if (!d->fd) return MACC_E_BAD_STREAM;
        if (!d->session) {
            OSStatus st = make_session(d);
            if (st != noErr) return st;
        }

        CMBlockBufferRef bb = NULL;
        OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, body, kCFAllocatorDefault, NULL, 0,
                                                         body, kCMBlockBufferAssureMemoryNowFlag, &bb);
        if (st != noErr) return st;
        size_t off = 0;
        for (size_t i = 0; i < n; i++) {
            int skip = 0;
            if (ps_slot(d->codec, &nals[i], &skip) >= 0 || skip) continue;
            uint32_t be = CFSwapInt32HostToBig((uint32_t)nals[i].len);
            CMBlockBufferReplaceDataBytes(&be, bb, off, 4);
            CMBlockBufferReplaceDataBytes(nals[i].p, bb, off + 4, nals[i].len);
            off += 4 + nals[i].len;
        }
        CMSampleBufferRef sb = NULL;
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts, 1), kCMTimeInvalid};
        size_t sample_size = body;
        st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, d->fd, 1, 1, &timing, 1, &sample_size, &sb);
        CFRelease(bb);
        if (st != noErr) return st;

        st = decode_sample(d, sb);
        if (st == kVTInvalidSessionErr) {
            // The session went away (GPU change, sleep): one more try on a fresh one.
            [d dropSession];
            st = make_session(d);
            if (st == noErr) st = decode_sample(d, sb);
        }
        CFRelease(sb);
        if (st != noErr) return st;
        if (!d->out) return MACC_OK;

        CVPixelBufferRef pb = d->out;
        d->out = NULL;
        d->held = pb;
        CGRect clean = CVImageBufferGetCleanRect(pb);
        size_t bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb);
        frame->pixel_buffer = pb;
        frame->width = clean.size.width > 0 ? (uint32_t)clean.size.width : (uint32_t)bw;
        frame->height = clean.size.height > 0 ? (uint32_t)clean.size.height : (uint32_t)bh;
        if (frame->width > bw) frame->width = (uint32_t)bw;
        if (frame->height > bh) frame->height = (uint32_t)bh;
        frame->pts = d->out_pts;
        frame->full_range = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        frame->matrix = macc_matrix_of(pb);
        *got = 1;
        return MACC_OK;
    }
}

void macc_decoder_release_frame(macc_decoder *dec, macc_frame *frame) {
    MaccDecoderObj *d = D(dec);
    if (d->held && frame && frame->pixel_buffer == d->held) {
        CVPixelBufferRelease(d->held);
        d->held = NULL;
        frame->pixel_buffer = NULL;
    }
}

macc_status macc_frame_read_nv12(const macc_frame *frame, uint32_t x, uint32_t y, uint8_t yuv[3]) {
    CVPixelBufferRef pb = (CVPixelBufferRef)frame->pixel_buffer;
    if (!pb || CVPixelBufferGetPlaneCount(pb) != 2) return MACC_E_INVALID;
    if (x >= CVPixelBufferGetWidthOfPlane(pb, 0) || y >= CVPixelBufferGetHeightOfPlane(pb, 0)) return MACC_E_INVALID;
    CVReturn r = CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (r != kCVReturnSuccess) return r;
    const uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    const uint8_t *uvp = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    yuv[0] = yp[y * ys + x];
    yuv[1] = uvp[(y / 2) * uvs + (x / 2) * 2];
    yuv[2] = uvp[(y / 2) * uvs + (x / 2) * 2 + 1];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return MACC_OK;
}
