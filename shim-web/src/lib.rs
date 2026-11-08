//! moonsec iroh for the browser: a wasm-bindgen API over iroh 1.4.1.
//!
//! The browser twin of the native shim (`shim/`, C ABI in `shim/include/iroh_shim.h`). Same iroh
//! version, same Ed25519 endpoint keys, same `EndpointTicket` text, same ALPNs, so a browser
//! endpoint dials a native host (and the pairing exchange in `core/pair` runs over its
//! streams). The differences come from the browser:
//!
//! - **Relay only.** iroh in the browser has no UDP sockets; every path is a relay path over a
//!   WebSocket to the relay's HTTPS port. The browser does the TLS, so a relay needs a
//!   certificate the browser trusts (there is no `relay_ca_pem`).
//! - **No AppRate.** The native shim installs its own congestion controller and paces at the
//!   core's target. Here iroh's default controller runs: the browser client mostly receives,
//!   and sends feedback, input and acks. `setTargetBitrate` comes when a browser host needs it.
//! - **Promises, not timeouts on blocking calls.** Every blocking native call returns a
//!   `Promise` here; `timeoutMs` (0 or omitted = none) rejects it with code `"timeout"`.
//! - **No wakeup fd.** `recvDatagram()` is a promise that resolves on the next datagram, and
//!   `drainDatagrams()` takes everything queued at once without awaiting.
//!
//! Errors are JS `Error`s with a `code` property: `"invalid"`, `"closed"`, `"timeout"`,
//! `"busy"` or `"internal"`, the native shim's status codes by name.
#![allow(clippy::new_without_default)]

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::rc::Rc;
use std::str::FromStr;
use std::sync::Arc;

use bytes::Bytes;
use iroh::endpoint::{ConnectOptions, PathEvent, QuicTransportConfig, RecvStream, SendStream, presets};
use iroh::{Endpoint as IrohEndpoint, RelayMode, RelayUrl, SecretKey, TransportAddr};
use iroh_tickets::endpoint::EndpointTicket;
use js_sys::{Array, Object, Promise, Reflect, Uint8Array};
use n0_future::StreamExt;
use n0_future::time::{Duration, Instant};
use tokio::sync::Notify;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::{future_to_promise, spawn_local};

/// API version, (major << 16) | (minor << 8) | patch. Follows the native shim's ABI v0.2.
pub const VERSION: u32 = 0x00_02_00;

const DEFAULT_SEND_BUFFER: usize = 1 << 20;
const DEFAULT_RECV_BUFFER: usize = 2 << 20;
const DEFAULT_RECV_QUEUE: usize = 4096;
const EVENT_QUEUE: usize = 256;

// Event kinds: the native shim's IROH_EV_* values.
const EV_PATH_OPENED: u32 = 1;
const EV_PATH_SELECTED: u32 = 2;
const EV_PATH_CLOSED: u32 = 3;
const EV_LAGGED: u32 = 4;
const EV_CONN_CLOSED: u32 = 7;
const PATH_NONE: u32 = u32::MAX;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console, js_name = error)]
    fn console_error(s: &str);
}

#[wasm_bindgen(start)]
fn start() {
    std::panic::set_hook(Box::new(|info| console_error(&format!("iroh-web panic: {info}"))));
    now_us();
}

thread_local! {
    static EPOCH: Instant = Instant::now();
}

/// Microseconds on this module's monotonic clock (event timestamps use it).
#[wasm_bindgen(js_name = nowUs)]
pub fn now_us() -> f64 {
    EPOCH.with(|e| e.elapsed().as_micros() as f64)
}

/// The API version, as `iroh_shim_version()` returns it.
#[wasm_bindgen]
pub fn version() -> u32 {
    VERSION
}

fn js_err(code: &str, msg: impl std::fmt::Display) -> JsValue {
    let e = js_sys::Error::new(&msg.to_string());
    let _ = Reflect::set(&e, &"code".into(), &code.into());
    e.into()
}

fn set(o: &Object, k: &str, v: impl Into<JsValue>) {
    let _ = Reflect::set(o, &k.into(), &v.into());
}

/// Runs `fut` with `timeout_ms` (0 = no timeout).
async fn with_timeout<T>(timeout_ms: u32, what: &str, fut: impl Future<Output = Result<T, JsValue>>) -> Result<T, JsValue> {
    if timeout_ms == 0 {
        return fut.await;
    }
    match n0_future::time::timeout(Duration::from_millis(timeout_ms as u64), fut).await {
        Ok(r) => r,
        Err(_) => Err(js_err("timeout", format!("{what} timed out"))),
    }
}

// ---------------------------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------------------------

fn opt(o: &JsValue, k: &str) -> Option<JsValue> {
    if o.is_undefined() || o.is_null() {
        return None;
    }
    Reflect::get(o, &k.into()).ok().filter(|v| !v.is_undefined() && !v.is_null())
}

fn opt_num(o: &JsValue, k: &str) -> Result<Option<f64>, JsValue> {
    match opt(o, k) {
        None => Ok(None),
        Some(v) => v.as_f64().filter(|n| *n >= 0.0).map(Some).ok_or_else(|| js_err("invalid", format!("{k} must be a non-negative number"))),
    }
}

fn alpn_bytes(v: &JsValue) -> Result<Vec<u8>, JsValue> {
    if let Some(s) = v.as_string() {
        Ok(s.into_bytes())
    } else if v.is_instance_of::<Uint8Array>() {
        Ok(Uint8Array::from(v.clone()).to_vec())
    } else {
        Err(js_err("invalid", "alpn must be a string or Uint8Array"))
    }
}

#[derive(Clone, Copy)]
struct ConnConfig {
    send_buffer: usize,
    recv_buffer: usize,
    recv_queue: usize,
    conn_idle: Option<Duration>,
}

impl ConnConfig {
    fn transport(&self) -> Result<QuicTransportConfig, JsValue> {
        let mut b = QuicTransportConfig::builder()
            .datagram_send_buffer_size(self.send_buffer)
            .datagram_receive_buffer_size(Some(self.recv_buffer));
        if let Some(d) = self.conn_idle {
            let t = iroh::endpoint::IdleTimeout::try_from(d).map_err(|e| js_err("invalid", format!("connIdleTimeoutMs: {e}")))?;
            b = b.max_idle_timeout(Some(t));
        }
        Ok(b.build())
    }
}

// ---------------------------------------------------------------------------------------------
// Endpoint
// ---------------------------------------------------------------------------------------------

/// An iroh endpoint in the browser. Bind with `Endpoint.bind(opts)`.
#[wasm_bindgen]
pub struct Endpoint {
    ep: IrohEndpoint,
    alpn: Vec<u8>,
    cfg: ConnConfig,
}

#[wasm_bindgen]
impl Endpoint {
    /// Binds an endpoint. Options (all optional except `relayUrls` in `"custom"` mode):
    ///
    /// - `secretKey`: `Uint8Array(32)`, the device's Ed25519 key; omitted = a fresh key
    /// - `alpn`: string or bytes accepted on incoming connections (omitted = dial-only)
    /// - `relayMode`: `"custom"` (default: only `relayUrls`, no discovery; dial by ticket) or
    ///   `"default"` (n0's relays and discovery)
    /// - `relayUrls`: an array of relay URLs, or one newline-separated string
    /// - `datagramSendBuffer` (1 MiB), `datagramRecvBuffer` (2 MiB), `recvQueueLen` (4096),
    ///   `connIdleTimeoutMs` (iroh's): as in the native `IrohBindOpts`
    #[wasm_bindgen(unchecked_return_type = "Promise<Endpoint>")]
    pub fn bind(opts: JsValue) -> Promise {
        future_to_promise(async move { Ok(Endpoint::bind_inner(opts).await?.into()) })
    }

    async fn bind_inner(opts: JsValue) -> Result<Endpoint, JsValue> {
        let cfg = ConnConfig {
            send_buffer: opt_num(&opts, "datagramSendBuffer")?.map(|n| n as usize).unwrap_or(DEFAULT_SEND_BUFFER),
            recv_buffer: opt_num(&opts, "datagramRecvBuffer")?.map(|n| n as usize).unwrap_or(DEFAULT_RECV_BUFFER),
            recv_queue: opt_num(&opts, "recvQueueLen")?.map(|n| n as usize).unwrap_or(DEFAULT_RECV_QUEUE).max(1),
            conn_idle: opt_num(&opts, "connIdleTimeoutMs")?.map(|n| Duration::from_millis(n as u64)),
        };
        if cfg.send_buffer < 4096 {
            return Err(js_err("invalid", "datagramSendBuffer must be at least 4096"));
        }
        let alpn = opt(&opts, "alpn").map(|v| alpn_bytes(&v)).transpose()?.unwrap_or_default();
        let mode = opt(&opts, "relayMode").and_then(|v| v.as_string()).unwrap_or_else(|| "custom".into());
        let mut b = match mode.as_str() {
            "default" => IrohEndpoint::builder(presets::N0),
            "custom" | "custom-only" => {
                let raw = opt(&opts, "relayUrls").ok_or_else(|| js_err("invalid", "relayUrls required"))?;
                let list: Vec<String> = if let Some(s) = raw.as_string() {
                    s.lines().map(|l| l.trim().to_string()).collect()
                } else if Array::is_array(&raw) {
                    Array::from(&raw).iter().filter_map(|v| v.as_string()).collect()
                } else {
                    return Err(js_err("invalid", "relayUrls must be an array or a string"));
                };
                let urls = list
                    .iter()
                    .filter(|u| !u.is_empty())
                    .map(|u| RelayUrl::from_str(u).map_err(|e| js_err("invalid", format!("bad relay url {u}: {e}"))))
                    .collect::<Result<Vec<_>, _>>()?;
                if urls.is_empty() {
                    return Err(js_err("invalid", "relayUrls is empty"));
                }
                IrohEndpoint::builder(presets::Minimal).relay_mode(RelayMode::custom(urls))
            }
            m => return Err(js_err("invalid", format!("unknown relayMode {m}"))),
        };
        if let Some(k) = opt(&opts, "secretKey") {
            if !k.is_instance_of::<Uint8Array>() {
                return Err(js_err("invalid", "secretKey must be a Uint8Array"));
            }
            let k = Uint8Array::from(k).to_vec();
            let k: [u8; 32] = k.try_into().map_err(|_| js_err("invalid", "secretKey must be 32 bytes"))?;
            b = b.secret_key(SecretKey::from_bytes(&k));
        }
        if !alpn.is_empty() {
            b = b.alpns(vec![alpn.clone()]);
        }
        let ep = b.bind().await.map_err(|e| js_err("internal", format!("bind: {e}")))?;
        Ok(Endpoint { ep, alpn, cfg })
    }

    /// Resolves once the endpoint is connected to its home relay. Without that, its ticket
    /// has no address a peer can dial.
    #[wasm_bindgen(unchecked_return_type = "Promise<void>")]
    pub fn online(&self, timeout_ms: Option<u32>) -> Promise {
        let ep = self.ep.clone();
        future_to_promise(async move {
            with_timeout(timeout_ms.unwrap_or(0), "online", async move {
                ep.online().await;
                Ok(JsValue::UNDEFINED)
            })
            .await
        })
    }

    /// The endpoint ID (public key) as 64 hex digits.
    #[wasm_bindgen(getter)]
    pub fn id(&self) -> String {
        self.ep.id().to_string()
    }

    /// The endpoint's 32-byte secret key, to keep (IndexedDB) and pass back to `bind`.
    #[wasm_bindgen(js_name = secretKey)]
    pub fn secret_key(&self) -> Uint8Array {
        Uint8Array::from(&self.ep.secret_key().to_bytes()[..])
    }

    /// A dialable `EndpointTicket` (the same text `iroh_endpoint_ticket` gives).
    pub fn ticket(&self) -> String {
        EndpointTicket::new(self.ep.addr()).to_string()
    }

    /// Dials the endpoint in `ticket` with `alpn`.
    #[wasm_bindgen(unchecked_return_type = "Promise<Connection>")]
    pub fn connect(&self, ticket: String, alpn: JsValue, timeout_ms: Option<u32>) -> Promise {
        let ep = self.ep.clone();
        let cfg = self.cfg;
        future_to_promise(async move {
            let ticket = EndpointTicket::from_str(ticket.trim()).map_err(|e| js_err("invalid", format!("bad ticket: {e}")))?;
            let alpn = alpn_bytes(&alpn)?;
            let tc = cfg.transport()?;
            let conn = with_timeout(timeout_ms.unwrap_or(0), "connect", async move {
                let opts = ConnectOptions::new().with_transport_config(tc);
                let connecting = ep
                    .connect_with_opts(ticket.endpoint_addr().clone(), &alpn, opts)
                    .await
                    .map_err(|e| js_err("internal", format!("connect: {e}")))?;
                connecting.await.map_err(|e| js_err("internal", format!("connect: {e}")))
            })
            .await?;
            Ok(Connection::wrap(conn, cfg).into())
        })
    }

    /// Waits for an incoming connection (needs `alpn` at bind) and completes its handshake.
    #[wasm_bindgen(unchecked_return_type = "Promise<Connection>")]
    pub fn accept(&self, timeout_ms: Option<u32>) -> Promise {
        let ep = self.ep.clone();
        let cfg = self.cfg;
        let alpn = self.alpn.clone();
        future_to_promise(async move {
            if alpn.is_empty() {
                return Err(js_err("invalid", "endpoint was bound without an alpn (dial-only)"));
            }
            let tc = cfg.transport()?;
            let incoming = with_timeout(timeout_ms.unwrap_or(0), "accept", async {
                ep.accept().await.ok_or_else(|| js_err("closed", "endpoint closed"))
            })
            .await?;
            let sc = ep.create_server_config_builder(vec![alpn]).set_transport_config(tc).build();
            let accepting = incoming.accept_with(Arc::new(sc)).map_err(|e| js_err("internal", format!("accept: {e}")))?;
            let conn = with_timeout(10_000, "accept handshake", async move {
                accepting.await.map_err(|e| js_err("internal", format!("accept: {e}")))
            })
            .await?;
            Ok(Connection::wrap(conn, cfg).into())
        })
    }

    /// Closes every connection and the relay link.
    #[wasm_bindgen(unchecked_return_type = "Promise<void>")]
    pub fn close(&self) -> Promise {
        let ep = self.ep.clone();
        future_to_promise(async move {
            ep.close().await;
            Ok(JsValue::UNDEFINED)
        })
    }
}

// ---------------------------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------------------------

struct Shared {
    conn: iroh::endpoint::Connection,
    rx: RefCell<VecDeque<Bytes>>,
    rx_cap: usize,
    rx_notify: Notify,
    rx_from_quic: Cell<u64>,
    rx_read: Cell<u64>,
    rx_drops: Cell<u64>,
    tx_sent: Cell<u64>,
    events: RefCell<VecDeque<Object>>,
    events_dropped: Cell<u64>,
    selected_path: Cell<u32>,
    selections: Cell<u32>,
    closed: Cell<bool>,
}

impl Shared {
    fn push_event(&self, kind: u32, path_id: u32, value: f64, addr: Option<&TransportAddr>) {
        let o = Object::new();
        set(&o, "kind", kind);
        set(&o, "name", match kind {
            EV_PATH_OPENED => "path-opened",
            EV_PATH_SELECTED => "path-selected",
            EV_PATH_CLOSED => "path-closed",
            EV_LAGGED => "lagged",
            _ => "conn-closed",
        });
        set(&o, "pathId", path_id);
        set(&o, "tUs", now_us());
        set(&o, "value", value);
        set(&o, "isRelay", addr.is_some_and(|a| a.is_relay()));
        set(&o, "remoteAddr", addr.map(addr_text).unwrap_or_default());
        let mut q = self.events.borrow_mut();
        if q.len() >= EVENT_QUEUE {
            q.pop_front();
            self.events_dropped.set(self.events_dropped.get() + 1);
        }
        q.push_back(o);
    }
}

fn addr_text(a: &TransportAddr) -> String {
    match a {
        TransportAddr::Ip(sa) => sa.to_string(),
        TransportAddr::Relay(url) => url.to_string(),
        other => format!("{other:?}"),
    }
}

fn path_u32(id: iroh::endpoint::PathId) -> u32 {
    id.to_string().parse().unwrap_or(PATH_NONE)
}

/// A connection to one peer: unreliable datagrams and reliable bidirectional streams.
#[wasm_bindgen]
pub struct Connection {
    sh: Rc<Shared>,
}

impl Connection {
    fn wrap(conn: iroh::endpoint::Connection, cfg: ConnConfig) -> Connection {
        let sh = Rc::new(Shared {
            conn: conn.clone(),
            rx: RefCell::new(VecDeque::new()),
            rx_cap: cfg.recv_queue,
            rx_notify: Notify::new(),
            rx_from_quic: Cell::new(0),
            rx_read: Cell::new(0),
            rx_drops: Cell::new(0),
            tx_sent: Cell::new(0),
            events: RefCell::new(VecDeque::new()),
            events_dropped: Cell::new(0),
            selected_path: Cell::new(PATH_NONE),
            selections: Cell::new(0),
            closed: Cell::new(false),
        });
        // Subscribe before reading the current selection so no change falls in between.
        let mut events = conn.path_events();
        for p in conn.paths().iter() {
            if p.is_selected() {
                sh.selected_path.set(path_u32(p.id()));
            }
        }
        // Datagram reader: QUIC's receive buffer into our queue; a full queue drops the newest.
        {
            let sh = sh.clone();
            spawn_local(async move {
                const BATCH: usize = 64;
                let mut batch: Vec<Bytes> = vec![Bytes::new(); BATCH];
                while let Ok(n) = sh.conn.read_many_datagrams(&mut batch).await {
                    {
                        let mut q = sh.rx.borrow_mut();
                        for d in batch.iter_mut().take(n) {
                            if q.len() >= sh.rx_cap {
                                sh.rx_drops.set(sh.rx_drops.get() + 1);
                            } else {
                                q.push_back(std::mem::take(d));
                            }
                        }
                    }
                    sh.rx_from_quic.set(sh.rx_from_quic.get() + n as u64);
                    sh.rx_notify.notify_one();
                }
            });
        }
        // Path events.
        {
            let sh = sh.clone();
            spawn_local(async move {
                while let Some(ev) = events.next().await {
                    match ev {
                        PathEvent::Opened { id, remote_addr, .. } => sh.push_event(EV_PATH_OPENED, path_u32(id), 0.0, Some(&remote_addr)),
                        PathEvent::Selected { id, remote_addr, .. } => {
                            sh.selected_path.set(path_u32(id));
                            sh.selections.set(sh.selections.get() + 1);
                            sh.push_event(EV_PATH_SELECTED, path_u32(id), 0.0, Some(&remote_addr))
                        }
                        PathEvent::Closed { id, remote_addr, last_stats, .. } => {
                            sh.push_event(EV_PATH_CLOSED, path_u32(id), last_stats.lost_packets as f64, Some(&remote_addr))
                        }
                        PathEvent::Lagged { missed, .. } => sh.push_event(EV_LAGGED, PATH_NONE, missed as f64, None),
                        _ => {}
                    }
                }
            });
        }
        // Close watcher: wakes a pending recvDatagram so it rejects with "closed".
        {
            let sh = sh.clone();
            spawn_local(async move {
                let why = sh.conn.closed().await;
                sh.closed.set(true);
                let o_reason = why.to_string();
                sh.push_event(EV_CONN_CLOSED, PATH_NONE, 0.0, None);
                if let Some(ev) = sh.events.borrow().back() {
                    set(ev, "reason", o_reason);
                }
                sh.rx_notify.notify_one();
            });
        }
        Connection { sh }
    }
}

#[wasm_bindgen]
impl Connection {
    /// Queues one datagram. Never waits; when the send buffer is full QUIC evicts the oldest.
    #[wasm_bindgen(js_name = sendDatagram)]
    pub fn send_datagram(&self, data: &[u8]) -> Result<(), JsValue> {
        match self.sh.conn.send_datagram(Bytes::copy_from_slice(data)) {
            Ok(()) => {
                self.sh.tx_sent.set(self.sh.tx_sent.get() + 1);
                Ok(())
            }
            Err(e) => Err(js_err(if self.sh.closed.get() { "closed" } else { "invalid" }, format!("send datagram: {e}"))),
        }
    }

    /// The next datagram. Rejects with `"timeout"` after `timeoutMs` (0/omitted = wait), or
    /// `"closed"` once the connection is closed and the queue is empty.
    #[wasm_bindgen(js_name = recvDatagram, unchecked_return_type = "Promise<Uint8Array>")]
    pub fn recv_datagram(&self, timeout_ms: Option<u32>) -> Promise {
        let sh = self.sh.clone();
        future_to_promise(async move {
            with_timeout(timeout_ms.unwrap_or(0), "recv", async move {
                loop {
                    if let Some(d) = sh.rx.borrow_mut().pop_front() {
                        sh.rx_read.set(sh.rx_read.get() + 1);
                        return Ok(Uint8Array::from(&d[..]).into());
                    }
                    if sh.closed.get() {
                        return Err(js_err("closed", "connection closed"));
                    }
                    sh.rx_notify.notified().await;
                }
            })
            .await
        })
    }

    /// Every queued datagram (up to `max`, default all), without waiting. Empty array if none.
    #[wasm_bindgen(js_name = drainDatagrams, unchecked_return_type = "Uint8Array[]")]
    pub fn drain_datagrams(&self, max: Option<u32>) -> Array {
        let out = Array::new();
        let mut q = self.sh.rx.borrow_mut();
        let n = q.len().min(max.map(|m| m as usize).unwrap_or(usize::MAX));
        for d in q.drain(..n) {
            out.push(&Uint8Array::from(&d[..]));
        }
        self.sh.rx_read.set(self.sh.rx_read.get() + n as u64);
        out
    }

    /// Largest datagram the path takes now (relay paths: about 1.1 KB less than the MTU).
    #[wasm_bindgen(js_name = maxDatagramSize)]
    pub fn max_datagram_size(&self) -> u32 {
        self.sh.conn.max_datagram_size().unwrap_or(0) as u32
    }

    /// The peer's endpoint ID (64 hex digits), as the handshake authenticated it.
    #[wasm_bindgen(getter, js_name = remoteId)]
    pub fn remote_id(&self) -> String {
        self.sh.conn.remote_id().to_string()
    }

    /// The next path or connection event, or `undefined`. Kinds are the native IROH_EV_*.
    #[wasm_bindgen(js_name = pollEvent)]
    pub fn poll_event(&self) -> Option<Object> {
        self.sh.events.borrow_mut().pop_front()
    }

    /// Connection counters, named like `IrohConnStats` (camelCase). Numbers, not bigints.
    pub fn stats(&self) -> Object {
        let sh = &self.sh;
        let s = sh.conn.stats();
        let read = sh.rx_read.get();
        let from_quic = sh.rx_from_quic.get();
        let drops = sh.rx_drops.get();
        let rx_wire = s.frame_rx.datagram.max(from_quic);
        let o = Object::new();
        set(&o, "dgramSent", sh.tx_sent.get() as f64);
        set(&o, "dgramTxWire", s.frame_tx.datagram as f64);
        // Not split into evicted vs still queued (the native shim's FIFO accounting is not
        // ported): sent - tx_wire.
        set(&o, "dgramSendBacklog", sh.tx_sent.get().saturating_sub(s.frame_tx.datagram) as f64);
        set(&o, "dgramRxWire", rx_wire as f64);
        set(&o, "dgramRead", read as f64);
        set(&o, "dgramRecvDropsQuic", rx_wire.saturating_sub(from_quic) as f64);
        set(&o, "dgramRecvDropsShim", drops as f64);
        set(&o, "dgramRecvQueued", sh.rx.borrow().len() as f64);
        set(&o, "sentPackets", s.sent_packets as f64);
        set(&o, "lostPackets", s.lost_packets as f64);
        set(&o, "lostBytes", s.lost_bytes as f64);
        set(&o, "udpTxBytes", s.udp_tx.bytes as f64);
        set(&o, "udpRxBytes", s.udp_rx.bytes as f64);
        set(&o, "eventsDropped", sh.events_dropped.get() as f64);
        set(&o, "selectedPath", sh.selected_path.get());
        set(&o, "pathCount", sh.conn.paths().len() as u32);
        set(&o, "closed", sh.closed.get() || sh.conn.close_reason().is_some());
        set(&o, "pathSelections", sh.selections.get());
        o
    }

    /// One row per path, named like `IrohPathStats` (camelCase).
    #[wasm_bindgen(js_name = pathStats)]
    pub fn path_stats(&self) -> Array {
        let out = Array::new();
        for p in self.sh.conn.paths().iter() {
            let s = p.stats();
            let o = Object::new();
            set(&o, "pathId", path_u32(p.id()));
            set(&o, "isRelay", p.is_relay());
            set(&o, "isSelected", p.is_selected());
            set(&o, "rttUs", s.rtt.as_micros() as f64);
            set(&o, "cwnd", s.cwnd as f64);
            set(&o, "mtu", s.current_mtu as f64);
            set(&o, "sentPackets", s.sent_packets as f64);
            set(&o, "sentBytes", s.sent_bytes as f64);
            set(&o, "lostPackets", s.lost_packets as f64);
            set(&o, "lostBytes", s.lost_bytes as f64);
            set(&o, "congestionEvents", s.congestion_events as f64);
            set(&o, "udpTxDatagrams", s.udp_tx.datagrams as f64);
            set(&o, "udpRxDatagrams", s.udp_rx.datagrams as f64);
            set(&o, "remoteAddr", addr_text(&p.remote_addr()));
            out.push(&o);
        }
        out
    }

    /// Opens a bidirectional stream. Like native, it opens lazily: the peer's `acceptBi`
    /// returns after the first write.
    #[wasm_bindgen(js_name = openBi, unchecked_return_type = "Promise<BiStream>")]
    pub fn open_bi(&self, timeout_ms: Option<u32>) -> Promise {
        let conn = self.sh.conn.clone();
        future_to_promise(async move {
            let s = with_timeout(timeout_ms.unwrap_or(0), "open_bi", async move {
                conn.open_bi().await.map_err(|e| js_err("closed", format!("open_bi: {e}")))
            })
            .await?;
            Ok(BiStream::new(s).into())
        })
    }

    /// Accepts the peer's next bidirectional stream.
    #[wasm_bindgen(js_name = acceptBi, unchecked_return_type = "Promise<BiStream>")]
    pub fn accept_bi(&self, timeout_ms: Option<u32>) -> Promise {
        let conn = self.sh.conn.clone();
        future_to_promise(async move {
            let s = with_timeout(timeout_ms.unwrap_or(0), "accept_bi", async move {
                conn.accept_bi().await.map_err(|e| js_err("closed", format!("accept_bi: {e}")))
            })
            .await?;
            Ok(BiStream::new(s).into())
        })
    }

    /// Resolves with the close reason once the connection is closed (by either side).
    #[wasm_bindgen(unchecked_return_type = "Promise<string>")]
    pub fn closed(&self) -> Promise {
        let conn = self.sh.conn.clone();
        future_to_promise(async move { Ok(conn.closed().await.to_string().into()) })
    }

    /// Closes the connection with an application error code (`iroh_conn_free(c, code)`).
    pub fn close(&self, code: Option<u32>, reason: Option<String>) {
        let code = iroh::endpoint::VarInt::from_u32(code.unwrap_or(0));
        self.sh.conn.close(code, reason.unwrap_or_default().as_bytes());
    }
}

// ---------------------------------------------------------------------------------------------
// Bidirectional streams
// ---------------------------------------------------------------------------------------------

/// A reliable bidirectional stream. One read and one write may be in flight at a time;
/// overlapping calls reject with `"busy"`.
#[wasm_bindgen]
pub struct BiStream {
    send: Rc<RefCell<Option<SendStream>>>,
    recv: Rc<RefCell<Option<RecvStream>>>,
}

impl BiStream {
    fn new((send, recv): (SendStream, RecvStream)) -> BiStream {
        BiStream { send: Rc::new(RefCell::new(Some(send))), recv: Rc::new(RefCell::new(Some(recv))) }
    }
}

#[wasm_bindgen]
impl BiStream {
    /// Writes all of `data`.
    #[wasm_bindgen(unchecked_return_type = "Promise<void>")]
    pub fn write(&self, data: Vec<u8>, timeout_ms: Option<u32>) -> Promise {
        let slot = self.send.clone();
        future_to_promise(async move {
            let mut s = slot.borrow_mut().take().ok_or_else(|| js_err("busy", "a write is already in flight"))?;
            let r = with_timeout(timeout_ms.unwrap_or(0), "write", async {
                s.write_all(&data).await.map_err(|e| js_err("closed", format!("write: {e}")))
            })
            .await;
            *slot.borrow_mut() = Some(s);
            r.map(|()| JsValue::UNDEFINED)
        })
    }

    /// Reads up to `maxLen` bytes (default 64 KiB). Resolves `null` at the end of the stream.
    #[wasm_bindgen(unchecked_return_type = "Promise<Uint8Array | null>")]
    pub fn read(&self, max_len: Option<u32>, timeout_ms: Option<u32>) -> Promise {
        let slot = self.recv.clone();
        future_to_promise(async move {
            let mut r = slot.borrow_mut().take().ok_or_else(|| js_err("busy", "a read is already in flight"))?;
            let max = max_len.unwrap_or(65536).max(1) as usize;
            let out = with_timeout(timeout_ms.unwrap_or(0), "read", async {
                r.read_chunk(max).await.map_err(|e| js_err("closed", format!("read: {e}")))
            })
            .await;
            *slot.borrow_mut() = Some(r);
            match out? {
                Some(chunk) => Ok(Uint8Array::from(&chunk[..]).into()),
                None => Ok(JsValue::NULL),
            }
        })
    }

    /// Finishes the send side; the peer reads end-of-stream after the data.
    pub fn finish(&self) -> Result<(), JsValue> {
        let mut g = self.send.borrow_mut();
        let s = g.as_mut().ok_or_else(|| js_err("busy", "a write is in flight"))?;
        s.finish().map_err(|e| js_err("closed", format!("finish: {e}")))
    }

    /// Resets both directions with an application error code (`iroh_stream_free(s, code)`).
    pub fn reset(&self, code: u32) {
        let code = iroh::endpoint::VarInt::from_u32(code);
        if let Some(s) = self.send.borrow_mut().as_mut() {
            let _ = s.reset(code);
        }
        if let Some(r) = self.recv.borrow_mut().as_mut() {
            let _ = r.stop(code);
        }
    }
}
