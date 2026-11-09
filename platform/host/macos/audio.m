// System audio capture with ScreenCaptureKit (macOS 13+).
//
// SCK only streams audio as part of a display stream, so this opens its own SCStream on
// the display with a tiny, slow video configuration and only an audio output. The
// handler converts each buffer (f32, usually non-interleaved) to interleaved f32 in a
// one-second ring; `read` copies out of it. The ring tracks the clock time of its oldest
// frame from the sample buffers' presentation times (host time clock, mach ticks), so a
// read reports when its first frame was captured. When the reader falls behind by more
// than the ring, the oldest audio is dropped and counted.
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <pthread.h>
#include <stdlib.h>
#include "mh_internal.h"

#define RING_FRAMES 48000

struct mh_audio;

@interface MHAudioOut : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, assign) struct mh_audio *audio;
@end

struct mh_audio {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    void *stream, *out, *queue;
    uint32_t channels;
    float *ring; // RING_FRAMES * channels
    size_t head, count; // in frames
    int64_t head_time_us; // clock time of the frame at `head`
    uint64_t overruns;
    int stopped;
    char err[256];
    float *scratch;
    size_t scratch_frames;
};

static void push_audio(struct mh_audio *a, const float *pcm, size_t frames, int64_t time_us) {
    pthread_mutex_lock(&a->mu);
    const size_t ch = a->channels;
    if (frames > RING_FRAMES) {
        a->overruns += frames - RING_FRAMES;
        pcm += (frames - RING_FRAMES) * ch;
        time_us += (int64_t)(frames - RING_FRAMES) * 1000000 / 48000;
        frames = RING_FRAMES;
    }
    if (a->count + frames > RING_FRAMES) {
        size_t drop = a->count + frames - RING_FRAMES;
        a->head = (a->head + drop) % RING_FRAMES;
        a->count -= drop;
        a->head_time_us += (int64_t)drop * 1000000 / 48000;
        a->overruns += drop;
    }
    // The ring's time follows the newest buffer when it was empty; otherwise it keeps
    // counting samples from the oldest, which is what a reader wants.
    if (a->count == 0) a->head_time_us = time_us;
    size_t tail = (a->head + a->count) % RING_FRAMES;
    for (size_t i = 0; i < frames;) {
        size_t n = RING_FRAMES - tail;
        if (n > frames - i) n = frames - i;
        memcpy(a->ring + tail * ch, pcm + i * ch, n * ch * sizeof(float));
        tail = (tail + n) % RING_FRAMES;
        i += n;
    }
    a->count += frames;
    pthread_cond_signal(&a->cv);
    pthread_mutex_unlock(&a->mu);
}

@implementation MHAudioOut
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    struct mh_audio *a = self.audio;
    if (!a || type != SCStreamOutputTypeAudio || !CMSampleBufferIsValid(sb)) return;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM || !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) || asbd->mBitsPerChannel != 32)
        return;
    size_t frames = (size_t)CMSampleBufferGetNumSamples(sb);
    if (frames == 0) return;
    // Room for a list of up to 8 buffers.
    struct {
        AudioBufferList list;
        AudioBuffer more[7];
    } abl;
    CMBlockBufferRef block = NULL;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, NULL, &abl.list, sizeof abl, NULL, NULL,
                                                                          kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
    if (st != noErr) return;
    const size_t out_ch = a->channels;
    const size_t src_ch = asbd->mChannelsPerFrame ? asbd->mChannelsPerFrame : 1;
    const int interleaved = !(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    if (a->scratch_frames < frames) {
        free(a->scratch);
        a->scratch = malloc(frames * out_ch * sizeof(float));
        a->scratch_frames = a->scratch ? frames : 0;
    }
    if (a->scratch) {
        for (size_t c = 0; c < out_ch; c++) {
            size_t sc = c < src_ch ? c : src_ch - 1; // mono source: copy to both
            const float *src;
            size_t step;
            if (interleaved) {
                src = (const float *)abl.list.mBuffers[0].mData + sc;
                step = src_ch;
            } else {
                if (sc >= abl.list.mNumberBuffers) sc = abl.list.mNumberBuffers - 1;
                src = (const float *)abl.list.mBuffers[sc].mData;
                step = 1;
            }
            for (size_t i = 0; i < frames; i++) a->scratch[i * out_ch + c] = src[i * step];
        }
        if (out_ch == 1 && src_ch >= 2) { // downmix
            for (size_t i = 0; i < frames; i++) {
                float l, r;
                if (interleaved) {
                    l = ((const float *)abl.list.mBuffers[0].mData)[i * src_ch];
                    r = ((const float *)abl.list.mBuffers[0].mData)[i * src_ch + 1];
                } else {
                    l = ((const float *)abl.list.mBuffers[0].mData)[i];
                    r = abl.list.mNumberBuffers > 1 ? ((const float *)abl.list.mBuffers[1].mData)[i] : l;
                }
                a->scratch[i] = 0.5f * (l + r);
            }
        }
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        int64_t t = CMTIME_IS_VALID(pts) ? mh_ticks_to_us(CMClockConvertHostTimeToSystemUnits(pts)) : mh_now_us();
        push_audio(a, a->scratch, frames, t);
    }
    CFRelease(block);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    struct mh_audio *a = self.audio;
    if (!a) return;
    pthread_mutex_lock(&a->mu);
    a->stopped = 1;
    snprintf(a->err, sizeof a->err, "audio stream stopped: %s", error.description.UTF8String);
    pthread_cond_broadcast(&a->cv);
    pthread_mutex_unlock(&a->mu);
}
@end

int mh_audio_create(mh_audio **out) {
    struct mh_audio *a = calloc(1, sizeof *a);
    if (!a) return mh_fail(MH_ERR_NOMEM, "out of memory");
    pthread_mutex_init(&a->mu, NULL);
    pthread_cond_init(&a->cv, NULL);
    *out = a;
    return MH_OK;
}

int mh_audio_start(mh_audio *a, uint32_t display_index, uint32_t channels) {
    @autoreleasepool {
        mh_clear_error();
        if (channels < 1 || channels > 2) return mh_fail(MH_ERR_UNSUPPORTED, "%u channels", channels);
        mh_audio_stop(a);
        int rc = MH_OK;
        SCDisplay *display = mh_sc_display(display_index, &rc);
        if (!display) return rc;
        float *ring = calloc((size_t)RING_FRAMES * channels, sizeof(float));
        if (!ring) return mh_fail(MH_ERR_NOMEM, "out of memory");
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        SCStreamConfiguration *sc = [SCStreamConfiguration new];
        sc.capturesAudio = YES;
        sc.sampleRate = 48000;
        sc.channelCount = (NSInteger)channels;
        sc.excludesCurrentProcessAudio = YES;
        // Video is required but unused: keep it as small and slow as SCK allows.
        sc.width = 2;
        sc.height = 2;
        sc.minimumFrameInterval = CMTimeMake(1, 1);
        sc.queueDepth = 3;
        MHAudioOut *o = [MHAudioOut new];
        o.audio = a;
        dispatch_queue_t q = dispatch_queue_create(
            "moonsec.audio", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:sc delegate:o];
        NSError *err = nil;
        if (![stream addStreamOutput:o type:SCStreamOutputTypeAudio sampleHandlerQueue:q error:&err]) {
            free(ring);
            return mh_sc_fail(err, "addStreamOutput(audio)");
        }
        pthread_mutex_lock(&a->mu);
        free(a->ring);
        a->ring = ring;
        a->channels = channels;
        a->head = a->count = 0;
        a->overruns = 0;
        a->stopped = 0;
        pthread_mutex_unlock(&a->mu);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *start_err = nil;
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
            start_err = e;
            dispatch_semaphore_signal(done);
        }];
        if (MH_WAIT(done, 5000) != 0 || start_err) {
            o.audio = NULL;
            return mh_sc_fail(start_err, "startCapture(audio)");
        }
        a->stream = (void *)CFBridgingRetain(stream);
        a->out = (void *)CFBridgingRetain(o);
        a->queue = (void *)CFBridgingRetain(q);
        return MH_OK;
    }
}

int mh_audio_read(mh_audio *a, float *out, uint32_t max_frames, int64_t timeout_us, uint32_t *frames, int64_t *time_us) {
    *frames = 0;
    *time_us = mh_now_us();
    int64_t deadline = *time_us + (timeout_us > 0 ? timeout_us : 0);
    pthread_mutex_lock(&a->mu);
    for (;;) {
        if (a->count > 0) break;
        if (a->stopped) {
            int rc = mh_fail(MH_ERR_DEVICE_LOST, "%s", a->err);
            pthread_mutex_unlock(&a->mu);
            return rc;
        }
        if (!a->stream) {
            pthread_mutex_unlock(&a->mu);
            return mh_fail(MH_ERR_CLOSED, "audio not started");
        }
        int64_t left = deadline - mh_now_us();
        if (left <= 0) break;
        struct timespec ts = {.tv_sec = left / 1000000, .tv_nsec = (left % 1000000) * 1000};
        pthread_cond_timedwait_relative_np(&a->cv, &a->mu, &ts);
    }
    if (a->count == 0) {
        pthread_mutex_unlock(&a->mu);
        return MH_TIMEOUT;
    }
    const size_t ch = a->channels;
    size_t n = a->count < max_frames ? a->count : max_frames;
    *time_us = a->head_time_us;
    for (size_t i = 0; i < n;) {
        size_t run = RING_FRAMES - a->head;
        if (run > n - i) run = n - i;
        memcpy(out + i * ch, a->ring + a->head * ch, run * ch * sizeof(float));
        a->head = (a->head + run) % RING_FRAMES;
        i += run;
    }
    a->count -= n;
    a->head_time_us += (int64_t)n * 1000000 / 48000;
    *frames = (uint32_t)n;
    pthread_mutex_unlock(&a->mu);
    return MH_OK;
}

uint64_t mh_audio_overruns(mh_audio *a) {
    pthread_mutex_lock(&a->mu);
    uint64_t n = a->overruns;
    pthread_mutex_unlock(&a->mu);
    return n;
}

void mh_audio_stop(mh_audio *a) {
    @autoreleasepool {
        if (a->stream) {
            SCStream *stream = (__bridge SCStream *)a->stream;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [stream stopCaptureWithCompletionHandler:^(NSError *e) { dispatch_semaphore_signal(done); }];
            MH_WAIT(done, 2000);
            dispatch_sync((__bridge dispatch_queue_t)a->queue, ^{});
            ((__bridge MHAudioOut *)a->out).audio = NULL;
        }
        mh_cf_release(a->stream);
        mh_cf_release(a->out);
        mh_cf_release(a->queue);
        a->stream = a->out = a->queue = NULL;
        pthread_mutex_lock(&a->mu);
        a->count = 0;
        a->stopped = 0;
        pthread_mutex_unlock(&a->mu);
    }
}

void mh_audio_destroy(mh_audio *a) {
    if (!a) return;
    mh_audio_stop(a);
    free(a->ring);
    free(a->scratch);
    pthread_cond_destroy(&a->cv);
    pthread_mutex_destroy(&a->mu);
    free(a);
}
