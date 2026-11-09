/*
 * The Linux host backend's C side, as Zig sees it (platform/host/linux/host.zig).
 * No system headers here: D-Bus and PipeWire stay in the .c files, and translate-c only
 * ever reads this file.
 *
 *   mlh_portal.c    xdg-desktop-portal ScreenCast over D-Bus: CreateSession, SelectSources
 *                   (cursor mode, persist mode, restore token), Start, OpenPipeWireRemote.
 *   mlh_capture.c   A PipeWire video stream on a portal node: dma-buf (with modifiers) or
 *                   memfd/memory buffers, cursor metadata, newest-frame mailbox.
 *   mlh_audio.c     A PipeWire capture stream on the default sink's monitor, f32, into a
 *                   ring the audio thread reads with a timeout.
 *   mlh_common.c    Errors and the clock.
 *
 * Every function returns 0 (MLH_OK) on success, MLH_TIMEOUT where noted, and a negative
 * MLH_E_* code otherwise; the C side prints the detail (mlh_last_error has the message).
 */
#ifndef MLH_H
#define MLH_H

#include <stddef.h>
#include <stdint.h>

#define MLH_OK 0
#define MLH_TIMEOUT 1
#define MLH_E_FAIL (-1)
#define MLH_E_UNSUPPORTED (-2)
#define MLH_E_NOMEM (-3)
#define MLH_E_CLOSED (-4)
#define MLH_E_NODEVICE (-5)
/* The user cancelled the portal's dialog, or the portal refused. */
#define MLH_E_DENIED (-6)
/* The stream or session went away (output unplugged, session revoked). */
#define MLH_E_LOST (-7)

/* The last error message on this thread (empty when none). */
const char *mlh_last_error(void);
/* CLOCK_MONOTONIC in microseconds (PipeWire's graph clock is CLOCK_MONOTONIC too). */
int64_t mlh_now_us(void);

/* ------------------------------------------------------------------------ */
/* ScreenCast portal */

typedef struct mlh_portal mlh_portal;

/* Cursor modes (the portal's bit values). */
#define MLH_CURSOR_HIDDEN 1u
#define MLH_CURSOR_EMBEDDED 2u
#define MLH_CURSOR_METADATA 4u

/* Persist modes: none, while this process runs, until the user revokes it. */
#define MLH_PERSIST_NONE 0u
#define MLH_PERSIST_TRANSIENT 1u
#define MLH_PERSIST_PERMANENT 2u

typedef struct mlh_portal_options {
    /* A token from an earlier session's mlh_portal_restore_token, or NULL. The portal
     * then restores that choice without a dialog (ScreenCast version 4 or later). */
    const char *restore_token;
    uint32_t persist_mode;
    /* The cursor mode wanted. When the portal does not offer it, metadata falls back to
     * embedded, embedded to metadata, and then to hidden. */
    uint32_t cursor_mode;
    /* Let the user pick several monitors (one stream each). */
    int multiple;
    /* How long to wait for the user to answer the dialog; 0 = 5 minutes. */
    uint32_t timeout_ms;
} mlh_portal_options;

#define MLH_SOURCE_MONITOR 1u
#define MLH_SOURCE_WINDOW 2u
#define MLH_SOURCE_VIRTUAL 4u

typedef struct mlh_stream_info {
    uint32_t node_id;
    uint32_t source_type;
    /* Position and size in compositor (logical) coordinates; -1/0 when not given. */
    int32_t x, y;
    int32_t width, height;
    /* The portal's mapping id for the monitor (version 5), for input mapping. */
    char mapping_id[64];
} mlh_stream_info;

/* Connects to the session bus and runs CreateSession, SelectSources and Start. Blocks
 * while the portal shows its dialog (not when a restore token is honoured).
 * MLH_E_NODEVICE: no session bus or no ScreenCast portal. MLH_E_DENIED: cancelled. */
int mlh_portal_open(const mlh_portal_options *o, mlh_portal **out);
/* Ends the session (the streams stop) and closes the bus connection. */
void mlh_portal_close(mlh_portal *p);
/* The portal interface's version and the cursor mode in effect. */
uint32_t mlh_portal_version(const mlh_portal *p);
uint32_t mlh_portal_cursor_mode(const mlh_portal *p);
uint32_t mlh_portal_stream_count(const mlh_portal *p);
int mlh_portal_stream(const mlh_portal *p, uint32_t i, mlh_stream_info *out);
/* The token to pass next time (NULL when the portal gave none). The spec makes tokens
 * single use (a start with one may return another), so always store the latest. */
const char *mlh_portal_restore_token(const mlh_portal *p);
/* OpenPipeWireRemote: a PipeWire connection that can see the session's nodes. The
 * caller owns the fd (mlh_capture_start takes it over). */
int mlh_portal_pipewire_fd(mlh_portal *p, int *fd);
/* Reads pending D-Bus messages without blocking; MLH_E_LOST once the session closed. */
int mlh_portal_poll(mlh_portal *p);

/* The restore token file: one line. Load: MLH_TIMEOUT when there is no file (or it is
 * empty), the token in `buf` otherwise. Store: written to a temporary file (mode 0600)
 * and renamed over `path`; the directory is created (0700) when missing. */
int mlh_token_load(const char *path, char *buf, size_t cap);
int mlh_token_store(const char *path, const char *token);

/* ------------------------------------------------------------------------ */
/* Video capture */

typedef struct mlh_capture mlh_capture;

typedef struct mlh_capture_config {
    /* The PipeWire connection (from mlh_portal_pipewire_fd), taken over; -1 connects to
     * the default daemon (tests). */
    int fd;
    /* The node to capture (mlh_stream_info.node_id). */
    uint32_t node_id;
    /* The highest frame rate wanted. */
    uint32_t fps;
    /* Offer dma-buf with these DRM modifiers (frames stay on the GPU); 0 modifiers: memory
     * buffers only. The producer picks dma-buf if it can and falls back to memory. */
    const uint64_t *modifiers;
    uint32_t n_modifiers;
    /* Ask for cursor metadata (the portal's cursor mode is metadata). */
    int cursor_meta;
    /* How long to wait for the format; 0 = 5 s. */
    uint32_t timeout_ms;
} mlh_capture_config;

/* Frame kinds. */
#define MLH_FRAME_MEMORY 1u
#define MLH_FRAME_DMABUF 2u

/* DRM fourccs of the frames (B, G, R, A/X in memory order is DRM's ARGB/XRGB8888). */
#define MLH_FOURCC_XRGB8888 0x34325258u /* 'XR24': B G R X */
#define MLH_FOURCC_ARGB8888 0x34325241u /* 'AR24': B G R A */
#define MLH_FOURCC_XBGR8888 0x34324258u /* 'XB24': R G B X */
#define MLH_FOURCC_ABGR8888 0x34324241u /* 'AB24': R G B A */
#define MLH_MOD_LINEAR 0ull
#define MLH_MOD_INVALID 0x00ffffffffffffffull

typedef struct mlh_dmabuf {
    uint32_t fourcc;
    uint64_t modifier;
    uint32_t width, height;
    uint32_t n_planes;
    int fd[4];
    uint32_t offset[4];
    uint32_t stride[4];
} mlh_dmabuf;

typedef struct mlh_cursor {
    /* Hotspot position in frame pixels (may be off the frame). */
    int32_t x, y;
    int32_t hot_x, hot_y;
    /* The bitmap, B G R A straight alpha; NULL before the first one. Changes `serial`. */
    const uint8_t *bitmap;
    uint32_t width, height, stride;
    uint32_t serial;
    uint8_t visible;
} mlh_cursor;

typedef struct mlh_frame {
    uint32_t kind;
    uint32_t width, height;
    /* Always B, G, R, A/X in memory order (RGB sources are swizzled into a copy). */
    uint32_t fourcc;
    /* MLH_FRAME_MEMORY: the pixels. MLH_FRAME_DMABUF: the pixels too when the buffer is
     * linear and could be mapped, else NULL. */
    const uint8_t *data;
    uint32_t stride;
    /* MLH_FRAME_DMABUF: the planes. Valid until release. */
    const mlh_dmabuf *dmabuf;
    /* Counts pictures the stream delivered. */
    uint64_t seq;
    /* When the process callback saw the buffer, and the producer's timestamp (the
     * buffer's header pts on CLOCK_MONOTONIC, never later than arrival; = arrival when
     * the producer gave none or an implausible one). */
    int64_t arrived_us;
    int64_t pts_us;
    /* 1: the same picture as the previous frame, with a moved cursor or as asked. */
    uint8_t repeat;
    uint8_t has_cursor;
    mlh_cursor cursor;
    /* Private: which buffer. */
    void *priv;
} mlh_frame;

typedef struct mlh_capture_stats {
    uint64_t frames;
    /* Buffers that came and were replaced by a newer one before anybody took them. */
    uint64_t dropped;
    /* Buffers with no picture (cursor-only updates, empty chunks) and corrupted ones. */
    uint64_t cursor_only;
    uint64_t corrupted;
    /* Format renegotiations after the first. */
    uint64_t renegotiations;
    uint32_t width, height;
    uint32_t fourcc;
    uint64_t modifier;
    uint8_t dmabuf;
    /* The producer's max frame rate, num/den (0/1 = variable). */
    uint32_t fps_num, fps_den;
} mlh_capture_stats;

/* Connects the stream and waits until the format is negotiated (or timeout). */
int mlh_capture_start(const mlh_capture_config *cfg, mlh_capture **out);
void mlh_capture_destroy(mlh_capture *c);
/* The negotiated frame size. */
void mlh_capture_size(mlh_capture *c, uint32_t *width, uint32_t *height);
/* Waits up to timeout_us for a picture newer than the last one handed out (or a cursor
 * change: then a repeat of the last picture). MLH_TIMEOUT when none came. At most one
 * frame out at a time. MLH_E_LOST when the stream ended. */
int mlh_capture_acquire(mlh_capture *c, int64_t timeout_us, mlh_frame *out);
/* The last picture again (repeat = 1, current cursor); MLH_TIMEOUT when there is none. */
int mlh_capture_repeat(mlh_capture *c, mlh_frame *out);
void mlh_capture_release(mlh_capture *c, mlh_frame *f);
void mlh_capture_get_stats(mlh_capture *c, mlh_capture_stats *out);

/* ------------------------------------------------------------------------ */
/* Audio capture */

typedef struct mlh_audio mlh_audio;

/* A capture stream on the default sink's monitor (stream.capture.sink), f32 interleaved
 * at rate x channels, into a ring of ring_ms, asking for a `quantum`-frame graph quantum.
 * `target`: a node name to capture instead of the default sink, or NULL.
 * MLH_E_NODEVICE when there is no PipeWire daemon. */
int mlh_audio_open(uint32_t rate, uint32_t channels, uint32_t ring_ms, uint32_t quantum, const char *target, mlh_audio **out);
void mlh_audio_close(mlh_audio *a);
/* Copies up to `frames` frames into `out`, waiting up to timeout_us for the first.
 * *got = frames copied (0 on timeout); *time_us = when the first of them was captured.
 * The ring drops its oldest frames when the reader falls behind (counted). */
int mlh_audio_read(mlh_audio *a, float *out, uint32_t frames, int64_t timeout_us, uint32_t *got, int64_t *time_us);
/* Whether the stream is linked and running, its quantum (0 until it ran), the frames
 * dropped because the reader fell behind, and the frames waiting in the ring. */
void mlh_audio_info(mlh_audio *a, int *streaming, uint32_t *quantum, uint64_t *overruns, uint32_t *queued);

#endif
