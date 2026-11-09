/* PipeWire audio capture of what the machine plays (see mlh.h).
 *
 * A capture stream with stream.capture.sink = true links to the default sink's monitor
 * (or `target`'s). Its process callback, on PipeWire's thread loop, appends each
 * quantum to a ring and notes the clock time of the newest frame; the audio thread reads
 * from the ring and gets the capture time of its first frame back from that note. When
 * the reader falls behind by a whole ring, the oldest frames go (counted as overruns). */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

#include "mlh_internal.h"

struct mlh_audio {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    struct spa_hook listener;
    uint32_t rate;
    uint32_t channels;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    /* Ring of `cap` frames; head and tail count frames forever. Under `mu`. */
    float *ring;
    uint32_t cap;
    uint64_t head;
    uint64_t tail;
    /* Clock time of frame `head` (one past the newest), from the last process cycle. */
    int64_t head_time_us;
    uint64_t overruns;
    uint32_t quantum;
    int streaming;
};

static void on_process(void *data) {
    struct mlh_audio *a = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(a->stream);
    if (!b) return;
    int64_t now = mlh_now_us();
    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];
    uint32_t stride = (uint32_t)sizeof(float) * a->channels;
    if (!d->data || !d->chunk || d->chunk->size == 0) {
        pw_stream_queue_buffer(a->stream, b);
        return;
    }
    uint32_t off = d->chunk->offset % d->maxsize;
    uint32_t n = d->chunk->size / stride;
    if (off + (size_t)n * stride > d->maxsize) n = (d->maxsize - off) / stride;
    const float *src = SPA_PTROFF(d->data, off, const float);
    /* The newest frame was captured about one graph delay ago; the delay (in graph ticks)
     * is what the capture side has not handed over yet. */
    int64_t delay_us = 0;
    struct pw_time t;
    if (pw_stream_get_time_n(a->stream, &t, sizeof t) == 0 && t.rate.denom > 0 && t.delay > 0)
        delay_us = t.delay * 1000000 * t.rate.num / t.rate.denom;

    pthread_mutex_lock(&a->mu);
    if (n > a->cap) {
        src += (size_t)(n - a->cap) * a->channels;
        a->overruns += n - a->cap;
        n = a->cap;
    }
    uint32_t used = (uint32_t)(a->head - a->tail);
    if (used + n > a->cap) {
        uint32_t drop = used + n - a->cap;
        a->tail += drop;
        a->overruns += drop;
    }
    for (uint32_t i = 0; i < n;) {
        uint32_t pos = (uint32_t)((a->head + i) % a->cap);
        uint32_t run = a->cap - pos;
        if (run > n - i) run = n - i;
        memcpy(a->ring + (size_t)pos * a->channels, src + (size_t)i * a->channels, (size_t)run * stride);
        i += run;
    }
    a->head += n;
    a->head_time_us = now - delay_us;
    a->quantum = n;
    pthread_cond_signal(&a->cv);
    pthread_mutex_unlock(&a->mu);
    pw_stream_queue_buffer(a->stream, b);
}

static void on_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    struct mlh_audio *a = data;
    pthread_mutex_lock(&a->mu);
    a->streaming = state == PW_STREAM_STATE_STREAMING;
    pthread_mutex_unlock(&a->mu);
    if (state == PW_STREAM_STATE_ERROR) mlh_log("PipeWire audio capture error: %s", error ? error : "?");
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state,
    .process = on_process,
};

int mlh_audio_open(uint32_t rate, uint32_t channels, uint32_t ring_ms, uint32_t quantum, const char *target, mlh_audio **out) {
    *out = NULL;
    if (channels == 0 || channels > 8) return mlh_fail(MLH_E_UNSUPPORTED, "%u channels", channels);
    mlh_pw_init();
    struct mlh_audio *a = calloc(1, sizeof *a);
    if (!a) return MLH_E_NOMEM;
    pthread_mutex_init(&a->mu, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&a->cv, &ca);
    pthread_condattr_destroy(&ca);
    a->rate = rate;
    a->channels = channels;
    a->cap = rate * (ring_ms ? ring_ms : 500) / 1000;
    a->ring = calloc((size_t)a->cap * channels, sizeof(float));
    if (!a->ring) {
        mlh_audio_close(a);
        return MLH_E_NOMEM;
    }
    int rc = MLH_E_FAIL;
    a->loop = pw_thread_loop_new("moonsec-audio-in", NULL);
    if (!a->loop) goto fail;

    char latency[32];
    snprintf(latency, sizeof latency, "%u/%u", quantum ? quantum : 256, rate);
    struct pw_properties *props = pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE,
                                                    "Screen", PW_KEY_STREAM_CAPTURE_SINK, "true", PW_KEY_NODE_LATENCY, latency,
                                                    PW_KEY_APP_NAME, "moonsec", NULL);
    if (target && target[0]) pw_properties_set(props, PW_KEY_TARGET_OBJECT, target);
    a->stream = pw_stream_new_simple(pw_thread_loop_get_loop(a->loop), "moonsec-audio-capture", props, &stream_events, a);
    if (!a->stream) {
        rc = mlh_fail(MLH_E_FAIL, "pw_stream_new_simple failed");
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
        rc = mlh_fail(MLH_E_FAIL, "pw_thread_loop_start failed");
        goto fail;
    }
    pw_thread_loop_lock(a->loop);
    int err = pw_stream_connect(a->stream, PW_DIRECTION_INPUT, PW_ID_ANY, PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
    /* With no daemon the stream goes to the error state at once. */
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
        rc = mlh_fail(MLH_E_NODEVICE, "PipeWire: %s", err < 0 ? spa_strerror(err) : (why ? why : "no daemon"));
        goto fail;
    }
    mlh_log("PipeWire %s audio capture: %u Hz x%u from %s, ring %u frames, stream %s", pw_get_library_version(), rate, channels,
            target && target[0] ? target : "the default sink's monitor", a->cap, pw_stream_state_as_string(st));
    *out = a;
    return MLH_OK;
fail:
    mlh_audio_close(a);
    return rc;
}

void mlh_audio_close(mlh_audio *a) {
    if (!a) return;
    if (a->loop) pw_thread_loop_stop(a->loop);
    if (a->stream) pw_stream_destroy(a->stream);
    if (a->loop) pw_thread_loop_destroy(a->loop);
    pthread_cond_destroy(&a->cv);
    pthread_mutex_destroy(&a->mu);
    free(a->ring);
    free(a);
}

int mlh_audio_read(mlh_audio *a, float *out, uint32_t frames, int64_t timeout_us, uint32_t *got, int64_t *time_us) {
    *got = 0;
    *time_us = 0;
    pthread_mutex_lock(&a->mu);
    if (a->head == a->tail && timeout_us > 0) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        int64_t ns = ts.tv_nsec + (timeout_us % 1000000) * 1000;
        ts.tv_sec += timeout_us / 1000000 + ns / 1000000000;
        ts.tv_nsec = ns % 1000000000;
        while (a->head == a->tail) {
            if (pthread_cond_timedwait(&a->cv, &a->mu, &ts) == ETIMEDOUT) break;
        }
    }
    uint32_t avail = (uint32_t)(a->head - a->tail);
    uint32_t n = avail < frames ? avail : frames;
    if (n > 0) {
        *time_us = a->head_time_us - (int64_t)(a->head - a->tail) * 1000000 / a->rate;
        for (uint32_t i = 0; i < n;) {
            uint32_t pos = (uint32_t)((a->tail + i) % a->cap);
            uint32_t run = a->cap - pos;
            if (run > n - i) run = n - i;
            memcpy(out + (size_t)i * a->channels, a->ring + (size_t)pos * a->channels, (size_t)run * a->channels * sizeof(float));
            i += run;
        }
        a->tail += n;
    }
    pthread_mutex_unlock(&a->mu);
    *got = n;
    return MLH_OK;
}

void mlh_audio_info(mlh_audio *a, int *streaming, uint32_t *quantum, uint64_t *overruns, uint32_t *queued) {
    pthread_mutex_lock(&a->mu);
    *streaming = a->streaming;
    *quantum = a->quantum;
    *overruns = a->overruns;
    *queued = (uint32_t)(a->head - a->tail);
    pthread_mutex_unlock(&a->mu);
}
