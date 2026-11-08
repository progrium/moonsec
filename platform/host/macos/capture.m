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
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <pthread.h>
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

SCDisplay *mh_sc_display(uint32_t index, int *rc) {
    init_window_server();
    CGDirectDisplayID want = mh_display_id(index);
    if (!want) {
        *rc = mh_fail(MH_ERR_UNSUPPORTED, "no display %u", index);
        return nil;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *error = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
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
    for (SCDisplay *d in content.displays)
        if (d.displayID == want) return d;
    *rc = mh_fail(MH_ERR_UNSUPPORTED, "display %u (id %u) not in shareable content", index, want);
    return nil;
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
    uint64_t seq;
    mh_capture_stats stats;
    int stopped;     // the stream stopped with an error
    char err[256];
};

static void push_frame(struct mh_capture *c, CVPixelBufferRef pb, int64_t display_us, int64_t arrived_us) {
    pthread_mutex_lock(&c->mu);
    c->stats.complete++;
    c->seq++;
    if (display_us <= c->last_display_us) {
        c->stats.stale++;
        pthread_mutex_unlock(&c->mu);
        return;
    }
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
        pthread_mutex_unlock(&c->mu);
        return;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    NSNumber *disp = info[SCStreamFrameInfoDisplayTime];
    int64_t display_us = disp ? mh_ticks_to_us(disp.unsignedLongLongValue) : arrived;
    push_frame(c, pb, display_us, arrived);
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
        SCDisplay *display = mh_sc_display(cfg->display, &rc);
        if (!display) return rc;
        uint32_t w = cfg->width, h = cfg->height;
        if (!w || !h) {
            rc = mh_display_pixels(cfg->display, &w, &h);
            if (rc != MH_OK) return rc;
        }
        w &= ~1u; // even sizes for 4:2:0
        h &= ~1u;
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
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
    pthread_mutex_unlock(&c->mu);
    return MH_OK;
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
