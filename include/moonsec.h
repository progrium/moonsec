/*
 * moonsec.h: the public C ABI of the moonsec streaming library.
 *
 * Version 1.0 DRAFT. Not frozen: names and layouts may still change until the
 * header is marked 1.0 (see spec/c-abi-v1.md, "Freeze"). After the freeze,
 * 1.x releases only add: new functions, new constants, and new fields at the
 * end of structs that start with `struct_size`.
 *
 * Rules (spec/c-abi-v1.md has the full text):
 *   - Handles are opaque. Every function takes NULL safely and returns
 *     MOONSEC_ERR_INVALID (or does nothing, for destroy).
 *   - Every struct the caller passes in or gets filled starts with
 *     `uint32_t struct_size`, set by the caller to sizeof(that struct). The
 *     library reads and writes only the first struct_size bytes, so a caller
 *     built against an older 1.x header keeps working with a newer library.
 *     Zero-initialise config structs: zero means "default" for every field.
 *   - Buffers are the caller's. String outputs take (buf, cap, &len): len is
 *     set to the full length without the NUL; if cap <= len the call returns
 *     MOONSEC_ERR_BUFFER_TOO_SMALL and writes nothing.
 *   - Strings are UTF-8 and NUL-terminated. Input strings are copied; the
 *     caller may free them when the call returns.
 *   - Every function is thread-safe. Callbacks run on library threads (or
 *     inside moonsec_loopback_advance) and must not call moonsec functions.
 *   - Errors: a negative moonsec_status. moonsec_last_error() gives the detail
 *     for the calling thread's last failed call.
 */
#ifndef MOONSEC_H
#define MOONSEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(MOONSEC_SHARED)
#define MOONSEC_API __declspec(dllimport)
#else
#define MOONSEC_API
#endif

/* ------------------------------------------------------------------------- */
/* Version                                                                   */

#define MOONSEC_ABI_MAJOR 1
#define MOONSEC_ABI_MINOR 0
#define MOONSEC_ABI_PATCH 0
/* (major << 16) | (minor << 8) | patch */
#define MOONSEC_ABI_VERSION ((MOONSEC_ABI_MAJOR << 16) | (MOONSEC_ABI_MINOR << 8) | MOONSEC_ABI_PATCH)

/* The ABI version of the library actually loaded, as MOONSEC_ABI_VERSION. A
 * caller built against major M works with any loaded library of major M. */
MOONSEC_API uint32_t moonsec_version(void);
/* "1.0.0-draft" and build details. Static storage; never NULL. */
MOONSEC_API const char *moonsec_version_string(void);

/* What this build of the library can do (MOONSEC_FEATURE_*). */
#define MOONSEC_FEATURE_LOOPBACK 0x0001u       /* in-process simulated network */
#define MOONSEC_FEATURE_IROH 0x0002u           /* the iroh transport: tickets, relays, pairing */
#define MOONSEC_FEATURE_SYSTEM_BACKEND 0x0004u /* the OS capture/encode/decode/present backend */
#define MOONSEC_FEATURE_MULTI_USER 0x0008u     /* more than one client per host */
#define MOONSEC_FEATURE_DISPLAYS 0x0010u       /* display listing and switching */
MOONSEC_API uint32_t moonsec_features(void);

/* ------------------------------------------------------------------------- */
/* Status codes                                                              */

typedef int32_t moonsec_status;

#define MOONSEC_OK 0
#define MOONSEC_ERR_INVALID (-1)          /* bad argument, NULL handle, struct_size too small */
#define MOONSEC_ERR_UNSUPPORTED (-2)      /* not in this build, on this platform, or by this backend */
#define MOONSEC_ERR_NO_MEMORY (-3)
#define MOONSEC_ERR_STATE (-4)            /* not callable now (listening twice, session ended, ...) */
#define MOONSEC_ERR_BUFFER_TOO_SMALL (-5) /* len holds the size needed */
#define MOONSEC_ERR_TIMEOUT (-6)
#define MOONSEC_ERR_TRANSPORT (-7) /* bind, connect or accept failed */
#define MOONSEC_ERR_REFUSED (-8)   /* pairing failed, not paired, admission refused */
#define MOONSEC_ERR_BACKEND (-9)   /* capture, encoder, decoder or presenter failed */
#define MOONSEC_ERR_IO (-10)       /* the state directory could not be read or written */
#define MOONSEC_ERR_INTERNAL (-99)

/* A short constant name ("MOONSEC_ERR_TIMEOUT"); never NULL. */
MOONSEC_API const char *moonsec_status_string(moonsec_status status);
/* The detail of the calling thread's last failed call ("" if none). */
MOONSEC_API moonsec_status moonsec_last_error(char *buf, size_t cap, size_t *len);

/* ------------------------------------------------------------------------- */
/* Handles                                                                   */

typedef struct moonsec_host moonsec_host;         /* a device that streams its screen */
typedef struct moonsec_client moonsec_client;     /* a device that shows a host's screen */
typedef struct moonsec_session moonsec_session;   /* one host <-> client stream */
typedef struct moonsec_loopback moonsec_loopback; /* an in-process simulated network */

/* ------------------------------------------------------------------------- */
/* Shared constants                                                          */

#define MOONSEC_BACKEND_SYNTHETIC 0 /* test pattern, passthrough codec, scripted input */
#define MOONSEC_BACKEND_SYSTEM 1    /* the OS backend (MOONSEC_FEATURE_SYSTEM_BACKEND) */

#define MOONSEC_CODEC_H264 1
#define MOONSEC_CODEC_HEVC 2
#define MOONSEC_CODEC_AV1 3
#define MOONSEC_CODEC_PASSTHROUGH 250 /* the synthetic backend's codec */

/* Bitmask of codecs, for moonsec_client_config.codecs. */
#define MOONSEC_CODECS_H264 0x01u
#define MOONSEC_CODECS_HEVC 0x02u
#define MOONSEC_CODECS_AV1 0x04u
#define MOONSEC_CODECS_PASSTHROUGH 0x08u

#define MOONSEC_CHROMA_420 0
#define MOONSEC_CHROMA_444 1

#define MOONSEC_COLOR_SDR_BT709 0
#define MOONSEC_COLOR_HDR10 1 /* BT.2020, PQ, 10-bit */

#define MOONSEC_RELAY_DISABLED 0 /* direct paths only; binds on loopback unless bind_addr says otherwise */
#define MOONSEC_RELAY_DEFAULT 1  /* the public n0 relays and discovery; binds on all interfaces */
#define MOONSEC_RELAY_CUSTOM 2   /* relay_url only (a self-hosted relay); no n0 relays or discovery */

#define MOONSEC_CLIPBOARD_OFF 0
#define MOONSEC_CLIPBOARD_SYSTEM 1 /* sync the OS clipboard */
#define MOONSEC_CLIPBOARD_APP 2    /* the app's: moonsec_session_clipboard_set/get, MOONSEC_EVENT_CLIPBOARD */

/* The coded video format of a stream. Frozen layout. */
typedef struct moonsec_video_format {
    uint32_t codec;     /* MOONSEC_CODEC_* */
    uint32_t chroma;    /* MOONSEC_CHROMA_* */
    uint32_t bit_depth; /* 8 or 10 */
    uint32_t color;     /* MOONSEC_COLOR_* */
} moonsec_video_format;

/* ------------------------------------------------------------------------- */
/* Input                                                                     */

#define MOONSEC_INPUT_KEY 1      /* code: USB HID keyboard usage; down */
#define MOONSEC_INPUT_BUTTON 2   /* code: mouse button, 1-based; down */
#define MOONSEC_INPUT_SCROLL 3   /* x, y: 120 per wheel notch */
#define MOONSEC_INPUT_MOVE_REL 4 /* x, y: relative motion */
#define MOONSEC_INPUT_MOVE_ABS 5 /* x, y: 0..65535 across the streamed display */
#define MOONSEC_INPUT_GAMEPAD 6  /* code: pad index 0..3; down: connected; pad_* fields */

/* One input event. Frozen layout; new kinds may be added. */
typedef struct moonsec_input {
    uint32_t kind; /* MOONSEC_INPUT_* */
    uint32_t code;
    int32_t down; /* 1 pressed / connected, 0 released / disconnected */
    int32_t x;
    int32_t y;
    uint32_t pad_buttons; /* XInput button order */
    int16_t pad_lx, pad_ly, pad_rx, pad_ry;
    uint16_t pad_lt, pad_rt;
    uint32_t reserved;
    /* Client: when it happened, on the client's monotonic clock (0 = now).
     * Host: when the client says it happened, on the host's clock. */
    int64_t time_us;
} moonsec_input;

/* ------------------------------------------------------------------------- */
/* Host                                                                      */

#define MOONSEC_HOST_YUV444 0x0001u        /* prefer 4:4:4 when the client decodes it */
#define MOONSEC_HOST_TEN_BIT 0x0002u       /* prefer 10-bit when the client decodes it */
#define MOONSEC_HOST_NO_HDR 0x0004u        /* never send HDR10, even from an HDR display */
#define MOONSEC_HOST_RATE_CONTROL 0x0008u  /* adapt bitrate, resolution and frame rate to the link */
#define MOONSEC_HOST_LOSS_POLICY 0x0010u   /* choose NACK, FEC or relay mode per path */
#define MOONSEC_HOST_NO_AUDIO 0x0020u      /* don't stream the backend's audio */
#define MOONSEC_HOST_APP_INPUT 0x0040u     /* deliver client input as MOONSEC_EVENT_INPUT instead of injecting it */
#define MOONSEC_HOST_REQUIRE_PAIRED 0x0080u /* iroh: admit only paired clients; the default now, kept for source compatibility */
#define MOONSEC_HOST_INSECURE_NO_PAIRING 0x0100u /* iroh: admit any client that reaches the endpoint (tests and labs only) */

typedef struct moonsec_host_config {
    uint32_t struct_size; /* sizeof(moonsec_host_config) */
    uint32_t backend;     /* MOONSEC_BACKEND_* */
    /* The device key and paired-device lists. NULL: the per-user default
     * directory; "": a fresh key in memory, nothing saved. */
    const char *state_dir;
    const char *name; /* shown to devices that pair; NULL: the computer's name */
    uint32_t flags;   /* MOONSEC_HOST_* */
    uint32_t codec;   /* preferred MOONSEC_CODEC_*; 0: the backend's best */
    uint32_t fps;     /* 0: 60 */
    uint32_t display; /* display: an index from moonsec_host_displays (0: the first listed) */
    uint32_t width;   /* capture size hint; 0: the display's own */
    uint32_t height;
    uint64_t bitrate_bps; /* start bitrate; 0: 10 Mbit/s */
    uint32_t clipboard;   /* MOONSEC_CLIPBOARD_* */
    uint32_t max_clients; /* 0: 1; up to 32 at once over iroh (MOONSEC_FEATURE_MULTI_USER) */
    uint32_t relay_mode;  /* MOONSEC_RELAY_* */
    uint32_t reserved0;
    const char *relay_url;    /* MOONSEC_RELAY_CUSTOM */
    const char *relay_ca_pem; /* extra CA (PEM text) for a self-hosted relay; NULL: none */
    const char *bind_addr;    /* "IP:PORT"; NULL: by relay_mode */
    /* Called (on a library thread) when the event queue goes from empty to
     * non-empty; drain it with moonsec_host_poll_event. May be NULL. */
    void (*notify)(void *ctx);
    void *notify_ctx;
} moonsec_host_config;

MOONSEC_API moonsec_status moonsec_host_create(const moonsec_host_config *config, moonsec_host **out);
/* Ends every session (the clients are told), stops the threads, frees the
 * host and its sessions. */
MOONSEC_API void moonsec_host_destroy(moonsec_host *host);

/* This device's ID: 64 hex digits (the iroh endpoint ID). */
MOONSEC_API moonsec_status moonsec_host_id(moonsec_host *host, char *buf, size_t cap, size_t *len);

/* iroh: bind and accept clients in the background. Each admitted client
 * becomes a session (MOONSEC_EVENT_SESSION_STARTED). */
MOONSEC_API moonsec_status moonsec_host_listen(moonsec_host *host);
/* The address ticket clients connect with (after moonsec_host_listen). */
MOONSEC_API moonsec_status moonsec_host_ticket(moonsec_host *host, char *buf, size_t cap, size_t *len);

/* Pairing (iroh, state_dir): open a pairing window. */
typedef struct moonsec_pair_config {
    uint32_t struct_size;
    uint32_t seconds;  /* window length; 0: 120 */
    uint32_t pairings; /* devices it may pair; 0: 1 */
    uint32_t method;   /* MOONSEC_PAIR_QR_AND_PIN (0), _QR_ONLY, _PIN_ONLY */
} moonsec_pair_config;
#define MOONSEC_PAIR_QR_AND_PIN 0
#define MOONSEC_PAIR_QR_ONLY 1
#define MOONSEC_PAIR_PIN_ONLY 2

typedef struct moonsec_pair_info {
    uint32_t struct_size;
    uint32_t seconds;
    char qr_ticket[512];   /* "MOONSEC1:..." with the one-time secret; "" when PIN only */
    char addr_ticket[512]; /* "MOONSEC1:..." without a secret, used with the PIN */
    char pin[8];           /* six digits, NUL-terminated; "" when QR only */
} moonsec_pair_info;

/* Opens the window and returns the tickets and PIN to show. The window runs
 * in the background next to the session accept loop; outcomes arrive as
 * MOONSEC_EVENT_PAIRED and MOONSEC_EVENT_PAIR_FAILED, and
 * MOONSEC_EVENT_PAIR_CLOSED when it closes. Requires moonsec_host_listen. */
MOONSEC_API moonsec_status moonsec_host_pair_begin(moonsec_host *host, const moonsec_pair_config *config, moonsec_pair_info *info);
MOONSEC_API moonsec_status moonsec_host_pair_end(moonsec_host *host);

/* What a paired client may do besides watching and listening. New pairings
 * get MOONSEC_PERM_ALL. */
#define MOONSEC_PERM_INPUT 0x0001u     /* its keyboard, mouse and gamepad input is applied */
#define MOONSEC_PERM_CLIPBOARD 0x0002u /* the clipboard syncs with it */
#define MOONSEC_PERM_ALL 0x0003u

/* Sets a paired client's permissions (peer_id: its 64 hex digit ID, as in
 * events) and saves them with the allowlist. Applies at once to its session, if
 * it has one. MOONSEC_ERR_REFUSED if it is not paired. */
MOONSEC_API moonsec_status moonsec_host_set_permissions(moonsec_host *host, const char *peer_id, uint32_t perms);

/* Loopback: serve one client over `loopback`, in virtual time. The session
 * exists at once (`*session`, may be NULL) and starts streaming when the
 * client says hello. */
MOONSEC_API moonsec_status moonsec_host_listen_loopback(moonsec_host *host, moonsec_loopback *loopback, moonsec_session **session);

/* Multi-user (MOONSEC_FEATURE_MULTI_USER): hand input control to the client
 * of `session`, or back to the host's own user with NULL. */
MOONSEC_API moonsec_status moonsec_host_give_input(moonsec_host *host, moonsec_session *session);

/* Displays (MOONSEC_FEATURE_DISPLAYS). Frozen layout. */
typedef struct moonsec_display_info {
    uint32_t index;       /* the backend's display id: the value moonsec_host_config.display takes */
    uint32_t width;
    uint32_t height;
    uint32_t refresh_mhz; /* refresh rate in millihertz; 0 unknown */
    uint32_t primary;     /* 1 for the primary display */
    uint32_t hdr;         /* 1 when in an HDR mode now */
    char name[64];
} moonsec_display_info;
/* Fills up to `cap` entries; `*count` is the number of displays. While a session
 * streams: its capture's list; otherwise the backend's, if it can list without
 * streaming (MOONSEC_ERR_UNSUPPORTED if not). */
MOONSEC_API moonsec_status moonsec_host_displays(moonsec_host *host, moonsec_display_info *out, size_t cap, size_t *count);

/* ------------------------------------------------------------------------- */
/* Client                                                                    */

#define MOONSEC_CLIENT_NO_AUDIO 0x0001u    /* don't play the stream's audio */
#define MOONSEC_CLIENT_NO_OS_INPUT 0x0002u /* don't read the backend's input; send with moonsec_session_send_input only */
#define MOONSEC_CLIENT_FULLSCREEN 0x0004u
#define MOONSEC_CLIENT_REQUIRE_PAIRED 0x0008u /* iroh: connect only to paired hosts; the default now, kept for source compatibility */
#define MOONSEC_CLIENT_INSECURE_NO_PAIRING 0x0010u /* iroh: connect to any host the ticket names (tests and labs only) */

/* A presented picture, for moonsec_client_config.on_frame. Valid during the
 * callback only. */
typedef struct moonsec_frame {
    uint32_t struct_size;
    uint32_t frame_id;
    uint32_t width;
    uint32_t height;
    moonsec_video_format format;
    const void *pixels; /* CPU copy (BGRA8) when the backend has one, else NULL */
    uint32_t stride;
    uint32_t reserved;
    void *gpu_texture; /* the backend's GPU image (ID3D11Texture2D*, CVPixelBufferRef, ...), or NULL */
    int64_t presented_us; /* client monotonic clock */
} moonsec_frame;

typedef struct moonsec_client_config {
    uint32_t struct_size; /* sizeof(moonsec_client_config) */
    uint32_t backend;     /* MOONSEC_BACKEND_* */
    const char *state_dir; /* as moonsec_host_config.state_dir */
    const char *name;      /* shown to the host when pairing */
    uint32_t flags;        /* MOONSEC_CLIENT_* */
    uint32_t codecs;       /* MOONSEC_CODECS_* to offer; 0: all the decoder has */
    uint32_t max_width;    /* 0: no limit */
    uint32_t max_height;
    uint32_t clipboard;  /* MOONSEC_CLIPBOARD_* */
    uint32_t relay_mode; /* MOONSEC_RELAY_* */
    const char *relay_url;
    const char *relay_ca_pem;
    const char *bind_addr;
    void (*notify)(void *ctx); /* as moonsec_host_config.notify */
    void *notify_ctx;
    /* Called on the present thread after each picture is shown. May be NULL. */
    void (*on_frame)(void *ctx, const moonsec_frame *frame);
    void *frame_ctx;
} moonsec_client_config;

MOONSEC_API moonsec_status moonsec_client_create(const moonsec_client_config *config, moonsec_client **out);
MOONSEC_API void moonsec_client_destroy(moonsec_client *client);
MOONSEC_API moonsec_status moonsec_client_id(moonsec_client *client, char *buf, size_t cap, size_t *len);

/* iroh: connect to the host in `ticket` (moonsec_host_ticket, or a paired
 * host's saved address) and start a session. Returns once connected (or
 * after `timeout_ms`, 0: 30 s); the session streams after the host's config
 * (MOONSEC_EVENT_SESSION_STARTED). One session at a time. */
MOONSEC_API moonsec_status moonsec_client_connect(moonsec_client *client, const char *ticket, uint32_t timeout_ms, moonsec_session **session);
/* Pair with a host: `ticket` is its QR ticket, or its address ticket and
 * `pin` its PIN (NULL otherwise). Blocks until done; MOONSEC_ERR_REFUSED on a
 * wrong PIN or an expired ticket. */
MOONSEC_API moonsec_status moonsec_client_pair(moonsec_client *client, const char *ticket, const char *pin);
/* Loopback: connect to the host listening on `loopback`. */
MOONSEC_API moonsec_status moonsec_client_connect_loopback(moonsec_client *client, moonsec_loopback *loopback, moonsec_session **session);

/* ------------------------------------------------------------------------- */
/* Sessions                                                                  */

#define MOONSEC_STATE_CONNECTING 0 /* host: waiting for hello; client: waiting for config */
#define MOONSEC_STATE_STREAMING 1
#define MOONSEC_STATE_ENDED 2

#define MOONSEC_END_NONE 0
#define MOONSEC_END_CLOSED 1       /* this side closed it */
#define MOONSEC_END_PEER_CLOSED 2  /* the other side said bye */
#define MOONSEC_END_TIMEOUT 3      /* nothing heard for too long */
#define MOONSEC_END_TRANSPORT 4    /* the connection closed */
#define MOONSEC_END_FAILED 5       /* no common codec, backend failure, ... */

MOONSEC_API int32_t moonsec_session_state(moonsec_session *session); /* MOONSEC_STATE_*, or <0 */
/* Close: say bye and end. The handle stays valid until released. */
MOONSEC_API moonsec_status moonsec_session_close(moonsec_session *session);
/* Free an ended session's handle. Sessions still open are closed first.
 * Parents free any sessions left when destroyed. */
MOONSEC_API void moonsec_session_release(moonsec_session *session);

/* Client: send an input event to the host. */
MOONSEC_API moonsec_status moonsec_session_send_input(moonsec_session *session, const moonsec_input *input);
/* Multi-user client: ask the host's input owner for control. */
MOONSEC_API moonsec_status moonsec_session_request_input(moonsec_session *session);

/* Clipboard (MOONSEC_CLIPBOARD_APP): set this side's text (sent to the peer),
 * get the peer's latest text. */
MOONSEC_API moonsec_status moonsec_session_clipboard_set(moonsec_session *session, const char *text, size_t len);
MOONSEC_API moonsec_status moonsec_session_clipboard_get(moonsec_session *session, char *buf, size_t cap, size_t *len);

/* The stream's coded format and size, once streaming. */
MOONSEC_API moonsec_status moonsec_session_format(moonsec_session *session, moonsec_video_format *format, uint32_t *width, uint32_t *height);

/* ------------------------------------------------------------------------- */
/* Telemetry                                                                 */

#define MOONSEC_STAGE_CAPTURE 0 /* host: capture API latency */
#define MOONSEC_STAGE_ENCODE 1  /* host: frame to encoded */
#define MOONSEC_STAGE_NETWORK 2 /* encoded to received (cross-clock) */
#define MOONSEC_STAGE_DECODE 3  /* client: received to decoded */
#define MOONSEC_STAGE_PRESENT 4 /* client: decoded to presented */
#define MOONSEC_STAGE_TOTAL 5   /* capture to present: glass to glass (cross-clock) */
#define MOONSEC_STAGE_INPUT 6   /* client input to host injection (cross-clock) */
#define MOONSEC_STAGE_MAX 8     /* slots in moonsec_telemetry.stages */

/* Over the recent window of frames. Frozen layout. */
typedef struct moonsec_stage_stats {
    uint32_t count; /* samples; 0 = no data, the rest are 0 */
    uint32_t reserved;
    int64_t min_us;
    int64_t mean_us;
    int64_t p50_us;
    int64_t p95_us;
    int64_t p99_us;
    int64_t max_us;
} moonsec_stage_stats;

#define MOONSEC_TELEMETRY_RELAYED 0x01u      /* the selected path goes through a relay */
#define MOONSEC_TELEMETRY_CLOCK_SYNCED 0x02u /* cross-clock stages are valid */
#define MOONSEC_TELEMETRY_STALLED 0x04u      /* the path has stopped acking */

typedef struct moonsec_telemetry {
    uint32_t struct_size;
    int32_t state;      /* MOONSEC_STATE_* */
    int32_t end_reason; /* MOONSEC_END_* */
    uint32_t flags;     /* MOONSEC_TELEMETRY_* */
    moonsec_video_format format;
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t stage_count; /* stages filled: 7 in 1.0 */
    uint64_t bitrate_bps; /* encoder bitrate */
    uint64_t pacing_bps;  /* transport pacing rate */
    int64_t rtt_us;
    uint64_t frames;      /* host: sent; client: presented */
    uint64_t frames_lost; /* client */
    uint64_t keyframes;   /* host */
    uint64_t refreshes;   /* host: LTR refreshes */
    uint64_t freezes;     /* client: no new picture for 200 ms */
    int64_t longest_gap_us; /* client */
    uint64_t retransmits; /* host */
    uint64_t parity_shards; /* host: FEC */
    uint64_t input_events;  /* host: applied; client: sent */
    uint64_t path_changes;
    uint64_t reconnects;    /* iroh: new connections under this session (spec: Reconnect) */
    moonsec_stage_stats stages[MOONSEC_STAGE_MAX]; /* by MOONSEC_STAGE_* */
} moonsec_telemetry;

MOONSEC_API moonsec_status moonsec_session_telemetry(moonsec_session *session, moonsec_telemetry *out);

/* ------------------------------------------------------------------------- */
/* Events                                                                    */

#define MOONSEC_EVENT_SESSION_STARTED 1 /* session: streaming; format, width, height */
#define MOONSEC_EVENT_SESSION_ENDED 2   /* session; code: MOONSEC_END_* */
#define MOONSEC_EVENT_FORMAT_CHANGED 3  /* session; format, width, height */
#define MOONSEC_EVENT_INPUT 4           /* host with MOONSEC_HOST_APP_INPUT; session, input */
#define MOONSEC_EVENT_CLIPBOARD 5       /* session: the peer's text arrived (moonsec_session_clipboard_get) */
#define MOONSEC_EVENT_PATH_CHANGED 6    /* session; code: 1 relayed, 0 direct */
#define MOONSEC_EVENT_PAIRED 7          /* host; peer_id, peer_name */
#define MOONSEC_EVENT_PAIR_FAILED 8     /* host; peer_id; code: MOONSEC_PAIR_FAIL_* */
#define MOONSEC_EVENT_PAIR_CLOSED 9     /* host; code: devices paired in the window */
#define MOONSEC_EVENT_INPUT_OWNER 10    /* multi-user; session holding input (host: that member's; client: its own session, NULL when someone else holds it); code: holder's member id, 0 = host's user */
#define MOONSEC_EVENT_REFUSED 11        /* host: a client that is not paired was turned away; peer_id */

#define MOONSEC_PAIR_FAIL_BAD_PROOF 1 /* wrong PIN or secret */
#define MOONSEC_PAIR_FAIL_EXPIRED 2
#define MOONSEC_PAIR_FAIL_OTHER 3

typedef struct moonsec_event {
    uint32_t struct_size;
    uint32_t type;            /* MOONSEC_EVENT_* */
    moonsec_session *session; /* the session it is about, or NULL */
    int64_t time_us;          /* local monotonic clock */
    int32_t code;
    uint32_t width;
    uint32_t height;
    uint32_t reserved;
    moonsec_video_format format;
    moonsec_input input;
    char peer_id[72]; /* 64 hex digits */
    char peer_name[64];
} moonsec_event;

/* Take the oldest event: 1 if `*event` was filled, 0 if the queue is empty,
 * <0 on error. `timeout_ms` > 0 waits that long for one (not in loopback
 * mode, where events come only from moonsec_loopback_advance). On macOS, a
 * call on the main thread handles AppKit's events while it waits, so a
 * MOONSEC_BACKEND_SYSTEM client's window shows and draws without [NSApp run]. */
MOONSEC_API int32_t moonsec_host_poll_event(moonsec_host *host, moonsec_event *event, uint32_t timeout_ms);
MOONSEC_API int32_t moonsec_client_poll_event(moonsec_client *client, moonsec_event *event, uint32_t timeout_ms);

/* ------------------------------------------------------------------------- */
/* Loopback: an in-process simulated network, in virtual time                */

#define MOONSEC_PROFILE_CLEAN 0 /* no delay, no loss */
#define MOONSEC_PROFILE_LAN 1   /* 1 ms, small jitter, rare loss */
#define MOONSEC_PROFILE_WAN 2   /* 25 ms, jitter, 1% loss */

typedef struct moonsec_loopback_config {
    uint32_t struct_size;
    uint32_t profile; /* MOONSEC_PROFILE_* */
    uint64_t seed;    /* 0: 1 */
} moonsec_loopback_config;

MOONSEC_API moonsec_status moonsec_loopback_create(const moonsec_loopback_config *config, moonsec_loopback **out);
/* Destroy after the host and client using it. */
MOONSEC_API void moonsec_loopback_destroy(moonsec_loopback *loopback);
/* Run the network, then the host and client attached to it, for `us`
 * microseconds of virtual time, on the calling thread. */
MOONSEC_API moonsec_status moonsec_loopback_advance(moonsec_loopback *loopback, int64_t us);
/* Virtual time, us since creation. */
MOONSEC_API int64_t moonsec_loopback_now(moonsec_loopback *loopback);

#ifdef __cplusplus
}
#endif

#endif /* MOONSEC_H */
