// Screen capture with ScreenCaptureKit.
//
// SCK calls the sample handler on our serial queue, one CMSampleBuffer per frame. The
// handler keeps only the newest complete frame in a one-slot mailbox; `acquire` takes it
// (waiting on a condition variable up to the caller's timeout). So a consumer that falls
// behind never sees a backlog: older frames are replaced, counted, and their surfaces go
// back to SCK's pool at once.
//
// Timestamps. SCStreamFrameInfoDisplayTime is mach_absolute_time of the vsync the frame
// belongs to. S7 found it is often a few ms *after* the handler runs, so captured_us is
// min(display time, arrival): never in the future. Frames whose display time is not
// after the last one's (out of order) are dropped as stale; frames that arrive more than
// two frame intervals after their display time are late and still delivered, since a late
// frame is still the newest picture we have.
//
// Damage. Complete frames carry SCStreamFrameInfoDirtyRects, in points of the display.
// The handler unites them over the frames the mailbox replaces, so an acquired frame's
// rects cover everything since the previous acquire; a frame without the attachment, a
// stale frame dropped or a blank/suspended status in between makes it unknown. Idle
// frames change nothing. host.zig scales points to frame pixels (damage.zig).
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <math.h>
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include "mh_internal.h"

static void init_window_server(void) {
    // SCK aborts in some command-line processes (CGS_REQUIRE_INIT) unless the window
    // server connection exists; AppKit sets it up.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([NSThread isMainThread]) [NSApplication sharedApplication];
        (void)CGMainDisplayID();
    });
}

int mh_sc_fail(NSError *err, const char *what) {
    int code = MH_ERR;
    if (err && [err.domain isEqualToString:SCStreamErrorDomain] && err.code == SCStreamErrorUserDeclined) code = MH_ERR_PERMISSION;
    if (!CGPreflightScreenCaptureAccess()) code = MH_ERR_PERMISSION;
    return mh_fail(code, "%s: %s", what, err ? err.description.UTF8String : "timed out");
}

// What ScreenCaptureKit can capture now, fetched synchronously (up to 5 s).
static SCShareableContent *sc_content(BOOL exclude_desktop, int *rc) {
    init_window_server();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *error = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:exclude_desktop
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *c, NSError *e) {
                                                     content = c;
                                                     error = e;
                                                     dispatch_semaphore_signal(done);
                                                 }];
    if (MH_WAIT(done, 5000) != 0 || !content) {
        *rc = mh_sc_fail(error, "SCShareableContent");
        return nil;
    }
    return content;
}

SCDisplay *mh_sc_display(uint32_t index, int *rc) {
    CGDirectDisplayID want = mh_display_id(index);
    if (!want) {
        *rc = mh_fail(MH_ERR_UNSUPPORTED, "no display %u", index);
        return nil;
    }
    SCShareableContent *content = sc_content(NO, rc);
    if (!content) return nil;
    for (SCDisplay *d in content.displays)
        if (d.displayID == want) return d;
    *rc = mh_fail(MH_ERR_UNSUPPORTED, "display %u (id %u) not in shareable content", index, want);
    return nil;
}

static SCWindow *sc_window(uint32_t id, int *rc) {
    SCShareableContent *content = sc_content(YES, rc);
    if (!content) return nil;
    for (SCWindow *w in content.windows)
        if (w.windowID == id) return w;
    *rc = mh_fail(MH_ERR_UNSUPPORTED, "window %u is not shareable (gone, minimized or off screen)", id);
    return nil;
}

static void copy_utf8(char *dst, size_t cap, NSString *s) {
    dst[0] = 0;
    if (!s || ![s getCString:dst maxLength:cap encoding:NSUTF8StringEncoding]) {
        // Too long: cut at a character boundary that fits.
        if (!s) return;
        NSUInteger n = s.length;
        while (n > 0) {
            n = [s rangeOfComposedCharacterSequenceAtIndex:n - 1].location;
            if ([[s substringToIndex:n] getCString:dst maxLength:cap encoding:NSUTF8StringEncoding]) return;
        }
        dst[0] = 0;
    }
}

int mh_windows(mh_window_info *out, uint32_t cap, uint32_t *count) {
    @autoreleasepool {
        mh_clear_error();
        *count = 0;
        int rc = MH_OK;
        SCShareableContent *content = sc_content(YES, &rc);
        if (!content) return rc;
        pid_t self = getpid();
        uint32_t n = 0;
        for (SCWindow *w in content.windows) {
            SCRunningApplication *app = w.owningApplication;
            // Normal windows of other apps, big enough to be one (not a status item or a
            // tooltip).
            if (!app || app.processID == self || w.windowLayer != 0) continue;
            if (w.frame.size.width < 40 || w.frame.size.height < 40) continue;
            if (n < cap) {
                mh_window_info *o = &out[n];
                memset(o, 0, sizeof *o);
                o->id = w.windowID;
                o->pid = (uint32_t)app.processID;
                o->x = (int32_t)lround(w.frame.origin.x);
                o->y = (int32_t)lround(w.frame.origin.y);
                o->width = (uint32_t)lround(w.frame.size.width);
                o->height = (uint32_t)lround(w.frame.size.height);
                o->on_screen = w.onScreen ? 1 : 0;
                copy_utf8(o->app, sizeof o->app, app.applicationName);
                copy_utf8(o->title, sizeof o->title, w.title);
            }
            n++;
        }
        *count = n;
        return MH_OK;
    }
}

struct mh_capture;

@interface MHVideoOut : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, assign) struct mh_capture *cap;
@end

struct mh_capture {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    // Retained Objective-C objects, held as CF references (plain C struct).
    void *stream;  // SCStream
    void *out;     // MHVideoOut
    void *queue;   // dispatch_queue_t
    void *filter;  // SCContentFilter
    void *config;  // SCStreamConfiguration
    mh_capture_config cfg;
    uint32_t width, height;
    int64_t interval_us;
    // Mailbox (under mu).
    CVPixelBufferRef pending;
    uint64_t pending_seq;
    int64_t pending_captured_us, pending_arrived_us;
    int64_t last_display_us;
    // Dirty rects since the last acquire (points); acc_known 0: unknown.
    mh_rectf acc[MH_DIRTY_MAX];
    uint32_t acc_n;
    int acc_known;
    // The acquired frame's copy (until the next acquire).
    mh_rectf out_dirty[MH_DIRTY_MAX];
    double src_w, src_h;
    uint64_t seq;
    mh_capture_stats stats;
    int stopped;     // the stream stopped with an error
    char err[256];
};

static void dirty_add(mh_rectf *list, uint32_t *n, mh_rectf r) {
    if (r.w <= 0 || r.h <= 0) return;
    if (*n < MH_DIRTY_MAX) {
        list[(*n)++] = r;
        return;
    }
    mh_rectf *l = &list[MH_DIRTY_MAX - 1];
    double x1 = fmax(l->x + l->w, r.x + r.w), y1 = fmax(l->y + l->h, r.y + r.h);
    l->x = fmin(l->x, r.x);
    l->y = fmin(l->y, r.y);
    l->w = x1 - l->x;
    l->h = y1 - l->y;
}

// `dirty` NULL: this frame's dirty rects are unknown.
static void push_frame(struct mh_capture *c, CVPixelBufferRef pb, int64_t display_us, int64_t arrived_us, const mh_rectf *dirty,
                       uint32_t n_dirty) {
    pthread_mutex_lock(&c->mu);
    c->stats.complete++;
    c->seq++;
    if (display_us <= c->last_display_us) {
        c->stats.stale++;
        c->acc_known = 0; // the next frame's rects are relative to this one, which we drop
        pthread_mutex_unlock(&c->mu);
        return;
    }
    if (!dirty) c->acc_known = 0;
    else if (c->acc_known)
        for (uint32_t i = 0; i < n_dirty; i++) dirty_add(c->acc, &c->acc_n, dirty[i]);
    c->last_display_us = display_us;
    int64_t late = arrived_us - display_us;
    if (late > 2 * c->interval_us) c->stats.late++;
    if (late > c->stats.max_late_us) c->stats.max_late_us = late;
    if (c->pending) {
        CVPixelBufferRelease(c->pending);
        c->stats.replaced++;
    }
    c->pending = CVPixelBufferRetain(pb);
    c->pending_seq = c->seq;
    c->pending_captured_us = display_us < arrived_us ? display_us : arrived_us;
    c->pending_arrived_us = arrived_us;
    pthread_cond_signal(&c->cv);
    pthread_mutex_unlock(&c->mu);
}

@implementation MHVideoOut
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    int64_t arrived = mh_now_us();
    struct mh_capture *c = self.cap;
    if (!c || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb)) return;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!att || CFArrayGetCount(att) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(att, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) {
        pthread_mutex_lock(&c->mu);
        c->stats.idle++;
        // Idle: the same picture. Anything else (blank, suspended, started, stopped):
        // we cannot say what the next complete frame changed.
        if (!status || status.integerValue != SCFrameStatusIdle) c->acc_known = 0;
        pthread_mutex_unlock(&c->mu);
        return;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    NSNumber *disp = info[SCStreamFrameInfoDisplayTime];
    int64_t display_us = disp ? mh_ticks_to_us(disp.unsignedLongLongValue) : arrived;
    mh_rectf dirty[MH_DIRTY_MAX];
    uint32_t n_dirty = 0;
    int known = 0;
    id rects = info[SCStreamFrameInfoDirtyRects];
    if ([rects isKindOfClass:[NSArray class]]) {
        known = 1;
        for (id d in (NSArray *)rects) {
            CGRect r;
            if (![d isKindOfClass:[NSDictionary class]] || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d, &r)) {
                known = 0;
                break;
            }
            r = CGRectStandardize(r);
            dirty_add(dirty, &n_dirty, (mh_rectf){r.origin.x, r.origin.y, r.size.width, r.size.height});
        }
    }
    push_frame(c, pb, display_us, arrived, known ? dirty : NULL, n_dirty);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    struct mh_capture *c = self.cap;
    if (!c) return;
    pthread_mutex_lock(&c->mu);
    c->stopped = 1;
    snprintf(c->err, sizeof c->err, "stream stopped: %s", error.description.UTF8String);
    pthread_cond_broadcast(&c->cv);
    pthread_mutex_unlock(&c->mu);
}
@end

int mh_capture_create(mh_capture **out) {
    struct mh_capture *c = calloc(1, sizeof *c);
    if (!c) return mh_fail(MH_ERR_NOMEM, "out of memory");
    pthread_mutex_init(&c->mu, NULL);
    pthread_cond_init(&c->cv, NULL);
    *out = c;
    return MH_OK;
}

static SCStreamConfiguration *make_config(const mh_capture_config *cfg, uint32_t w, uint32_t h) {
    SCStreamConfiguration *sc = [SCStreamConfiguration new];
    sc.width = w;
    sc.height = h;
    sc.minimumFrameInterval = CMTimeMake(1, (int32_t)(cfg->fps ? cfg->fps : 60));
    sc.pixelFormat = mh_fmt_to_cv(cfg->format);
    uint32_t qd = cfg->queue_depth ? cfg->queue_depth : 6;
    sc.queueDepth = qd < 3 ? 3 : qd > 8 ? 8 : qd;
    sc.showsCursor = cfg->cursor ? YES : NO;
    sc.capturesAudio = NO;
    sc.scalesToFit = YES;
    if (cfg->format == MH_FMT_NV12) {
        sc.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;
        sc.colorSpaceName = kCGColorSpaceITUR_709;
    }
    return sc;
}

int mh_capture_start(mh_capture *c, const mh_capture_config *cfg, uint32_t *width, uint32_t *height) {
    @autoreleasepool {
        mh_clear_error();
        mh_capture_stop(c);
        int rc = MH_OK;
        uint32_t w = cfg->width, h = cfg->height;
        SCContentFilter *filter = nil;
        if (cfg->window) {
            // One window, wherever it is and whatever covers it.
            SCWindow *window = sc_window(cfg->window, &rc);
            if (!window) return rc;
            if (!w || !h) {
                rc = mh_window_pixels(cfg->window, &w, &h);
                if (rc != MH_OK) return rc;
            }
            filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
        } else {
            SCDisplay *display = mh_sc_display(cfg->display, &rc);
            if (!display) return rc;
            if (!w || !h) {
                rc = mh_display_pixels(cfg->display, &w, &h);
                if (rc != MH_OK) return rc;
            }
            filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        }
        w &= ~1u; // even sizes for 4:2:0
        h &= ~1u;
        SCStreamConfiguration *sc = make_config(cfg, w, h);
        MHVideoOut *o = [MHVideoOut new];
        o.cap = c;
        dispatch_queue_t q = dispatch_queue_create(
            "moonsec.capture", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:sc delegate:o];
        NSError *err = nil;
        if (![stream addStreamOutput:o type:SCStreamOutputTypeScreen sampleHandlerQueue:q error:&err])
            return mh_sc_fail(err, "addStreamOutput");

        pthread_mutex_lock(&c->mu);
        c->cfg = *cfg;
        c->width = w;
        c->height = h;
        c->interval_us = 1000000 / (cfg->fps ? cfg->fps : 60);
        c->stopped = 0;
        c->err[0] = 0;
        c->last_display_us = INT64_MIN;
        c->acc_known = 0;
        c->acc_n = 0;
        c->src_w = c->src_h = 0;
        if (!cfg->window) {
            // Dirty rects are in the display's points.
            CGRect b = CGDisplayBounds(mh_display_id(cfg->display));
            c->src_w = b.size.width;
            c->src_h = b.size.height;
        }
        memset(&c->stats, 0, sizeof c->stats);
        pthread_mutex_unlock(&c->mu);

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *start_err = nil;
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
            start_err = e;
            dispatch_semaphore_signal(done);
        }];
        if (MH_WAIT(done, 5000) != 0 || start_err) {
            o.cap = NULL;
            return mh_sc_fail(start_err, "startCapture");
        }
        c->stream = (void *)CFBridgingRetain(stream);
        c->out = (void *)CFBridgingRetain(o);
        c->queue = (void *)CFBridgingRetain(q);
        c->filter = (void *)CFBridgingRetain(filter);
        c->config = (void *)CFBridgingRetain(sc);
        *width = w;
        *height = h;
        return MH_OK;
    }
}

int mh_capture_acquire(mh_capture *c, int64_t timeout_us, mh_frame *out) {
    int64_t deadline = mh_now_us() + (timeout_us > 0 ? timeout_us : 0);
    pthread_mutex_lock(&c->mu);
    for (;;) {
        if (c->pending) break;
        if (c->stopped) {
            int rc = mh_fail(MH_ERR_DEVICE_LOST, "%s", c->err);
            pthread_mutex_unlock(&c->mu);
            return rc;
        }
        if (!c->stream) {
            pthread_mutex_unlock(&c->mu);
            return mh_fail(MH_ERR_CLOSED, "capture not started");
        }
        int64_t left = deadline - mh_now_us();
        if (left <= 0) break;
        struct timespec ts = {.tv_sec = left / 1000000, .tv_nsec = (left % 1000000) * 1000};
        pthread_cond_timedwait_relative_np(&c->cv, &c->mu, &ts);
    }
    if (!c->pending) {
        pthread_mutex_unlock(&c->mu);
        return MH_TIMEOUT;
    }
    CVPixelBufferRef pb = c->pending;
    c->pending = NULL;
    out->pixel_buffer = pb; // the mailbox's reference moves to the caller
    out->width = (uint32_t)CVPixelBufferGetWidth(pb);
    out->height = (uint32_t)CVPixelBufferGetHeight(pb);
    out->format = mh_cv_to_fmt(CVPixelBufferGetPixelFormatType(pb));
    out->seq = c->pending_seq;
    out->captured_us = c->pending_captured_us;
    out->arrived_us = c->pending_arrived_us;
    out->dirty = NULL;
    out->n_dirty = 0;
    if (c->acc_known) {
        memcpy(c->out_dirty, c->acc, c->acc_n * sizeof c->acc[0]);
        out->dirty = c->out_dirty;
        out->n_dirty = c->acc_n;
    }
    out->src_w = c->src_w;
    out->src_h = c->src_h;
    c->acc_known = 1;
    c->acc_n = 0;
    pthread_mutex_unlock(&c->mu);
    return MH_OK;
}

int mh_frame_read_rect(void *pixel_buffer, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t *out, uint32_t out_stride) {
    CVPixelBufferRef pb = (CVPixelBufferRef)pixel_buffer;
    if (!pb) return mh_fail(MH_ERR, "read_rect: no pixel buffer");
    if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) return MH_ERR_UNSUPPORTED;
    size_t pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb);
    if (w == 0 || h == 0 || x > pw || y > ph || w > pw - x || h > ph - y || out_stride < w * 4)
        return mh_fail(MH_ERR, "read_rect: %ux%u at %u,%u is not inside the %zux%zu frame", w, h, x, y, pw, ph);
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return mh_fail(MH_ERR, "read_rect: lock failed");
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    if (base)
        for (uint32_t r = 0; r < h; r++) memcpy(out + (size_t)r * out_stride, base + (size_t)(y + r) * bpr + (size_t)x * 4, (size_t)w * 4);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return base ? MH_OK : mh_fail(MH_ERR, "read_rect: no base address");
}

int mh_capture_update(mh_capture *c, uint32_t width, uint32_t height, uint32_t fps) {
    @autoreleasepool {
        if (!c->stream) return mh_fail(MH_ERR_CLOSED, "capture not started");
        SCStream *stream = (__bridge SCStream *)c->stream;
        mh_capture_config cfg = c->cfg;
        if (fps) cfg.fps = fps;
        uint32_t w = (width ? width : c->width) & ~1u, h = (height ? height : c->height) & ~1u;
        SCStreamConfiguration *sc = make_config(&cfg, w, h);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *err = nil;
        [stream updateConfiguration:sc
                  completionHandler:^(NSError *e) {
                      err = e;
                      dispatch_semaphore_signal(done);
                  }];
        if (MH_WAIT(done, 5000) != 0 || err) return mh_sc_fail(err, "updateConfiguration");
        pthread_mutex_lock(&c->mu);
        c->cfg = cfg;
        c->width = w;
        c->height = h;
        c->interval_us = 1000000 / (cfg.fps ? cfg.fps : 60);
        c->acc_known = 0; // frames of the new size start over
        pthread_mutex_unlock(&c->mu);
        mh_cf_release(c->config);
        c->config = (void *)CFBridgingRetain(sc);
        return MH_OK;
    }
}

void mh_capture_get_stats(mh_capture *c, mh_capture_stats *out) {
    pthread_mutex_lock(&c->mu);
    *out = c->stats;
    pthread_mutex_unlock(&c->mu);
}

void mh_capture_stop(mh_capture *c) {
    @autoreleasepool {
        if (c->stream) {
            SCStream *stream = (__bridge SCStream *)c->stream;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [stream stopCaptureWithCompletionHandler:^(NSError *e) { dispatch_semaphore_signal(done); }];
            MH_WAIT(done, 2000);
            // Let a handler already running finish before the output forgets us.
            dispatch_sync((__bridge dispatch_queue_t)c->queue, ^{});
            ((__bridge MHVideoOut *)c->out).cap = NULL;
        }
        mh_cf_release(c->stream);
        mh_cf_release(c->out);
        mh_cf_release(c->queue);
        mh_cf_release(c->filter);
        mh_cf_release(c->config);
        c->stream = c->out = c->queue = c->filter = c->config = NULL;
        pthread_mutex_lock(&c->mu);
        if (c->pending) CVPixelBufferRelease(c->pending);
        c->pending = NULL;
        c->stopped = 0;
        pthread_mutex_unlock(&c->mu);
    }
}

void mh_capture_destroy(mh_capture *c) {
    if (!c) return;
    mh_capture_stop(c);
    pthread_cond_destroy(&c->cv);
    pthread_mutex_destroy(&c->mu);
    free(c);
}
