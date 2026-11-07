/* moonsec iroh shim C ABI (v0.1, spike S1).
 * Status codes: 0 = ok, negative = error; iroh_last_error() has the message (thread-local).
 * The caller owns all buffers. Handles are opaque and freed with their *_free call. */
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

typedef struct IrohEndpoint IrohEndpoint;
typedef struct IrohConn IrohConn;

typedef struct IrohBindOpts {
    const uint8_t *secret_key; /* 32 bytes, or NULL for a fresh key */
    const uint8_t *alpn;       /* ALPN accepted for incoming conns; NULL = dial-only */
    size_t alpn_len;
    uint32_t relay_mode;       /* IROH_RELAY_* */
    const char *relay_urls;    /* used with IROH_RELAY_CUSTOM */
    const char *bind_addr;     /* e.g. "127.0.0.1:0"; NULL = default (all interfaces) */
} IrohBindOpts;

uint32_t iroh_shim_version(void);
const char *iroh_last_error(void);

int32_t iroh_endpoint_bind(const IrohBindOpts *opts, IrohEndpoint **out);
int32_t iroh_endpoint_online(const IrohEndpoint *ep, uint32_t timeout_ms);
int32_t iroh_endpoint_id(const IrohEndpoint *ep, char *buf, size_t cap);
int32_t iroh_endpoint_ticket(const IrohEndpoint *ep, char *buf, size_t cap, size_t *out_len);
int32_t iroh_endpoint_connect(const IrohEndpoint *ep, const char *ticket, const uint8_t *alpn,
                              size_t alpn_len, uint32_t timeout_ms, IrohConn **out);
int32_t iroh_endpoint_accept(const IrohEndpoint *ep, uint32_t timeout_ms, IrohConn **out);
void iroh_endpoint_free(IrohEndpoint *ep);

int32_t iroh_conn_send_datagram(const IrohConn *c, const uint8_t *buf, size_t len);
/* timeout_ms == 0: non-blocking, returns IROH_ERR_AGAIN when empty. */
int32_t iroh_conn_recv_datagram(const IrohConn *c, uint8_t *buf, size_t cap, uint32_t timeout_ms,
                                size_t *out_len);
size_t iroh_conn_max_datagram_size(const IrohConn *c);
uint64_t iroh_conn_local_drops(const IrohConn *c);
int32_t iroh_conn_remote_id(const IrohConn *c, char *buf, size_t cap);
void iroh_conn_free(IrohConn *c, uint32_t error_code);

#ifdef __cplusplus
}
#endif
#endif
