/* PipeWire playback (see mlc.h). The app's audio thread writes into a single-producer,
 * single-consumer ring; the stream's process callback, on PipeWire's own thread loop,
 * copies one graph quantum out of it per cycle and plays silence when it runs dry. */
#define _GNU_SOURCE
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

#include "mlc_internal.h"

struct mlc_audio {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    struct spa_hook listener;
    uint32_t rate;
    uint32_t channels;
    /* Ring of `cap` frames; head and tail count frames forever (mod 2^64). */
    float *ring;
    uint32_t cap;
    _Atomic uint64_t head; /* written */
    _Atomic uint64_t tail; /* played */
    _Atomic uint32_t quantum;
    _Atomic int streaming;
    _Atomic uint64_t underruns;
    /* Frames the graph still holds ahead of the device, from pw_stream_get_time_n. */
    _Atomic uint32_t graph_delay;
    int was_dry;
};

static void on_process(void *data) {
    struct mlc_audio *a = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(a->stream);
    if (!b) return;
    struct spa_buffer *buf = b->buffer;
    float *dst = buf->datas[0].data;
    if (!dst) {
        pw_stream_queue_buffer(a->stream, b);
        return;
    }
    uint32_t stride = (uint32_t)sizeof(float) * a->channels;
    uint32_t max = buf->datas[0].maxsize / stride;
    uint32_t want = max;
#if PW_CHECK_VERSION(0, 3, 49)
    if (b->requested && b->requested < want) want = (uint32_t)b->requested;
#endif
    atomic_store(&a->quantum, want);
    uint64_t head = atomic_load_explicit(&a->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&a->tail, memory_order_relaxed);
    uint32_t avail = (uint32_t)(head - tail);
    uint32_t n = avail < want ? avail : want;
    for (uint32_t i = 0; i < n;) {
        uint32_t pos = (uint32_t)((tail + i) % a->cap);
        uint32_t run = a->cap - pos;
        if (run > n - i) run = n - i;
        memcpy(dst + (size_t)i * a->channels, a->ring + (size_t)pos * a->channels, (size_t)run * stride);
        i += run;
    }
    if (n < want) {
        memset(dst + (size_t)n * a->channels, 0, (size_t)(want - n) * stride);
        /* Count each time it runs dry, not each dry cycle; silence before the first
         * write is not an underrun. */
        if (!a->was_dry && head > 0) atomic_fetch_add(&a->underruns, 1);
        a->was_dry = 1;
    } else {
        a->was_dry = 0;
    }
    atomic_store_explicit(&a->tail, tail + n, memory_order_release);
    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = (int32_t)stride;
    buf->datas[0].chunk->size = want * stride;
    pw_stream_queue_buffer(a->stream, b);

    struct pw_time t;
    if (pw_stream_get_time_n(a->stream, &t, sizeof t) == 0 && t.rate.denom > 0) {
        /* delay is in graph ticks at t.rate; convert to our frames. */
        int64_t d = t.delay * (int64_t)a->rate * t.rate.num / t.rate.denom;
        atomic_store(&a->graph_delay, d > 0 ? (uint32_t)d : 0);
    }
}

static void on_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    struct mlc_audio *a = data;
    atomic_store(&a->streaming, state == PW_STREAM_STATE_STREAMING);
    if (state == PW_STREAM_STATE_ERROR) mlc_log("PipeWire stream error: %s", error ? error : "?");
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state,
    .process = on_process,
};

static int pw_inited;

int mlc_audio_open(uint32_t rate, uint32_t channels, uint32_t ring_ms, uint32_t quantum, const char *name, mlc_audio **out) {
    *out = NULL;
    if (channels == 0 || channels > 8) return mlc_fail(MLC_E_UNSUPPORTED, "%u channels", channels);
    if (!pw_inited) {
        pw_init(NULL, NULL);
        pw_inited = 1;
    }
    struct mlc_audio *a = calloc(1, sizeof *a);
    if (!a) return MLC_E_NOMEM;
    a->rate = rate;
    a->channels = channels;
    a->cap = rate * (ring_ms ? ring_ms : 200) / 1000;
    a->ring = calloc((size_t)a->cap * channels, sizeof(float));
    if (!a->ring) {
        free(a);
        return MLC_E_NOMEM;
    }
    int rc = MLC_E_FAIL;
    a->loop = pw_thread_loop_new("moonsec-audio", NULL);
    if (!a->loop) goto fail;

    char latency[32];
    snprintf(latency, sizeof latency, "%u/%u", quantum ? quantum : 256, rate);
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback", PW_KEY_MEDIA_ROLE, "Game",
        PW_KEY_NODE_LATENCY, latency, PW_KEY_APP_NAME, "moonsec", NULL);
    a->stream = pw_stream_new_simple(pw_thread_loop_get_loop(a->loop), name ? name : "moonsec", props, &stream_events, a);
    if (!a->stream) {
        rc = mlc_fail(MLC_E_FAIL, "pw_stream_new_simple failed");
        goto fail;
    }
    uint8_t pod_buf[1024];
    struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
    struct spa_audio_info_raw info = {.format = SPA_AUDIO_FORMAT_F32, .rate = rate, .channels = channels};
    if (channels == 2) {
        info.position[0] = SPA_AUDIO_CHANNEL_FL;
        info.position[1] = SPA_AUDIO_CHANNEL_FR;
    } else if (channels == 1) {
        info.position[0] = SPA_AUDIO_CHANNEL_MONO;
    } else {
        info.flags |= SPA_AUDIO_FLAG_UNPOSITIONED;
    }
    const struct spa_pod *params[1] = {spa_format_audio_raw_build(&bld, SPA_PARAM_EnumFormat, &info)};

    if (pw_thread_loop_start(a->loop) < 0) {
        rc = mlc_fail(MLC_E_FAIL, "pw_thread_loop_start failed");
        goto fail;
    }
    pw_thread_loop_lock(a->loop);
    int err = pw_stream_connect(a->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
                                params, 1);
    /* pw_stream_new_simple connects to the daemon; with no daemon the stream goes to
     * the error state at once. Wait briefly to tell "no daemon" from "not linked yet". */
    enum pw_stream_state st = PW_STREAM_STATE_CONNECTING;
    const char *why = NULL;
    for (int i = 0; i < 50 && err >= 0; i++) {
        st = pw_stream_get_state(a->stream, &why);
        if (st == PW_STREAM_STATE_ERROR || st == PW_STREAM_STATE_PAUSED || st == PW_STREAM_STATE_STREAMING) break;
        pw_thread_loop_unlock(a->loop);
        struct timespec ts = {0, 10 * 1000 * 1000};
        nanosleep(&ts, NULL);
        pw_thread_loop_lock(a->loop);
    }
    pw_thread_loop_unlock(a->loop);
    if (err < 0 || st == PW_STREAM_STATE_ERROR) {
        rc = mlc_fail(MLC_E_NODEVICE, "PipeWire: %s", err < 0 ? spa_strerror(err) : (why ? why : "no daemon"));
        goto fail;
    }
    mlc_log("PipeWire %s: %u Hz x%u, ring %u frames, asking for a %u-frame quantum, stream %s",
            pw_get_library_version(), rate, channels, a->cap, quantum ? quantum : 256, pw_stream_state_as_string(st));
    *out = a;
    return MLC_OK;

fail:
    mlc_audio_close(a);
    return rc;
}

void mlc_audio_close(mlc_audio *a) {
    if (!a) return;
    if (a->loop) pw_thread_loop_stop(a->loop);
    if (a->stream) pw_stream_destroy(a->stream);
    if (a->loop) pw_thread_loop_destroy(a->loop);
    free(a->ring);
    free(a);
}

int mlc_audio_write(mlc_audio *a, const float *pcm, uint32_t frames, uint32_t *written) {
    uint64_t head = atomic_load_explicit(&a->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&a->tail, memory_order_acquire);
    uint32_t space = a->cap - (uint32_t)(head - tail);
    uint32_t n = frames < space ? frames : space;
    for (uint32_t i = 0; i < n;) {
        uint32_t pos = (uint32_t)((head + i) % a->cap);
        uint32_t run = a->cap - pos;
        if (run > n - i) run = n - i;
        memcpy(a->ring + (size_t)pos * a->channels, pcm + (size_t)i * a->channels, (size_t)run * a->channels * sizeof(float));
        i += run;
    }
    atomic_store_explicit(&a->head, head + n, memory_order_release);
    *written = n;
    return MLC_OK;
}

uint32_t mlc_audio_queued(mlc_audio *a) {
    uint64_t head = atomic_load_explicit(&a->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&a->tail, memory_order_acquire);
    return (uint32_t)(head - tail) + atomic_load(&a->graph_delay);
}

void mlc_audio_info(mlc_audio *a, uint32_t *ring_frames, uint32_t *quantum, int *streaming, uint64_t *underruns) {
    *ring_frames = a->cap;
    *quantum = atomic_load(&a->quantum);
    *streaming = atomic_load(&a->streaming);
    *underruns = atomic_load(&a->underruns);
}
