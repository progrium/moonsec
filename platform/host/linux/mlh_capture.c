/* PipeWire screen capture on a portal node (see mlh.h).
 *
 * The stream runs on a pw_thread_loop. Its process callback dequeues every buffer that
 * arrived and keeps only the newest picture ("pending"), handing older ones straight
 * back (counted as dropped), so the capture thread always gets the latest frame. The
 * capture thread takes `pending` under the loop lock; it then holds that buffer (as
 * "last") until a newer one is taken, which is what repeat hands out again. So at most
 * two buffers are held, and we ask the producer for at least four.
 *
 * Buffers with an empty chunk carry only cursor metadata (the portal's metadata cursor
 * mode sends those when just the pointer moved); they update the cursor and wake the
 * capture thread, which returns a repeat of the last picture with the new cursor.
 *
 * dma-buf negotiation follows PipeWire's docs/dma-buf.dox (and OBS): the first EnumFormat
 * carries the modifiers we can take (mandatory, don't-fixate), the second none; the
 * producer picks. A format with a modifier means dma-buf buffers, else memfd/memory. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <linux/dma-buf.h>
#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/debug/types.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

#include "mlh_internal.h"

#define CURSOR_META_SIZE(w, h) (sizeof(struct spa_meta_cursor) + sizeof(struct spa_meta_bitmap) + (w) * (h) * 4)

struct held {
    struct pw_buffer *b;
    int64_t arrived_us;
    int64_t pts_us;
    uint64_t seq;
    /* Crop (VideoCrop meta) applied to memory frames. */
    uint32_t x, y, w, h;
};

struct mlh_capture {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook core_listener;
    struct spa_hook stream_listener;
    uint64_t modifiers[32];
    uint32_t n_modifiers;
    uint32_t fps;
    int cursor_meta;

    /* Under the loop lock. */
    int format_ready;
    int lost;
    struct spa_video_info_raw info;
    int dmabuf;
    uint64_t modifier;
    struct held pending;
    struct held last;
    int out;
    uint64_t seq;
    mlh_capture_stats stats;
    /* Cursor as the producer last described it. */
    mlh_cursor cursor;
    uint8_t *cursor_px;
    size_t cursor_cap;
    int cursor_changed;
    int have_cursor;

    /* The capture thread's own copies (outside the lock). */
    uint8_t *cursor_out;
    size_t cursor_out_cap;
    uint32_t cursor_out_serial;
    uint8_t *swz;
    size_t swz_cap;
    mlh_dmabuf dmabuf_out;
    int synced_fd;
};

/* ------------------------------------------------------------------------ */
/* Format helpers */

static uint32_t fourcc_of(enum spa_video_format f) {
    switch (f) {
    case SPA_VIDEO_FORMAT_BGRx: return MLH_FOURCC_XRGB8888;
    case SPA_VIDEO_FORMAT_BGRA: return MLH_FOURCC_ARGB8888;
    case SPA_VIDEO_FORMAT_RGBx: return MLH_FOURCC_XBGR8888;
    case SPA_VIDEO_FORMAT_RGBA: return MLH_FOURCC_ABGR8888;
    default: return 0;
    }
}

static int is_rgb_order(enum spa_video_format f) {
    return f == SPA_VIDEO_FORMAT_RGBx || f == SPA_VIDEO_FORMAT_RGBA;
}

static const enum spa_video_format formats[] = {SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA};

static const struct spa_pod *build_format(struct spa_pod_builder *b, const uint64_t *mods, uint32_t n_mods, uint32_t fps) {
    struct spa_pod_frame f[2];
    spa_pod_builder_push_object(b, &f[0], SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
    spa_pod_builder_add(b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), 0);
    spa_pod_builder_add(b, SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), 0);
    spa_pod_builder_prop(b, SPA_FORMAT_VIDEO_format, 0);
    spa_pod_builder_push_choice(b, &f[1], SPA_CHOICE_Enum, 0);
    spa_pod_builder_id(b, formats[0]);
    for (size_t i = 0; i < sizeof formats / sizeof formats[0]; i++) spa_pod_builder_id(b, formats[i]);
    spa_pod_builder_pop(b, &f[1]);
    if (n_mods > 0) {
        spa_pod_builder_prop(b, SPA_FORMAT_VIDEO_modifier, SPA_POD_PROP_FLAG_MANDATORY | SPA_POD_PROP_FLAG_DONT_FIXATE);
        spa_pod_builder_push_choice(b, &f[1], SPA_CHOICE_Enum, 0);
        spa_pod_builder_long(b, (int64_t)mods[0]);
        for (uint32_t i = 0; i < n_mods; i++) spa_pod_builder_long(b, (int64_t)mods[i]);
        spa_pod_builder_pop(b, &f[1]);
    }
    spa_pod_builder_add(b, SPA_FORMAT_VIDEO_size,
                        SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)), 0);
    spa_pod_builder_add(b, SPA_FORMAT_VIDEO_framerate,
                        SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(fps, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(1000, 1)), 0);
    return spa_pod_builder_pop(b, &f[0]);
}

/* ------------------------------------------------------------------------ */
/* Stream callbacks (loop thread, lock held) */

static void requeue(mlh_capture *c, struct held *h) {
    if (h->b) pw_stream_queue_buffer(c->stream, h->b);
    memset(h, 0, sizeof *h);
}

static void read_cursor(mlh_capture *c, struct spa_buffer *buf) {
    struct spa_meta_cursor *mc = spa_buffer_find_meta_data(buf, SPA_META_Cursor, sizeof *mc);
    if (!mc) return;
    c->have_cursor = 1;
    if (!spa_meta_cursor_is_valid(mc)) {
        /* id 0: no cursor on this output (or hidden). */
        if (c->cursor.visible) c->cursor_changed = 1;
        c->cursor.visible = 0;
        return;
    }
    if (!c->cursor.visible || c->cursor.x != mc->position.x || c->cursor.y != mc->position.y) c->cursor_changed = 1;
    c->cursor.visible = 1;
    c->cursor.x = mc->position.x;
    c->cursor.y = mc->position.y;
    c->cursor.hot_x = mc->hotspot.x;
    c->cursor.hot_y = mc->hotspot.y;
    if (mc->bitmap_offset < sizeof *mc) return;
    struct spa_meta_bitmap *bm = SPA_PTROFF(mc, mc->bitmap_offset, struct spa_meta_bitmap);
    if (bm->size.width == 0 || bm->size.height == 0 || bm->offset < sizeof *bm) return;
    enum spa_video_format bf = (enum spa_video_format)bm->format;
    int rgb = bf == SPA_VIDEO_FORMAT_RGBA || bf == SPA_VIDEO_FORMAT_RGBx;
    int argb = bf == SPA_VIDEO_FORMAT_ARGB || bf == SPA_VIDEO_FORMAT_ABGR;
    if (!rgb && !argb && bf != SPA_VIDEO_FORMAT_BGRA && bf != SPA_VIDEO_FORMAT_BGRx) return;
    uint32_t w = bm->size.width, h = bm->size.height;
    size_t need = (size_t)w * h * 4;
    if (need > c->cursor_cap) {
        uint8_t *n = realloc(c->cursor_px, need);
        if (!n) return;
        c->cursor_px = n;
        c->cursor_cap = need;
    }
    const uint8_t *src = SPA_PTROFF(bm, bm->offset, const uint8_t);
    uint32_t stride = bm->stride > 0 ? (uint32_t)bm->stride : w * 4;
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * stride;
        uint8_t *d = c->cursor_px + (size_t)y * w * 4;
        for (uint32_t x = 0; x < w; x++, s += 4, d += 4) {
            /* Into B, G, R, A. */
            switch (bf) {
            case SPA_VIDEO_FORMAT_RGBA: d[0] = s[2], d[1] = s[1], d[2] = s[0], d[3] = s[3]; break;
            case SPA_VIDEO_FORMAT_RGBx: d[0] = s[2], d[1] = s[1], d[2] = s[0], d[3] = 255; break;
            case SPA_VIDEO_FORMAT_ARGB: d[0] = s[3], d[1] = s[2], d[2] = s[1], d[3] = s[0]; break;
            case SPA_VIDEO_FORMAT_ABGR: d[0] = s[1], d[1] = s[2], d[2] = s[3], d[3] = s[0]; break;
            case SPA_VIDEO_FORMAT_BGRx: d[0] = s[0], d[1] = s[1], d[2] = s[2], d[3] = 255; break;
            default: memcpy(d, s, 4); break;
            }
        }
    }
    c->cursor.bitmap = c->cursor_px;
    c->cursor.width = w;
    c->cursor.height = h;
    c->cursor.stride = w * 4;
    c->cursor.serial++;
    c->cursor_changed = 1;
}

static void on_process(void *data) {
    mlh_capture *c = data;
    struct pw_buffer *b;
    int woke = 0;
    while ((b = pw_stream_dequeue_buffer(c->stream)) != NULL) {
        int64_t now = mlh_now_us();
        struct spa_buffer *buf = b->buffer;
        if (c->cursor_meta) read_cursor(c, buf);
        struct spa_meta_header *hdr = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof *hdr);
        struct spa_chunk *ch = buf->datas[0].chunk;
        if ((hdr && (hdr->flags & SPA_META_HEADER_FLAG_CORRUPTED)) || (ch->flags & SPA_CHUNK_FLAG_CORRUPTED)) {
            c->stats.corrupted++;
            pw_stream_queue_buffer(c->stream, b);
            continue;
        }
        /* dma-buf chunks may report size 0 for a full picture (the size is implied);
         * memory chunks with size 0 carry no picture. */
        if (buf->datas[0].type != SPA_DATA_DmaBuf && ch->size == 0) {
            c->stats.cursor_only++;
            pw_stream_queue_buffer(c->stream, b);
            if (c->cursor_changed) woke = 1;
            continue;
        }
        if (c->pending.b) {
            c->stats.dropped++;
            requeue(c, &c->pending);
        }
        c->pending.b = b;
        c->pending.arrived_us = now;
        c->pending.seq = ++c->seq;
        c->pending.pts_us = now;
        if (hdr && hdr->pts > 0) {
            int64_t pts = hdr->pts / 1000;
            /* Trust it when it is on our clock: not later than arrival, within a second. */
            if (pts <= now && now - pts < 1000000) c->pending.pts_us = pts;
        }
        c->pending.x = c->pending.y = 0;
        c->pending.w = c->info.size.width;
        c->pending.h = c->info.size.height;
        struct spa_meta_region *crop = spa_buffer_find_meta_data(buf, SPA_META_VideoCrop, sizeof *crop);
        if (crop && spa_meta_region_is_valid(crop) && crop->region.position.x >= 0 && crop->region.position.y >= 0 &&
            crop->region.position.x + crop->region.size.width <= c->info.size.width &&
            crop->region.position.y + crop->region.size.height <= c->info.size.height) {
            c->pending.x = (uint32_t)crop->region.position.x;
            c->pending.y = (uint32_t)crop->region.position.y;
            c->pending.w = crop->region.size.width;
            c->pending.h = crop->region.size.height;
        }
        c->stats.frames++;
        woke = 1;
    }
    if (woke) pw_thread_loop_signal(c->loop, false);
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    mlh_capture *c = data;
    if (id != SPA_PARAM_Format || !param) return;
    uint32_t mt, mst;
    if (spa_format_parse(param, &mt, &mst) < 0 || mt != SPA_MEDIA_TYPE_video || mst != SPA_MEDIA_SUBTYPE_raw) return;
    struct spa_video_info_raw info;
    spa_zero(info);
    if (spa_format_video_raw_parse(param, &info) < 0) return;
    const struct spa_pod_prop *mod = spa_pod_find_prop(param, NULL, SPA_FORMAT_VIDEO_modifier);
    c->dmabuf = mod != NULL;
    c->modifier = mod ? info.modifier : MLH_MOD_INVALID;
    if (c->format_ready) c->stats.renegotiations++;
    c->info = info;
    c->stats.width = info.size.width;
    c->stats.height = info.size.height;
    c->stats.fourcc = fourcc_of(info.format);
    c->stats.modifier = c->modifier;
    c->stats.dmabuf = (uint8_t)c->dmabuf;
    c->stats.fps_num = info.max_framerate.num ? info.max_framerate.num : info.framerate.num;
    c->stats.fps_den = info.max_framerate.num ? info.max_framerate.denom : info.framerate.denom;
    mlh_log("capture format: %s %ux%u, %s%s, max %u/%u fps", spa_debug_type_find_short_name(spa_type_video_format, info.format),
            info.size.width, info.size.height, c->dmabuf ? "dma-buf" : "memory", c->dmabuf ? (c->modifier == 0 ? " (linear)" : "") : "",
            c->stats.fps_num, c->stats.fps_den);
    if (!fourcc_of(info.format)) {
        c->lost = 1;
        mlh_fail(MLH_E_UNSUPPORTED, "capture: producer chose format %u", info.format);
        pw_thread_loop_signal(c->loop, false);
        return;
    }

    uint8_t pod_buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
    const struct spa_pod *params[4];
    uint32_t n = 0;
    int types = c->dmabuf ? (1 << SPA_DATA_DmaBuf) : ((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr));
    params[n++] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
                                             SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(6, 4, 16),
                                             SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(types));
    params[n++] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
                                             SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
    params[n++] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_VideoCrop),
                                             SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_region)));
    if (c->cursor_meta)
        params[n++] = spa_pod_builder_add_object(
            &b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Cursor), SPA_PARAM_META_size,
            SPA_POD_CHOICE_RANGE_Int(CURSOR_META_SIZE(64, 64), CURSOR_META_SIZE(1, 1), CURSOR_META_SIZE(1024, 1024)));
    pw_stream_update_params(c->stream, params, n);
    c->format_ready = 1;
    pw_thread_loop_signal(c->loop, false);
}

static void on_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    mlh_capture *c = data;
    if (state == PW_STREAM_STATE_ERROR || (state == PW_STREAM_STATE_UNCONNECTED && old != PW_STREAM_STATE_UNCONNECTED)) {
        if (!c->lost) mlh_log("capture stream %s: %s", pw_stream_state_as_string(state), error ? error : "ended");
        c->lost = 1;
        pw_thread_loop_signal(c->loop, false);
    }
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state,
    .param_changed = on_param_changed,
    .process = on_process,
};

static void on_core_error(void *data, uint32_t id, int seq, int res, const char *message) {
    (void)seq;
    mlh_capture *c = data;
    mlh_log("PipeWire error on %u: %s (%s)", id, message ? message : "?", spa_strerror(res));
    if (id == PW_ID_CORE) {
        c->lost = 1;
        pw_thread_loop_signal(c->loop, false);
    }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .error = on_core_error,
};

/* ------------------------------------------------------------------------ */

int mlh_capture_start(const mlh_capture_config *cfg, mlh_capture **out) {
    *out = NULL;
    mlh_pw_init();
    mlh_capture *c = calloc(1, sizeof *c);
    if (!c) {
        if (cfg->fd >= 0) close(cfg->fd);
        return MLH_E_NOMEM;
    }
    c->synced_fd = -1;
    c->fps = cfg->fps ? cfg->fps : 60;
    c->cursor_meta = cfg->cursor_meta;
    c->n_modifiers = cfg->n_modifiers < 32 ? cfg->n_modifiers : 32;
    for (uint32_t i = 0; i < c->n_modifiers; i++) c->modifiers[i] = cfg->modifiers[i];

    int rc = MLH_E_FAIL;
    c->loop = pw_thread_loop_new("moonsec-capture", NULL);
    if (!c->loop) goto fail_fd;
    c->context = pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0);
    if (!c->context) goto fail_fd;
    if (pw_thread_loop_start(c->loop) < 0) goto fail_fd;
    pw_thread_loop_lock(c->loop);
    c->core = cfg->fd >= 0 ? pw_context_connect_fd(c->context, cfg->fd, NULL, 0) : pw_context_connect(c->context, NULL, 0);
    if (!c->core) {
        pw_thread_loop_unlock(c->loop);
        rc = mlh_fail(MLH_E_NODEVICE, "PipeWire connect: %s", strerror(errno));
        goto fail;
    }
    pw_core_add_listener(c->core, &c->core_listener, &core_events, c);
    c->stream = pw_stream_new(c->core, "moonsec-capture",
                              pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture", PW_KEY_MEDIA_ROLE, "Screen", NULL));
    if (!c->stream) {
        pw_thread_loop_unlock(c->loop);
        rc = mlh_fail(MLH_E_FAIL, "pw_stream_new failed");
        goto fail;
    }
    pw_stream_add_listener(c->stream, &c->stream_listener, &stream_events, c);
    uint8_t pod_buf[2048];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
    const struct spa_pod *params[2];
    uint32_t n = 0;
    if (c->n_modifiers > 0) params[n++] = build_format(&b, c->modifiers, c->n_modifiers, c->fps);
    params[n++] = build_format(&b, NULL, 0, c->fps);
    int err = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, cfg->node_id ? cfg->node_id : PW_ID_ANY,
                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, n);
    if (err < 0) {
        pw_thread_loop_unlock(c->loop);
        rc = mlh_fail(MLH_E_FAIL, "pw_stream_connect: %s", spa_strerror(err));
        goto fail;
    }
    struct timespec deadline;
    pw_thread_loop_get_time(c->loop, &deadline, (int64_t)(cfg->timeout_ms ? cfg->timeout_ms : 5000) * SPA_NSEC_PER_MSEC);
    while (!c->format_ready && !c->lost) {
        if (pw_thread_loop_timed_wait_full(c->loop, &deadline) == -ETIMEDOUT) break;
    }
    int ready = c->format_ready && !c->lost;
    pw_thread_loop_unlock(c->loop);
    if (!ready) {
        rc = c->lost ? mlh_fail(MLH_E_LOST, "capture: the stream failed before a format (node %u)", cfg->node_id)
                     : mlh_fail(MLH_E_FAIL, "capture: no format from node %u", cfg->node_id);
        goto fail;
    }
    *out = c;
    return MLH_OK;

fail_fd:
    if (cfg->fd >= 0) close(cfg->fd);
fail:
    mlh_capture_destroy(c);
    return rc;
}

void mlh_capture_destroy(mlh_capture *c) {
    if (!c) return;
    if (c->loop) pw_thread_loop_stop(c->loop);
    c->lost = 1; /* quiet: the stream's state goes to unconnected on the way out */
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->core) pw_core_disconnect(c->core);
    if (c->context) pw_context_destroy(c->context);
    if (c->loop) pw_thread_loop_destroy(c->loop);
    free(c->cursor_px);
    free(c->cursor_out);
    free(c->swz);
    free(c);
}

void mlh_capture_size(mlh_capture *c, uint32_t *width, uint32_t *height) {
    pw_thread_loop_lock(c->loop);
    *width = c->info.size.width;
    *height = c->info.size.height;
    pw_thread_loop_unlock(c->loop);
}

/* Fills `f` from c->last (lock held). */
static int fill_frame(mlh_capture *c, mlh_frame *f, int repeat) {
    memset(f, 0, sizeof *f);
    struct held *h = &c->last;
    struct spa_buffer *buf = h->b->buffer;
    struct spa_data *d = &buf->datas[0];
    f->repeat = (uint8_t)repeat;
    f->seq = h->seq;
    f->arrived_us = h->arrived_us;
    f->pts_us = h->pts_us;
    f->priv = h->b;
    enum spa_video_format fmt = c->info.format;
    uint32_t stride = d->chunk->stride > 0 ? (uint32_t)d->chunk->stride : c->info.size.width * 4;
    if (d->type == SPA_DATA_DmaBuf) {
        f->kind = MLH_FRAME_DMABUF;
        f->width = c->info.size.width;
        f->height = c->info.size.height;
        mlh_dmabuf *db = &c->dmabuf_out;
        memset(db, 0, sizeof *db);
        db->fourcc = fourcc_of(fmt);
        db->modifier = c->modifier;
        db->width = f->width;
        db->height = f->height;
        db->n_planes = buf->n_datas < 4 ? buf->n_datas : 4;
        for (uint32_t i = 0; i < db->n_planes; i++) {
            db->fd[i] = (int)buf->datas[i].fd;
            db->offset[i] = buf->datas[i].chunk->offset;
            db->stride[i] = (uint32_t)buf->datas[i].chunk->stride;
        }
        f->dmabuf = db;
        f->fourcc = db->fourcc;
        /* Linear and mapped by PipeWire (MAPPABLE): give the pixels too. */
        if (c->modifier == MLH_MOD_LINEAR && d->data && !is_rgb_order(fmt)) {
            struct dma_buf_sync s = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ};
            if (ioctl((int)d->fd, DMA_BUF_IOCTL_SYNC, &s) == 0) c->synced_fd = (int)d->fd;
            f->data = (const uint8_t *)d->data + d->chunk->offset;
            f->stride = stride;
        }
        return MLH_OK;
    }
    if (!d->data || d->maxsize == 0) return mlh_fail(MLH_E_FAIL, "capture: buffer not mapped (type %u)", d->type);
    if (h->w == 0 || h->h == 0) return mlh_fail(MLH_E_FAIL, "capture: empty picture");
    f->kind = MLH_FRAME_MEMORY;
    f->width = h->w;
    f->height = h->h;
    const uint8_t *src = (const uint8_t *)d->data + (d->chunk->offset % d->maxsize) + (size_t)h->y * stride + (size_t)h->x * 4;
    f->stride = stride;
    f->data = src;
    f->fourcc = fourcc_of(fmt);
    return MLH_OK;
}

/* Outside the lock: the cursor copy and RGB swizzle. */
static int finish_frame(mlh_capture *c, mlh_frame *f, const mlh_cursor *cur, int have_cursor) {
    if (have_cursor) {
        f->has_cursor = 1;
        f->cursor = *cur;
        f->cursor.bitmap = c->cursor_out_serial ? c->cursor_out : NULL;
    }
    if (f->kind == MLH_FRAME_MEMORY && (f->fourcc == MLH_FOURCC_XBGR8888 || f->fourcc == MLH_FOURCC_ABGR8888)) {
        size_t need = (size_t)f->width * f->height * 4;
        if (need > c->swz_cap) {
            uint8_t *n = realloc(c->swz, need);
            if (!n) return MLH_E_NOMEM;
            c->swz = n;
            c->swz_cap = need;
        }
        for (uint32_t y = 0; y < f->height; y++) {
            const uint8_t *s = f->data + (size_t)y * f->stride;
            uint8_t *d = c->swz + (size_t)y * f->width * 4;
            for (uint32_t x = 0; x < f->width; x++, s += 4, d += 4) d[0] = s[2], d[1] = s[1], d[2] = s[0], d[3] = s[3];
        }
        f->data = c->swz;
        f->stride = f->width * 4;
        f->fourcc = f->fourcc == MLH_FOURCC_XBGR8888 ? MLH_FOURCC_XRGB8888 : MLH_FOURCC_ARGB8888;
    }
    return MLH_OK;
}

/* Copies the cursor bitmap for the capture thread when it changed (lock held). */
static void take_cursor(mlh_capture *c, mlh_cursor *cur) {
    *cur = c->cursor;
    c->cursor_changed = 0;
    if (c->cursor.bitmap && c->cursor.serial != c->cursor_out_serial) {
        size_t need = (size_t)c->cursor.width * c->cursor.height * 4;
        if (need > c->cursor_out_cap) {
            uint8_t *n = realloc(c->cursor_out, need);
            if (!n) return;
            c->cursor_out = n;
            c->cursor_out_cap = need;
        }
        memcpy(c->cursor_out, c->cursor.bitmap, need);
        c->cursor_out_serial = c->cursor.serial;
    }
}

int mlh_capture_acquire(mlh_capture *c, int64_t timeout_us, mlh_frame *out) {
    memset(out, 0, sizeof *out);
    pw_thread_loop_lock(c->loop);
    struct timespec deadline;
    pw_thread_loop_get_time(c->loop, &deadline, (timeout_us > 0 ? timeout_us : 0) * 1000);
    while (!c->pending.b && !(c->cursor_changed && c->last.b) && !c->lost) {
        if (timeout_us <= 0 || pw_thread_loop_timed_wait_full(c->loop, &deadline) == -ETIMEDOUT) break;
    }
    if (c->lost) {
        pw_thread_loop_unlock(c->loop);
        return mlh_fail(MLH_E_LOST, "capture stream ended");
    }
    int repeat;
    if (c->pending.b) {
        if (c->last.b) requeue(c, &c->last);
        c->last = c->pending;
        memset(&c->pending, 0, sizeof c->pending);
        repeat = 0;
    } else if (c->cursor_changed && c->last.b) {
        repeat = 1;
    } else {
        pw_thread_loop_unlock(c->loop);
        return MLH_TIMEOUT;
    }
    mlh_cursor cur;
    take_cursor(c, &cur);
    int have_cursor = c->have_cursor;
    int rc = fill_frame(c, out, repeat);
    c->out = rc == MLH_OK;
    pw_thread_loop_unlock(c->loop);
    if (rc < 0) return rc;
    return finish_frame(c, out, &cur, have_cursor);
}

int mlh_capture_repeat(mlh_capture *c, mlh_frame *out) {
    memset(out, 0, sizeof *out);
    pw_thread_loop_lock(c->loop);
    if (!c->last.b) {
        pw_thread_loop_unlock(c->loop);
        return MLH_TIMEOUT;
    }
    mlh_cursor cur;
    take_cursor(c, &cur);
    int have_cursor = c->have_cursor;
    int rc = fill_frame(c, out, 1);
    c->out = rc == MLH_OK;
    pw_thread_loop_unlock(c->loop);
    if (rc < 0) return rc;
    return finish_frame(c, out, &cur, have_cursor);
}

void mlh_capture_release(mlh_capture *c, mlh_frame *f) {
    (void)f;
    /* The buffer stays held as `last` (for repeat) until a newer one is taken. */
    if (c->synced_fd >= 0) {
        struct dma_buf_sync s = {.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ};
        ioctl(c->synced_fd, DMA_BUF_IOCTL_SYNC, &s);
        c->synced_fd = -1;
    }
    c->out = 0;
}

void mlh_capture_get_stats(mlh_capture *c, mlh_capture_stats *out) {
    pw_thread_loop_lock(c->loop);
    *out = c->stats;
    pw_thread_loop_unlock(c->loop);
}
