// S7 probe: ScreenCaptureKit -> VideoToolbox low-latency encode, per-stage timing.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include "probe.h"

static mach_timebase_info_data_t g_tb;
static double ticks_to_ms(uint64_t t) { return (double)t * g_tb.numer / g_tb.denom / 1e6; }

static const probe_config *g_cfg;
static probe_sample *g_out;
static int g_max;
static _Atomic int g_next;
static _Atomic int g_stopping;
static VTCompressionSessionRef g_vt;
static int g_rc;
static NSMutableString *g_info;

typedef struct { int idx; uint64_t origin; uint64_t submit; } frame_ref;

// ---------- LTR loss simulation (S7_LTR=1) ----------
// Every S7_LTR_EVERY frames (from frame S7_LTR_EVERY), S7_LTR_LEN frames are "lost". The simulated client acks the
// LTR token of every frame it decoded, S7_LTR_ACK frames after submit, and never acks lost frames or anything between
// the loss and the refresh. The host learns of the loss S7_LTR_ACK frames after the last lost frame and encodes that
// frame with ForceLTRRefresh. After the run both the full stream and the lossy stream (client drops from the first lost
// frame until the refresh, per S8's HEVC rule) are decoded and compared per frame.
static int g_ltr, g_ltr_every = 300, g_ltr_len = 5, g_ltr_ack = 3;
static CMSampleBufferRef *g_sbs;
static int32_t *g_tok;
static _Atomic uint8_t *g_tokstate; // 0 pending, 1 done no token, 2 done with token
static int g_ack_cursor;
static int g_loss_a(int i) { if (i < g_ltr_every) return -1; int k = i / g_ltr_every; return k * g_ltr_every; }
// frame i belongs to the client-dropped span [loss start, refresh) of some loss event?
static int g_dropped(int i) { int a = g_loss_a(i); if (a < 0) return 0; return i < a + g_ltr_len + g_ltr_ack; }
static int g_is_refresh(int i) { int a = g_loss_a(i); return a >= 0 && i == a + g_ltr_len + g_ltr_ack; }


static void vt_out(void *outRef, void *srcRef, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    uint64_t now = mach_absolute_time();
    frame_ref *fr = (frame_ref *)srcRef;
    if (fr == NULL) return;
    if (status == noErr && sb != NULL && fr->idx < g_max) {
        probe_sample *s = &g_out[fr->idx];
        s->encode_ms = ticks_to_ms(now - fr->submit);
        int64_t tt = (int64_t)(now - fr->origin);
        s->total_ms = tt >= 0 ? ticks_to_ms((uint64_t)tt) : -ticks_to_ms((uint64_t)-tt);
        s->bytes = (uint32_t)CMSampleBufferGetTotalSampleSize(sb);
        CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
        bool key = true;
        if (att && CFArrayGetCount(att) > 0) {
            CFDictionaryRef d = CFArrayGetValueAtIndex(att, 0);
            CFBooleanRef notSync = CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
            key = !(notSync && CFBooleanGetValue(notSync));
        }
        s->keyframe = key;
        if (g_ltr) {
            CFDictionaryRef d0 = (att && CFArrayGetCount(att) > 0) ? CFArrayGetValueAtIndex(att, 0) : NULL;
            CFNumberRef tok = d0 ? CFDictionaryGetValue(d0, kVTSampleAttachmentKey_RequireLTRAcknowledgementToken) : NULL;
            if (tok) { CFNumberGetValue(tok, kCFNumberSInt32Type, &g_tok[fr->idx]); s->ltr_token = 1; }
            CFRetain(sb); g_sbs[fr->idx] = sb;
            atomic_store(&g_tokstate[fr->idx], tok ? 2 : 1);
        }
        s->done = 1;
    } else if (g_ltr && fr->idx < g_max) atomic_store(&g_tokstate[fr->idx], 1);
    free(fr);
}

static void encode(CVPixelBufferRef pb, uint64_t origin, double capture_ms) {
    if (atomic_load(&g_stopping)) return;
    int idx = atomic_fetch_add(&g_next, 1);
    if (idx >= g_max) return;
    g_out[idx].capture_ms = capture_ms;
    frame_ref *fr = malloc(sizeof *fr);
    fr->idx = idx; fr->origin = origin;
    static int ptsr = 0; if (!ptsr) ptsr = getenv("S7_PTS_RATE") ? atoi(getenv("S7_PTS_RATE")) : g_cfg->fps;
    CMTime pts = CMTimeMake(idx, ptsr);
    NSMutableDictionary *opts = nil;
    if (g_ltr) {
        opts = [NSMutableDictionary dictionary];
        NSMutableArray *acks = [NSMutableArray array];
        // client has received (and reports) everything submitted up to idx - ack delay that is done
        while (g_ack_cursor <= idx - g_ltr_ack && atomic_load(&g_tokstate[g_ack_cursor]) != 0) {
            int j = g_ack_cursor++;
            if (atomic_load(&g_tokstate[j]) == 2 && !g_dropped(j)) [acks addObject:@(g_tok[j])];
        }
        if (acks.count) opts[(__bridge NSString *)kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acks;
        if (g_is_refresh(idx) && !getenv("S7_LTR_NOREFRESH")) { opts[(__bridge NSString *)kVTEncodeFrameOptionKey_ForceLTRRefresh] = @YES; g_out[idx].refresh = 1; }
        if (g_dropped(idx)) g_out[idx].lost = 1;
    }
    fr->submit = mach_absolute_time();
    OSStatus st = VTCompressionSessionEncodeFrame(g_vt, pb, pts, getenv("S7_NODUR") ? kCMTimeInvalid : CMTimeMake(1, ptsr), (__bridge CFDictionaryRef)opts, fr, NULL);
    if (st != noErr) { free(fr); if (g_ltr) atomic_store(&g_tokstate[idx], 1); }
}

static int setup_vt(void) {
    CMVideoCodecType codec = g_cfg->codec ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
    NSMutableDictionary *spec = [NSMutableDictionary dictionary];
    if (g_cfg->low_latency) spec[(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
    spec[(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = @YES;
    OSStatus st = VTCompressionSessionCreate(NULL, g_cfg->width, g_cfg->height, codec, (__bridge CFDictionaryRef)spec,
                                             NULL, NULL, vt_out, NULL, &g_vt);
    if (st != noErr) { [g_info appendFormat:@"VTCompressionSessionCreate failed: %d\n", (int)st]; return -1; }
#define SETP(k, v) do { OSStatus e = VTSessionSetProperty(g_vt, k, (__bridge CFTypeRef)(v)); \
    [g_info appendFormat:@"  %@ = %@%@\n", (__bridge NSString *)k, v, e ? [NSString stringWithFormat:@" (err %d)", (int)e] : @""]; } while (0)
    SETP(kVTCompressionPropertyKey_RealTime, getenv("S7_REALTIME") && !strcmp(getenv("S7_REALTIME"),"0") ? @NO : @YES);
    if (getenv("S7_SPEED_EXTRA")) SETP(kVTCompressionPropertyKey_MaxFrameDelayCount, @0);
    SETP(kVTCompressionPropertyKey_AllowFrameReordering, @NO);
    if (g_cfg->codec == 0)
        SETP(kVTCompressionPropertyKey_ProfileLevel, (__bridge NSString *)(getenv("S7_BASELINE") ? kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel));
    else
        SETP(kVTCompressionPropertyKey_ProfileLevel, (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel);
    SETP(kVTCompressionPropertyKey_AverageBitRate, @(g_cfg->bitrate_kbps * 1000));
    if (getenv("S7_VBV")) { // cap bytes per frame interval: one-frame VBV, factor x average
        double f = atof(getenv("S7_VBV"));
        SETP(kVTCompressionPropertyKey_DataRateLimits, (@[@((int)(g_cfg->bitrate_kbps * 1000.0 / 8 / g_cfg->fps * f)), @(1.0 / g_cfg->fps)]));
    }
    SETP(kVTCompressionPropertyKey_ExpectedFrameRate, @(getenv("S7_EXPECTED_FPS") ? atoi(getenv("S7_EXPECTED_FPS")) : g_cfg->fps));
    SETP(kVTCompressionPropertyKey_MaxKeyFrameInterval, @(INT32_MAX));
    SETP(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, @(0));
    SETP(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, @YES);
    SETP(kVTCompressionPropertyKey_MaximizePowerEfficiency, @NO);
    if (g_ltr) SETP(kVTCompressionPropertyKey_EnableLTR, @YES);
    if (getenv("S7_MAXDELAY")) SETP(kVTCompressionPropertyKey_MaxFrameDelayCount, @(atoi(getenv("S7_MAXDELAY"))));
#undef SETP
    CFStringRef eid = NULL;
    VTSessionCopyProperty(g_vt, kVTCompressionPropertyKey_EncoderID, NULL, &eid);
    [g_info appendFormat:@"  encoder id: %@\n", (__bridge NSString *)eid];
    if (eid) CFRelease(eid);
    CFBooleanRef hw = NULL;
    VTSessionCopyProperty(g_vt, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hw);
    [g_info appendFormat:@"  hardware encoder: %s\n", hw == kCFBooleanTrue ? "yes" : "no"];
    if (hw) CFRelease(hw);
    VTCompressionSessionPrepareToEncodeFrames(g_vt);
    return 0;
}

// ---------- animated content window ----------
@interface SceneView : NSView @end
@implementation SceneView {
    uint64_t _frame;
    uint8_t *_noise;
}
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)r {
    CGContextRef c = NSGraphicsContext.currentContext.CGContext;
    NSRect b = self.bounds;
    _frame++;
    if (g_cfg->scene == 1) {
        const int w = 480, h = 270;
        if (!_noise) _noise = malloc(w * h * 4);
        uint32_t *p = (uint32_t *)_noise;
        for (int i = 0; i < w * h; i++) p[i] = arc4random() | 0xff000000;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(_noise, w, h, 8, w * 4, cs, kCGImageAlphaNoneSkipFirst);
        CGImageRef img = CGBitmapContextCreateImage(bc);
        CGContextSetInterpolationQuality(c, kCGInterpolationNone);
        CGContextDrawImage(c, b, img);
        CGImageRelease(img); CGContextRelease(bc); CGColorSpaceRelease(cs);
    } else {
        // Moving gradient bands plus scrolling text: typical desktop/game motion.
        double t = _frame / 60.0;
        int bands = 24;
        for (int i = 0; i < bands; i++) {
            double ph = t * 2.0 + i * 0.4;
            CGContextSetRGBFillColor(c, 0.5 + 0.5 * sin(ph), 0.5 + 0.5 * sin(ph + 2.1), 0.5 + 0.5 * sin(ph + 4.2), 1);
            CGFloat bw = b.size.width / bands;
            CGContextFillRect(c, CGRectMake(i * bw, 0, bw + 1, b.size.height));
        }
        NSDictionary *a = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:22 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: NSColor.whiteColor};
        for (int line = 0; line < 20; line++) {
            CGFloat y = fmod(line * 28 + _frame * 4, b.size.height);
            NSString *s = [NSString stringWithFormat:@"frame %06llu line %02d  the quick brown fox jumps over the lazy dog %08x",
                           _frame, line, arc4random()];
            [s drawAtPoint:NSMakePoint(10 + 30 * sin(t + line), y) withAttributes:a];
        }
        CGFloat x = fmod(_frame * 12, b.size.width);
        CGContextSetRGBFillColor(c, 1, 1, 1, 1);
        CGContextFillEllipseInRect(c, CGRectMake(x, b.size.height / 2 + 120 * sin(t * 3), 80, 80));
    }
}
@end

static NSWindow *g_win;
static NSTimer *g_timer;
static CGWindowID g_winid;

static void make_window(void) {
    // 960x540 pt = 1920x1080 px on a 2x display.
    NSRect fr = NSMakeRect(80, 80, 960, 540);
    g_win = [[NSWindow alloc] initWithContentRect:fr styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                          backing:NSBackingStoreBuffered defer:NO];
    g_win.title = @"S7 probe content";
    g_win.releasedWhenClosed = NO;
    SceneView *v = [[SceneView alloc] initWithFrame:fr];
    g_win.contentView = v;
    g_win.level = NSFloatingWindowLevel;
    [g_win orderFrontRegardless];
    g_winid = (CGWindowID)g_win.windowNumber;
    g_timer = [NSTimer timerWithTimeInterval:1.0 / 120.0 repeats:YES block:^(NSTimer *t) { v.needsDisplay = YES; }];
    [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
}

static void finish(int rc) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_rc = rc;
        [NSApp stop:nil];
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                       timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
        [NSApp postEvent:e atStart:YES];
    });
}

// ---------- SCK ----------
@interface Out : NSObject <SCStreamOutput, SCStreamDelegate> @end
@implementation Out
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    uint64_t now = mach_absolute_time();
    if (type != SCStreamOutputTypeScreen) return;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!att || CFArrayGetCount(att) == 0) return;
    NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(att, 0);
    NSNumber *status = d[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    NSNumber *disp = d[SCStreamFrameInfoDisplayTime];
    uint64_t origin = disp ? disp.unsignedLongLongValue : now;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    static int dbg = 0;
    if (getenv("S7_DEBUG") && dbg++ < 8) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        fprintf(stderr, "now=%llu cont=%llu disp=%llu pts=%.6f hostclock=%.6f\n", now, mach_continuous_time(), origin,
                CMTimeGetSeconds(pts), CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())));
    }
    int64_t dt = (int64_t)(now - origin);
    // displayTime is the vsync this frame is shown on; it usually lies a few ms AFTER delivery, so this is signed.
    encode(pb, origin, dt >= 0 ? ticks_to_ms((uint64_t)dt) : -ticks_to_ms((uint64_t)-dt));
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    [g_info appendFormat:@"stream stopped: %@\n", error];
    finish(-3);
}
@end

static SCStream *g_stream;
static Out *g_outobj;

static void start_sck(void) {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *err) {
        if (err || !content) {
            [g_info appendFormat:@"getShareableContent failed (Screen Recording permission?): %@\n", err];
            finish(-2);
            return;
        }
        SCContentFilter *filter = nil;
        if (g_cfg->source == 2) {
            for (SCWindow *w in content.windows) if (w.windowID == g_winid) filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
            if (!filter) { [g_info appendString:@"probe window not found in shareable content\n"]; finish(-2); return; }
            [g_info appendString:@"capture: probe window (desktop independent)\n"];
        } else {
            SCDisplay *disp = content.displays.firstObject;
            filter = [[SCContentFilter alloc] initWithDisplay:disp excludingWindows:@[]];
            [g_info appendFormat:@"capture: display %u (%ldx%ld pt), scaled to %dx%d\n", disp.displayID,
                (long)disp.width, (long)disp.height, g_cfg->width, g_cfg->height];
        }
        SCStreamConfiguration *sc = [SCStreamConfiguration new];
        sc.width = g_cfg->width; sc.height = g_cfg->height;
        sc.minimumFrameInterval = CMTimeMake(1, g_cfg->fps);
        sc.pixelFormat = g_cfg->pixfmt ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        sc.queueDepth = 5;
        sc.showsCursor = YES;
        g_outobj = [Out new];
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:sc delegate:g_outobj];
        dispatch_queue_t q = dispatch_queue_create("s7.capture", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        NSError *e2 = nil;
        [g_stream addStreamOutput:g_outobj type:SCStreamOutputTypeScreen sampleHandlerQueue:q error:&e2];
        if (e2) { [g_info appendFormat:@"addStreamOutput: %@\n", e2]; finish(-2); return; }
        [g_stream startCaptureWithCompletionHandler:^(NSError *e3) {
            if (e3) { [g_info appendFormat:@"startCapture failed: %@\n", e3]; finish(-2); return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)g_cfg->seconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                atomic_store(&g_stopping, 1);
                [g_stream stopCaptureWithCompletionHandler:^(NSError *e4) { finish(0); }];
            });
        }];
    }];
}

// ---------- synthetic ----------
static CVPixelBufferPoolRef g_pool;
static dispatch_source_t g_tick;
static uint64_t g_synframe;

static void fill(CVPixelBufferRef pb) {
    CVPixelBufferLockBaseAddress(pb, 0);
    uint64_t f = g_synframe++;
    if (g_cfg->pixfmt == 0) {
        for (size_t p = 0; p < 2; p++) {
            uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, p);
            size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, p), h = CVPixelBufferGetHeightOfPlane(pb, p);
            size_t w = CVPixelBufferGetWidthOfPlane(pb, p) * (p ? 2 : 1);
            for (size_t y = 0; y < h; y++) {
                uint8_t *row = base + y * stride;
                if (g_cfg->scene == 1) arc4random_buf(row, w);
                else for (size_t x = 0; x < w; x++) row[x] = (uint8_t)(x + y + f * 4);
            }
        }
    } else {
        uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t stride = CVPixelBufferGetBytesPerRow(pb), h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb) * 4;
        for (size_t y = 0; y < h; y++) {
            uint8_t *row = base + y * stride;
            if (g_cfg->scene == 1) arc4random_buf(row, w);
            else for (size_t x = 0; x < w; x++) row[x] = (uint8_t)(x + y + f * 4);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

static void start_synthetic(void) {
    OSType fmt = g_cfg->pixfmt ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(fmt), (id)kCVPixelBufferWidthKey: @(g_cfg->width),
                            (id)kCVPixelBufferHeightKey: @(g_cfg->height), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &g_pool);
    // Pre-render a ring of frames so fill time is not counted and pacing is exact.
    enum { RING = 8 };
    static CVPixelBufferRef ring[RING];
    for (int i = 0; i < RING; i++) { CVPixelBufferPoolCreatePixelBuffer(NULL, g_pool, &ring[i]); fill(ring[i]); }
    [g_info appendString:@"capture: synthetic IOSurface frames (8-frame ring)\n"];
    dispatch_queue_t q = dispatch_queue_create("s7.synth", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    g_tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, q);
    __block int n = 0;
    dispatch_source_set_timer(g_tick, DISPATCH_TIME_NOW, NSEC_PER_SEC / g_cfg->fps, 0);
    dispatch_source_set_event_handler(g_tick, ^{
        uint64_t now = mach_absolute_time();
        encode(ring[n++ % RING], now, 0);
    });
    dispatch_resume(g_tick);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)g_cfg->seconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        atomic_store(&g_stopping, 1);
        dispatch_source_cancel(g_tick);
        finish(0);
    });
}

// ---------- decode verification ----------
static uint64_t *g_hash; static int *g_dst;
static void dec_cb(void *r, void *frr, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
    int i = (int)(intptr_t)frr; g_dst[i] = st; g_hash[i] = 0;
    if (!img) return;
    CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(img, 0); size_t ys = CVPixelBufferGetBytesPerRowOfPlane(img, 0);
    size_t h = CVPixelBufferGetHeightOfPlane(img, 0), w = CVPixelBufferGetWidthOfPlane(img, 0);
    uint64_t hv = 1469598103934665603ull;
    for (size_t j = 0; j < h; j++) for (size_t x = 0; x < w; x += 4) { hv ^= y[j * ys + x]; hv *= 1099511628211ull; }
    CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    g_hash[i] = hv;
}
static int decode_all(int n, int lossy, uint64_t *hash, int *st) {
    int first = -1;
    for (int i = 0; i < n; i++) if (g_sbs[i]) { first = i; break; }
    if (first < 0) return -1;
    g_hash = hash; g_dst = st;
    VTDecompressionOutputCallbackRecord r = {dec_cb, NULL};
    VTDecompressionSessionRef d;
    OSStatus e = VTDecompressionSessionCreate(NULL, CMSampleBufferGetFormatDescription(g_sbs[first]), NULL,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}, &r, &d);
    if (e) return e;
    for (int i = 0; i < n; i++) {
        st[i] = -1; hash[i] = 0;
        if (!g_sbs[i] || (lossy && g_dropped(i))) continue;
        VTDecodeInfoFlags fl;
        e = VTDecompressionSessionDecodeFrame(d, g_sbs[i], 0, (void *)(intptr_t)i, &fl);
        if (e) st[i] = e;
        VTDecompressionSessionWaitForAsynchronousFrames(d);
    }
    VTDecompressionSessionInvalidate(d); CFRelease(d);
    return 0;
}
static void verify_ltr(int n) {
    uint64_t *ha = calloc(n, 8), *hb = calloc(n, 8); int *sa = calloc(n, sizeof(int)), *sb = calloc(n, sizeof(int));
    if (decode_all(n, 0, ha, sa) || decode_all(n, 1, hb, sb)) { [g_info appendString:@"LTR verify: decoder setup failed\n"]; return; }
    int syncs = 0, toks = 0, fullerr = 0;
    for (int i = 1; i < n; i++) { if (g_out[i].done && g_out[i].keyframe) syncs++; if (g_out[i].ltr_token) toks++; if (g_sbs[i] && sa[i]) fullerr++; }
    [g_info appendFormat:@"LTR: loss every %d frames, %d lost, ack delay %d; %d frames with tokens, %d sync frames after frame 0, %d full-stream decode errors\n",
        g_ltr_every, g_ltr_len, g_ltr_ack, toks, syncs, fullerr];
    int events = 0, ok = 0;
    for (int a = g_ltr_every; a + g_ltr_len + g_ltr_ack < n; a += g_ltr_every) {
        int rf = a + g_ltr_len + g_ltr_ack, end = a + g_ltr_every < n ? a + g_ltr_every : n;
        int pre_ok = 1, mism = 0, derr = 0, first_bad = -1;
        for (int i = (a - 60 > 0 ? a - 60 : 0); i < a; i++) if (g_sbs[i] && ha[i] != hb[i]) pre_ok = 0;
        for (int i = rf; i < end; i++) {
            if (!g_sbs[i]) { mism++; if (first_bad < 0) first_bad = i; continue; }
            if (sb[i]) derr++;
            if (ha[i] != hb[i] || sb[i]) { mism++; if (first_bad < 0) first_bad = i; }
        }
        double mp = 0; int np = 0;
        for (int i = a - 60; i < a; i++) if (i > 0 && g_out[i].done) { mp += g_out[i].bytes; np++; }
        probe_sample *r = &g_out[rf];
        int good = r->done && pre_ok && mism == 0 && !r->keyframe;
        events++; ok += good;
        [g_info appendFormat:@"  loss %d-%d refresh@%d: %s %.1f KB (mean P %.1f KB) encode %.2f ms | bit-exact after refresh: %s (%d mismatches, %d decode errors, first bad %d)\n",
            a, a + g_ltr_len - 1, rf, r->keyframe ? "IDR" : "P", r->bytes / 1024.0, np ? mp / np / 1024.0 : 0, r->encode_ms,
            mism == 0 ? "yes" : "NO", mism, derr, first_bad];
    }
    [g_info appendFormat:@"LTR RESULT: %d/%d loss events recovered bit-exact with a non-IDR refresh\n", ok, events];
    free(ha); free(hb); free(sa); free(sb);
}

int probe_run(const probe_config *cfg, probe_sample *out, int max, int *count, char *info, int infolen) {
    @autoreleasepool {
        mach_timebase_info(&g_tb);
        g_cfg = cfg; g_out = out; g_max = max; atomic_store(&g_next, 0); g_rc = 0;
        memset(out, 0, sizeof(*out) * max);
        g_ltr = getenv("S7_LTR") && atoi(getenv("S7_LTR"));
        if (getenv("S7_LTR_EVERY")) g_ltr_every = atoi(getenv("S7_LTR_EVERY"));
        if (getenv("S7_LTR_LEN")) g_ltr_len = atoi(getenv("S7_LTR_LEN"));
        if (getenv("S7_LTR_ACK")) g_ltr_ack = atoi(getenv("S7_LTR_ACK"));
        g_ack_cursor = 0;
        if (g_ltr) { g_sbs = calloc(max, sizeof *g_sbs); g_tok = calloc(max, sizeof *g_tok); g_tokstate = calloc(max, 1); }
        g_info = [NSMutableString string];
        [g_info appendFormat:@"encoder: %s, low-latency rate control %s\n", cfg->codec ? "HEVC" : "H.264", cfg->low_latency ? "on" : "off"];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (setup_vt() != 0) { g_rc = -1; goto done; }
        if (cfg->show_window || cfg->source == 2) make_window();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (cfg->source == 0) start_synthetic(); else start_sck();
        });
        [NSApp run];
        VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
        [g_timer invalidate];
        [g_win close];
        if (g_ltr) verify_ltr(atomic_load(&g_next) < max ? atomic_load(&g_next) : max);
    done:
        if (g_vt) { VTCompressionSessionInvalidate(g_vt); CFRelease(g_vt); g_vt = NULL; }
        int n = atomic_load(&g_next);
        *count = n < max ? n : max;
        if (g_ltr) { for (int i = 0; i < max; i++) if (g_sbs[i]) CFRelease(g_sbs[i]); free(g_sbs); free(g_tok); free((void *)g_tokstate); }
        snprintf(info, infolen, "%s", g_info.UTF8String);
        return g_rc;
    }
}
