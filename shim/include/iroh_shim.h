/* moonsec iroh shim C ABI (v0.2).
 * Status codes: 0 = ok, negative = error; iroh_last_error() has the message (thread-local).
 * The caller owns all buffers. Handles are opaque and freed with their *_free call.
 * See shim/README.md for the design behind each call.
 *
 * Threading (docs/security-review.md): every call may come from any thread, and calls on one
 * handle may overlap, but a handle must not be freed while another thread is still inside a
 * call on it, nor used after its *_free. Blocking calls must not be made from the
 * IrohThreadStartFn hook (it runs on the shim's own thread, which they wait on). The
 * iroh_last_error() pointer is valid until the calling thread's next shim call. */
#ifndef MOONSEC_IROH_SHIM_H
#define MOONSEC_IROH_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IROH_OK 0
#define IROH_ERR_AGAIN (-1)
#define IROH_ERR_CLOSED (-2)
#define IROH_ERR_INVALID (-3)
#define IROH_ERR_TIMEOUT (-4)
#define IROH_ERR_TOO_SMALL (-5)
#define IROH_ERR_INTERNAL (-6)

#define IROH_RELAY_DEFAULT 0u  /* n0 public relays + n0 DNS/pkarr discovery */
#define IROH_RELAY_DISABLED 1u /* direct addresses only, no discovery */
#define IROH_RELAY_CUSTOM 2u   /* relay_urls (newline-separated) + n0 discovery */
#define IROH_RELAY_CUSTOM_ONLY 3u /* relay_urls, no discovery (dial by ticket; own relays) */

#define IROH_PATH_NONE 0xFFFFFFFFu
#define IROH_BURST_OFF 0xFFFFFFFFu  /* IrohBindOpts.burst_us: no burst credit */
#define IROH_NO_ACK_OFF 0xFFFFFFFFu /* IrohBindOpts.no_ack_progress_ms: no stall events */

/* IrohEvent.kind */
#define IROH_EV_PATH_OPENED 1u
#define IROH_EV_PATH_SELECTED 2u    /* the target rate moved to this path */
#define IROH_EV_PATH_CLOSED 3u      /* value = lost packets on the path */
#define IROH_EV_LAGGED 4u           /* value = path events iroh dropped */
#define IROH_EV_NO_ACK_PROGRESS 5u  /* selected path: nothing acked for value us */
#define IROH_EV_ACK_RESUMED 6u
#define IROH_EV_CONN_CLOSED 7u

typedef struct IrohEndpoint IrohEndpoint;
typedef struct IrohConn IrohConn;
typedef struct IrohStream IrohStream;

/* Zero-initialize, then set what you need: every 0/NULL field means "default". */
typedef struct IrohBindOpts {
    const uint8_t *secret_key;     /* 32 bytes, or NULL for a fresh key */
    const uint8_t *alpn;           /* ALPN accepted for incoming conns; NULL = dial-only */
    size_t alpn_len;
    uint32_t relay_mode;           /* IROH_RELAY_* */
    const char *relay_urls;        /* used with IROH_RELAY_CUSTOM(_ONLY) */
    const char *bind_addr;         /* e.g. "127.0.0.1:0"; NULL = default (all interfaces) */
    /* Per-connection transport settings for every conn of this endpoint. */
    size_t datagram_send_buffer;   /* bytes, default 1 MiB; must hold the largest frame (S10) */
    size_t datagram_recv_buffer;   /* bytes, default 2 MiB (QUIC's receive buffer) */
    uint32_t recv_queue_len;       /* datagrams the shim queues for the caller, default 4096 */
    uint32_t path_idle_timeout_ms; /* default 300 (S5); the S5c decision is open */
    uint32_t path_keepalive_ms;    /* default 100; must be below the idle timeout */
    uint32_t conn_idle_timeout_ms; /* default: iroh's */
    uint64_t initial_target_bps;   /* default 0 = unpaced until iroh_conn_set_target_bitrate */
    uint32_t burst_us;             /* AppRate burst credit, default 20000; IROH_BURST_OFF = none */
    uint32_t no_ack_progress_ms;   /* stall that raises IROH_EV_NO_ACK_PROGRESS, default 150 */
    const char *relay_ca_pem;      /* extra trusted roots (PEM) for relay TLS, e.g. a self-hosted
                                      relay's private CA; NULL = built-in web roots only */
} IrohBindOpts;

typedef struct IrohEvent {
    uint32_t kind;          /* IROH_EV_* */
    uint32_t path_id;       /* or IROH_PATH_NONE */
    uint64_t t_us;          /* iroh_shim_now_us() when the shim saw it */
    uint64_t value;         /* see IROH_EV_* */
    uint8_t is_relay;
    uint8_t _pad[7];
    char remote_addr[96];   /* "ip:port" or relay URL, NUL-terminated */
} IrohEvent;

/* Exact datagram accounting:
 *   dgram_sent == dgram_tx_wire + dgram_send_drops + dgram_send_queued
 *   dgram_rx_wire == dgram_read + dgram_recv_drops_quic + dgram_recv_drops_shim + dgram_recv_queued */
typedef struct IrohConnStats {
    uint64_t dgram_sent;            /* accepted by iroh_conn_send_datagram */
    uint64_t dgram_tx_wire;         /* put in a QUIC packet */
    uint64_t dgram_send_drops;      /* evicted from the full send buffer */
    uint64_t dgram_send_queued;     /* still in the send buffer */
    uint64_t dgram_rx_wire;         /* received in a QUIC packet */
    uint64_t dgram_read;            /* returned by iroh_conn_recv_datagram */
    uint64_t dgram_recv_drops_quic; /* dropped by QUIC's full receive buffer */
    uint64_t dgram_recv_drops_shim; /* dropped by the shim's full queue (caller too slow) */
    uint64_t dgram_recv_queued;     /* waiting in the shim's queue */
    uint64_t sent_packets;
    uint64_t lost_packets;
    uint64_t lost_bytes;
    uint64_t udp_tx_bytes;
    uint64_t udp_rx_bytes;
    uint64_t target_bps;
    uint64_t events_dropped;        /* events evicted from the shim's 256-entry queue */
    uint32_t selected_path;         /* or IROH_PATH_NONE */
    uint32_t path_count;
    uint32_t closed;
    uint32_t path_selections;       /* PATH_SELECTED events so far */
} IrohConnStats;

typedef struct IrohPathStats {
    uint32_t path_id;
    uint8_t is_relay;
    uint8_t is_selected;
    uint8_t no_ack_progress;  /* ack_stall_us is over the no-ack-progress threshold */
    uint8_t _pad;
    uint64_t rtt_us;
    uint64_t min_rtt_us;
    uint64_t cwnd;
    uint64_t mtu;
    uint64_t sent_packets;
    uint64_t sent_bytes;
    uint64_t lost_packets;
    uint64_t lost_bytes;
    uint64_t congestion_events;
    uint64_t udp_tx_datagrams;
    uint64_t udp_rx_datagrams;
    uint64_t pacing_bps;      /* base rate this path's controller paces at (0 = unpaced) */
    uint64_t ack_stall_us;    /* how long sent data has gone unacked (0 = all acked) */
    uint64_t last_ack_us;     /* shim clock of the last ack, 0 = none */
    char remote_addr[96];     /* "ip:port" or relay URL, NUL-terminated */
} IrohPathStats;

/* --- Runtime ---
 * iroh runs on one shim-owned thread (current-thread tokio runtime, S4). Optionally call
 * iroh_shim_init first to run a hook on that thread at startup, e.g. to pin it and raise
 * its priority. Returns IROH_ERR_INVALID if the runtime has already started. */
typedef void (*IrohThreadStartFn)(void *ctx);
int32_t iroh_shim_init(IrohThreadStartFn on_thread_start, void *ctx);

uint32_t iroh_shim_version(void);
uint64_t iroh_shim_now_us(void);
const char *iroh_last_error(void);

/* --- Endpoint --- */
int32_t iroh_endpoint_bind(const IrohBindOpts *opts, IrohEndpoint **out);
int32_t iroh_endpoint_online(const IrohEndpoint *ep, uint32_t timeout_ms);
int32_t iroh_endpoint_id(const IrohEndpoint *ep, char *buf, size_t cap);
int32_t iroh_endpoint_ticket(const IrohEndpoint *ep, char *buf, size_t cap, size_t *out_len);
int32_t iroh_endpoint_connect(const IrohEndpoint *ep, const char *ticket, const uint8_t *alpn,
                              size_t alpn_len, uint32_t timeout_ms, IrohConn **out);
int32_t iroh_endpoint_accept(const IrohEndpoint *ep, uint32_t timeout_ms, IrohConn **out);
/* The local network changed: re-run iroh's net report and try new paths now. */
int32_t iroh_endpoint_network_change(const IrohEndpoint *ep);
void iroh_endpoint_free(IrohEndpoint *ep);

/* --- Datagrams ---
 * send never blocks; when the send buffer is full the oldest queued datagrams are evicted
 * (and counted). recv: timeout_ms == 0 is non-blocking (IROH_ERR_AGAIN when empty). */
int32_t iroh_conn_send_datagram(const IrohConn *c, const uint8_t *buf, size_t len);
int32_t iroh_conn_recv_datagram(const IrohConn *c, uint8_t *buf, size_t cap, uint32_t timeout_ms,
                                size_t *out_len);
size_t iroh_conn_max_datagram_size(const IrohConn *c);
uint64_t iroh_conn_local_drops(const IrohConn *c); /* = IrohConnStats.dgram_recv_drops_shim */
int32_t iroh_conn_remote_id(const IrohConn *c, char *buf, size_t cap);
void iroh_conn_free(IrohConn *c, uint32_t error_code);

/* --- Rate (AppRate congestion controller) ---
 * The target is the core's capacity estimate in bits/s (0 = unpaced). It applies to the
 * selected path's controller and moves when iroh selects another path. */
int32_t iroh_conn_set_target_bitrate(const IrohConn *c, uint64_t bps);
int32_t iroh_conn_set_burst(const IrohConn *c, uint32_t burst_us);

/* --- Wakeup, events, stats ---
 * The wakeup handle (fd on Unix, SOCKET on Windows) becomes readable when a datagram or an
 * event arrives or the connection closes. Clear it, then drain recv and poll_event. */
int64_t iroh_conn_wakeup_handle(const IrohConn *c);
void iroh_conn_wakeup_clear(const IrohConn *c);
int32_t iroh_conn_poll_event(const IrohConn *c, IrohEvent *out); /* IROH_ERR_AGAIN if none */
int32_t iroh_conn_stats(const IrohConn *c, IrohConnStats *out);
/* Writes up to cap rows; *out_n = number of paths (may exceed cap). */
int32_t iroh_conn_path_stats(const IrohConn *c, IrohPathStats *out, size_t cap, size_t *out_n);

/* --- Bidirectional streams ---
 * Streams open lazily: the peer's accept returns after the first write. timeout_ms == 0 on
 * accept/read polls once (IROH_ERR_AGAIN). read: *out_len == 0 with IROH_OK = end of stream. */
int32_t iroh_conn_open_bi(const IrohConn *c, uint32_t timeout_ms, IrohStream **out);
int32_t iroh_conn_accept_bi(const IrohConn *c, uint32_t timeout_ms, IrohStream **out);
int32_t iroh_stream_write(const IrohStream *s, const uint8_t *buf, size_t len, uint32_t timeout_ms);
/* Writes what fits now (*out_written bytes); timeout_ms == 0 polls once (IROH_ERR_AGAIN when
 * flow control has no room). Never loses bytes on a timeout. Since 0.2.1. */
int32_t iroh_stream_write_some(const IrohStream *s, const uint8_t *buf, size_t len, uint32_t timeout_ms,
                               size_t *out_written);
int32_t iroh_stream_read(const IrohStream *s, uint8_t *buf, size_t cap, uint32_t timeout_ms,
                         size_t *out_len);
int32_t iroh_stream_finish(const IrohStream *s);
void iroh_stream_free(IrohStream *s, uint32_t error_code); /* nonzero code resets both sides */

#ifdef __cplusplus
}
#endif
#endif
