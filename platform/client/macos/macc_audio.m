// moonsec macOS client: CoreAudio output (macc.h).
//
// An AUHAL default-output unit takes 32-bit float interleaved at the session's rate
// and channel count (the unit converts to the device's format). The render callback
// drains a single-producer, single-consumer ring the audio thread writes into; it
// never blocks and fills with silence when the ring runs dry. The device is asked for
// a small I/O buffer (5 ms, clamped to what it allows).

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdlib.h>

#include "macc.h"

struct macc_audio {
    AudioUnit unit;
    AudioDeviceID device;
    uint32_t channels;
    uint32_t cap; // frames, power of two
    float *ring;  // cap * channels
    _Atomic uint64_t wpos, rpos; // frames written and read, ever
    _Atomic uint64_t underrun;
    uint32_t io_frames;
    uint32_t latency_frames;
};

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)ts;
    (void)bus;
    macc_audio *a = ref;
    float *dst = io->mBuffers[0].mData;
    uint64_t r = atomic_load_explicit(&a->rpos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&a->wpos, memory_order_acquire);
    uint64_t avail = w - r;
    uint32_t n = avail < frames ? (uint32_t)avail : frames;
    for (uint32_t i = 0; i < n; i++) {
        const float *src = a->ring + ((r + i) & (a->cap - 1)) * a->channels;
        for (uint32_t c = 0; c < a->channels; c++) dst[i * a->channels + c] = src[c];
    }
    if (n < frames) {
        memset(dst + (size_t)n * a->channels, 0, (size_t)(frames - n) * a->channels * sizeof(float));
        if (w > 0) atomic_fetch_add_explicit(&a->underrun, frames - n, memory_order_relaxed);
        if (n == 0) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    atomic_store_explicit(&a->rpos, r + n, memory_order_release);
    return noErr;
}

static OSStatus get_prop(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope,
                         UInt32 size, void *out) {
    AudioObjectPropertyAddress addr = {sel, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(obj, &addr, 0, NULL, &size, out);
}

macc_status macc_audio_open(uint32_t rate, uint32_t channels, uint32_t ring_frames, macc_audio **out) {
    *out = NULL;
    if (channels == 0 || channels > 8 || rate == 0) return MACC_E_INVALID;
    AudioDeviceID dev = kAudioObjectUnknown;
    OSStatus st =
        get_prop(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                 sizeof dev, &dev);
    if (st != noErr || dev == kAudioObjectUnknown) return MACC_E_NO_DEVICE;

    uint32_t cap = 1;
    uint32_t want = ring_frames ? ring_frames : 1024;
    while (cap < want) cap <<= 1;

    macc_audio *a = calloc(1, sizeof *a);
    if (!a) return MACC_E_INVALID;
    a->device = dev;
    a->channels = channels;
    a->cap = cap;
    a->ring = calloc((size_t)cap * channels, sizeof(float));
    if (!a->ring) {
        free(a);
        return MACC_E_INVALID;
    }

    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                      kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        st = MACC_E_NO_DEVICE;
        goto fail;
    }
    st = AudioComponentInstanceNew(comp, &a->unit);
    if (st != noErr) goto fail;

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = channels;
    fmt.mBitsPerChannel = 32;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = 4 * channels;
    fmt.mBytesPerPacket = 4 * channels;
    st = AudioUnitSetProperty(a->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    if (st != noErr) goto fail;
    AURenderCallbackStruct cb = {render, a};
    st = AudioUnitSetProperty(a->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                              sizeof cb);
    if (st != noErr) goto fail;

    // A small device I/O buffer: 5 ms at the device's rate, within its range.
    Float64 dev_rate = 0;
    get_prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof dev_rate, &dev_rate);
    if (dev_rate <= 0) dev_rate = rate;
    AudioValueRange range = {0, 0};
    get_prop(dev, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, sizeof range, &range);
    UInt32 io = (UInt32)(dev_rate * 0.005);
    if (range.mMinimum > 0 && io < range.mMinimum) io = (UInt32)range.mMinimum;
    if (range.mMaximum > 0 && io > range.mMaximum) io = (UInt32)range.mMaximum;
    AudioObjectPropertyAddress bsz = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                                      kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(dev, &bsz, 0, NULL, sizeof io, &io); // best effort
    UInt32 got_io = 0;
    get_prop(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, sizeof got_io, &got_io);
    a->io_frames = got_io;
    UInt32 lat = 0, safety = 0;
    get_prop(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, sizeof lat, &lat);
    get_prop(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, sizeof safety, &safety);
    a->latency_frames = lat + safety;

    st = AudioUnitInitialize(a->unit);
    if (st != noErr) goto fail;
    st = AudioOutputUnitStart(a->unit);
    if (st != noErr) {
        AudioUnitUninitialize(a->unit);
        goto fail;
    }
    *out = a;
    return MACC_OK;

fail:
    if (a->unit) AudioComponentInstanceDispose(a->unit);
    free(a->ring);
    free(a);
    return st;
}

void macc_audio_close(macc_audio *a) {
    if (!a) return;
    AudioOutputUnitStop(a->unit);
    AudioUnitUninitialize(a->unit);
    AudioComponentInstanceDispose(a->unit);
    free(a->ring);
    free(a);
}

macc_status macc_audio_write(macc_audio *a, const float *pcm, uint32_t frames, uint32_t *written) {
    uint64_t w = atomic_load_explicit(&a->wpos, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&a->rpos, memory_order_acquire);
    uint64_t space = a->cap - (w - r);
    uint32_t n = space < frames ? (uint32_t)space : frames;
    for (uint32_t i = 0; i < n; i++) {
        float *dst = a->ring + ((w + i) & (a->cap - 1)) * a->channels;
        for (uint32_t c = 0; c < a->channels; c++) dst[c] = pcm[(size_t)i * a->channels + c];
    }
    atomic_store_explicit(&a->wpos, w + n, memory_order_release);
    *written = n;
    return MACC_OK;
}

uint32_t macc_audio_queued(macc_audio *a) {
    uint64_t w = atomic_load_explicit(&a->wpos, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&a->rpos, memory_order_acquire);
    return (uint32_t)(w - r);
}

void macc_audio_info(macc_audio *a, uint32_t *ring_frames, uint32_t *io_frames, uint32_t *device_latency_frames) {
    *ring_frames = a->cap;
    *io_frames = a->io_frames;
    *device_latency_frames = a->latency_frames;
}

uint64_t macc_audio_underrun_frames(macc_audio *a) {
    return atomic_load_explicit(&a->underrun, memory_order_relaxed);
}
