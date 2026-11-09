/* A PipeWire video source for the host tests (see testsource.h): RGBx pictures of one
 * colour, with cursor metadata, and cursor-only buffers (an empty chunk), as a compositor
 * in the portal's metadata cursor mode sends them. It drives its own graph cycle, so a
 * test decides exactly what the capture side receives. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>

#include "testsource.h"

#define CURSOR_W 16
#define CURSOR_H 16
#define CURSOR_META_SIZE(w, h) (sizeof(struct spa_meta_cursor) + sizeof(struct spa_meta_bitmap) + (w) * (h) * 4)

struct mlh_testsource {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook listener;
    uint32_t width, height, stride;
    int streaming;
    uint32_t bitmap_sent;
};

static void on_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old, (void)error;
    struct mlh_testsource *s = data;
    s->streaming = state == PW_STREAM_STATE_STREAMING;
    pw_thread_loop_signal(s->loop, false);
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    struct mlh_testsource *s = data;
    if (id != SPA_PARAM_Format || !param) return;
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[3];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_buffers,
                                           SPA_POD_CHOICE_RANGE_Int(8, 4, 16), SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
                                           SPA_PARAM_BUFFERS_size, SPA_POD_Int((int)(s->stride * s->height)), SPA_PARAM_BUFFERS_stride,
                                           SPA_POD_Int((int)s->stride), SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
    params[1] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
                                           SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
    params[2] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Cursor),
                                           SPA_PARAM_META_size, SPA_POD_Int(CURSOR_META_SIZE(CURSOR_W, CURSOR_H)));
    pw_stream_update_params(s->stream, params, 3);
}

static const struct pw_stream_events events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state,
    .param_changed = on_param_changed,
};

int mlh_testsource_create(uint32_t width, uint32_t height, mlh_testsource **out, uint32_t *node_id) {
    *out = NULL;
    pw_init(NULL, NULL);
    struct mlh_testsource *s = calloc(1, sizeof *s);
    if (!s) return -1;
    s->width = width;
    s->height = height;
    s->stride = width * 4;
    s->loop = pw_thread_loop_new("moonsec-testsource", NULL);
    s->context = pw_context_new(pw_thread_loop_get_loop(s->loop), NULL, 0);
    pw_thread_loop_start(s->loop);
    pw_thread_loop_lock(s->loop);
    s->core = pw_context_connect(s->context, NULL, 0);
    if (!s->core) {
        pw_thread_loop_unlock(s->loop);
        mlh_testsource_destroy(s);
        return -2;
    }
    s->stream = pw_stream_new(s->core, "moonsec-test-source", pw_properties_new(PW_KEY_MEDIA_CLASS, "Video/Source", NULL));
    pw_stream_add_listener(s->stream, &s->listener, &events, s);
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
        SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_RGBx), SPA_FORMAT_VIDEO_size,
        SPA_POD_Rectangle(&SPA_RECTANGLE(width, height)), SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(0, 1)),
        SPA_FORMAT_VIDEO_maxFramerate, SPA_POD_Fraction(&SPA_FRACTION(60, 1)));
    pw_stream_connect(s->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, PW_STREAM_FLAG_DRIVER | PW_STREAM_FLAG_MAP_BUFFERS,
                      params, 1);
    uint32_t id = SPA_ID_INVALID;
    for (int i = 0; i < 200 && id == SPA_ID_INVALID; i++) {
        id = pw_stream_get_node_id(s->stream);
        if (id == SPA_ID_INVALID) {
            struct timespec ts;
            pw_thread_loop_get_time(s->loop, &ts, 10 * SPA_NSEC_PER_MSEC);
            pw_thread_loop_timed_wait_full(s->loop, &ts);
        }
    }
    pw_thread_loop_unlock(s->loop);
    if (id == SPA_ID_INVALID) {
        mlh_testsource_destroy(s);
        return -3;
    }
    *node_id = id;
    *out = s;
    return 0;
}

int mlh_testsource_wait_streaming(mlh_testsource *s, int timeout_ms) {
    pw_thread_loop_lock(s->loop);
    struct timespec ts;
    pw_thread_loop_get_time(s->loop, &ts, (int64_t)timeout_ms * SPA_NSEC_PER_MSEC);
    while (!s->streaming)
        if (pw_thread_loop_timed_wait_full(s->loop, &ts) == -ETIMEDOUT) break;
    int ok = s->streaming;
    pw_thread_loop_unlock(s->loop);
    return ok ? 0 : -1;
}

void mlh_testsource_destroy(mlh_testsource *s) {
    if (!s) return;
    if (s->loop) pw_thread_loop_stop(s->loop);
    if (s->stream) pw_stream_destroy(s->stream);
    if (s->core) pw_core_disconnect(s->core);
    if (s->context) pw_context_destroy(s->context);
    if (s->loop) pw_thread_loop_destroy(s->loop);
    free(s);
}

int mlh_testsource_push(mlh_testsource *s, int picture, uint8_t r, uint8_t g, uint8_t b, int32_t cursor_x, int32_t cursor_y, uint32_t bitmap_serial) {
    pw_thread_loop_lock(s->loop);
    struct pw_buffer *pb = pw_stream_dequeue_buffer(s->stream);
    if (!pb) {
        pw_thread_loop_unlock(s->loop);
        return -1;
    }
    struct spa_buffer *buf = pb->buffer;
    struct spa_data *d = &buf->datas[0];
    if (picture && (!d->data || d->maxsize < s->stride * s->height)) {
        /* Buffers from before our Buffers params took effect: hand it back unused. */
        d->chunk->size = 0;
        pw_stream_queue_buffer(s->stream, pb);
        pw_thread_loop_unlock(s->loop);
        return -1;
    }
    if (picture) {
        uint8_t *px = d->data;
        for (uint32_t i = 0; i < s->width * s->height; i++) px[4 * i] = r, px[4 * i + 1] = g, px[4 * i + 2] = b, px[4 * i + 3] = 255;
        d->chunk->offset = 0;
        d->chunk->stride = (int32_t)s->stride;
        d->chunk->size = s->stride * s->height;
    } else {
        d->chunk->size = 0;
    }
    struct spa_meta_header *h = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof *h);
    if (h) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        h->pts = (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
        h->flags = 0;
    }
    struct spa_meta_cursor *mc = spa_buffer_find_meta_data(buf, SPA_META_Cursor, sizeof *mc);
    if (mc) {
        mc->id = 1;
        mc->flags = 0;
        mc->position.x = cursor_x;
        mc->position.y = cursor_y;
        mc->hotspot.x = 2;
        mc->hotspot.y = 3;
        mc->bitmap_offset = 0;
        if (bitmap_serial != s->bitmap_sent) {
            /* An RGBA arrow-ish square: red, opaque in the top half. */
            mc->bitmap_offset = sizeof *mc;
            struct spa_meta_bitmap *bm = SPA_PTROFF(mc, mc->bitmap_offset, struct spa_meta_bitmap);
            bm->format = SPA_VIDEO_FORMAT_RGBA;
            bm->size.width = CURSOR_W;
            bm->size.height = CURSOR_H;
            bm->stride = CURSOR_W * 4;
            bm->offset = sizeof *bm;
            uint8_t *p = SPA_PTROFF(bm, bm->offset, uint8_t);
            for (int y = 0; y < CURSOR_H; y++)
                for (int x = 0; x < CURSOR_W; x++, p += 4) p[0] = 255, p[1] = 0, p[2] = 0, p[3] = y < CURSOR_H / 2 ? 255 : 0;
            s->bitmap_sent = bitmap_serial;
        }
    }
    pw_stream_queue_buffer(s->stream, pb);
    pw_stream_trigger_process(s->stream);
    pw_thread_loop_unlock(s->loop);
    return 0;
}
