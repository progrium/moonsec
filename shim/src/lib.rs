//! moonsec iroh shim: the C ABI the Zig core uses for networking (v0.2).
//!
//! Beyond wrapping iroh, the shim owns what spikes S2-S5 and S10 showed it must:
//! - congestion control and pacing (`AppRate`, one factory per connection, rate set by the core
//!   and moved to whichever path iroh selects; burst credit for frames),
//! - exact datagram drop accounting on both sides,
//! - path events, per-path stats and a "no ack progress" signal,
//! - datagram buffer sizes, path idle timeout and keep-alive,
//! - one dedicated current-thread runtime that the host can pin (S4).
//!
//! Conventions:
//! - Every function returns an `int32_t` status (0 = ok, negative = error) unless noted.
//! - On error, `iroh_last_error()` returns a thread-local, NUL-terminated message that
//!   stays valid until the next shim call on the same thread.
//! - The caller (Zig) owns every buffer that crosses the boundary; the shim never
//!   returns heap memory except opaque handles, which are freed with their `_free` call.
#![allow(clippy::missing_safety_doc)]

mod apprate;
mod wakeup;

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString, c_char};
use std::net::SocketAddr;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use apprate::{AppRate, AppRateFactory, NO_SELECTION, PathCounters, RateKnob};
use bytes::Bytes;
use iroh::endpoint::{
    ConnectOptions, Connection, IdleTimeout, PathEvent, PathId, QuicTransportConfig, RecvStream, SendStream,
    presets,
};
use iroh::tls::CaTlsConfig;
use iroh::{Endpoint, RelayMode, RelayUrl, SecretKey, TransportAddr};
use iroh_tickets::endpoint::EndpointTicket;
use n0_future::StreamExt;
use rustls_pki_types::{CertificateDer, pem::PemObject};
use wakeup::Wakeup;

pub const IROH_OK: i32 = 0;
pub const IROH_ERR_AGAIN: i32 = -1;
pub const IROH_ERR_CLOSED: i32 = -2;
pub const IROH_ERR_INVALID: i32 = -3;
pub const IROH_ERR_TIMEOUT: i32 = -4;
pub const IROH_ERR_TOO_SMALL: i32 = -5;
pub const IROH_ERR_INTERNAL: i32 = -6;

pub const IROH_RELAY_DEFAULT: u32 = 0;
pub const IROH_RELAY_DISABLED: u32 = 1;
pub const IROH_RELAY_CUSTOM: u32 = 2;
pub const IROH_RELAY_CUSTOM_ONLY: u32 = 3;

pub const IROH_PATH_NONE: u32 = u32::MAX;
pub const IROH_BURST_OFF: u32 = u32::MAX;
pub const IROH_NO_ACK_OFF: u32 = u32::MAX;

pub const IROH_EV_PATH_OPENED: u32 = 1;
pub const IROH_EV_PATH_SELECTED: u32 = 2;
pub const IROH_EV_PATH_CLOSED: u32 = 3;
pub const IROH_EV_LAGGED: u32 = 4;
pub const IROH_EV_NO_ACK_PROGRESS: u32 = 5;
pub const IROH_EV_ACK_RESUMED: u32 = 6;
pub const IROH_EV_CONN_CLOSED: u32 = 7;

// Defaults (see docs/design.md, Transport: "What the shim owns").
/// S10: 64 KiB evicted 62% of an 85 Mbit/s 60 fps stream; hold the largest frame.
const DEFAULT_SEND_BUFFER: usize = 1 << 20;
const DEFAULT_RECV_BUFFER: usize = 2 << 20;
const DEFAULT_RECV_QUEUE: u32 = 4096;
/// S5: dead direct path detected in 300 ms instead of 15 s. S5b's question is still open.
const DEFAULT_PATH_IDLE_MS: u32 = 300;
const DEFAULT_PATH_KEEPALIVE_MS: u32 = 100;
/// S10: about one frame of credit (20 ms) took frame bursts from 1.3 to 0.6 ms added p99.
const DEFAULT_BURST_US: u32 = 20_000;
const DEFAULT_NO_ACK_MS: u32 = 150;
const EVENT_QUEUE: usize = 256;
/// Bound on an accepted connection's handshake (see `iroh_endpoint_accept`).
const ACCEPT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Incoming handshakes in progress at once; a newcomer past it aborts the oldest, so peers
/// that start handshakes and stall cannot keep a real client out.
const MAX_HANDSHAKES: usize = 16;
/// Connections whose handshake completed, waiting for `iroh_endpoint_accept`.
const ACCEPTED_QUEUE: usize = 8;
const MONITOR_TICK: Duration = Duration::from_millis(5);
/// Bytes of bookkeeping noq charges per queued datagram (`size_of::<frame::Datagram>()`).
const DGRAM_OVERHEAD: usize = std::mem::size_of::<Bytes>();
/// Resolve the send FIFO at least this often, to bound its memory.
const TX_FIFO_RESOLVE: usize = 1024;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_error(msg: impl std::fmt::Display) {
    let s = CString::new(msg.to_string().replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|e| *e.borrow_mut() = s);
}

fn fail(code: i32, msg: impl std::fmt::Display) -> i32 {
    set_error(msg);
    code
}

// ---------------------------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------------------------

/// Called on the shim's runtime thread before it starts driving iroh, so the host can pin
/// it to a core and raise its priority (MMCSS, QoS class, SCHED_FIFO...).
pub type IrohThreadStartFn = Option<unsafe extern "C" fn(ctx: *mut std::ffi::c_void)>;

struct ThreadHook(IrohThreadStartFn, usize);

static THREAD_HOOK: Mutex<Option<ThreadHook>> = Mutex::new(None);
static RUNTIME: OnceLock<tokio::runtime::Handle> = OnceLock::new();

/// The shim runs iroh on one dedicated thread with a current-thread tokio runtime.
/// S4 measured a shared multi-thread runtime at 1-4 ms p99 handoff under CPU load;
/// one pinned, high-priority shim thread stayed at 100-400 us.
fn runtime() -> &'static tokio::runtime::Handle {
    RUNTIME.get_or_init(|| {
        apprate::epoch();
        let hook = THREAD_HOOK.lock().unwrap().take();
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("iroh-shim".into())
            .spawn(move || {
                if let Some(ThreadHook(Some(f), ctx)) = hook {
                    unsafe { f(ctx as *mut std::ffi::c_void) };
                }
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("failed to start tokio runtime");
                tx.send(rt.handle().clone()).unwrap();
                rt.block_on(std::future::pending::<()>());
            })
            .expect("failed to spawn iroh-shim thread");
        rx.recv().expect("iroh-shim thread died during startup")
    })
}

/// Runs `fut` on the shim thread and blocks the calling thread until it finishes.
fn run<F>(fut: F) -> F::Output
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    runtime().spawn(async move {
        let _ = tx.send(fut.await);
    });
    rx.recv().expect("iroh-shim runtime stopped")
}

/// Runs `fut` on the shim thread with a timeout. A zero timeout polls `fut` once.
fn block_on_timeout<F>(timeout_ms: u32, fut: F) -> Result<F::Output, tokio::time::error::Elapsed>
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let d = Duration::from_millis(timeout_ms as u64);
    run(async move { tokio::time::timeout(d, fut).await })
}

/// Optional. Registers a callback run on the shim's runtime thread when it starts.
/// Must be called before any other shim call; returns IROH_ERR_INVALID afterwards.
#[unsafe(no_mangle)]
pub extern "C" fn iroh_shim_init(on_thread_start: IrohThreadStartFn, ctx: *mut std::ffi::c_void) -> i32 {
    if RUNTIME.get().is_some() {
        return fail(IROH_ERR_INVALID, "shim runtime already started");
    }
    *THREAD_HOOK.lock().unwrap() = Some(ThreadHook(on_thread_start, ctx as usize));
    runtime();
    IROH_OK
}

/// Returns the shim ABI version as (major << 16) | (minor << 8) | patch.
#[unsafe(no_mangle)]
pub extern "C" fn iroh_shim_version() -> u32 {
    0x00_02_01
}

/// Microseconds on the shim's monotonic clock (the clock event timestamps use).
#[unsafe(no_mangle)]
pub extern "C" fn iroh_shim_now_us() -> u64 {
    apprate::now_us()
}

/// Returns the last error message for the calling thread (never NULL).
#[unsafe(no_mangle)]
pub extern "C" fn iroh_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

// ---------------------------------------------------------------------------------------------
// Endpoint
// ---------------------------------------------------------------------------------------------

/// Options for `iroh_endpoint_bind`. All pointers may be NULL and all numbers 0 (= default).
#[repr(C)]
pub struct IrohBindOpts {
    /// 32-byte Ed25519 secret key; NULL generates a fresh key.
    pub secret_key: *const u8,
    /// ALPN accepted for incoming connections (required to accept; may be NULL for dial-only).
    pub alpn: *const u8,
    pub alpn_len: usize,
    /// One of IROH_RELAY_*.
    pub relay_mode: u32,
    /// Newline-separated relay URLs, used with IROH_RELAY_CUSTOM and IROH_RELAY_CUSTOM_ONLY.
    pub relay_urls: *const c_char,
    /// Optional IPv4 bind address such as "127.0.0.1:0" or "0.0.0.0:4433".
    pub bind_addr: *const c_char,
    /// QUIC datagram send buffer in bytes (default 1 MiB). Must hold the largest frame.
    pub datagram_send_buffer: usize,
    /// QUIC datagram receive buffer in bytes (default 2 MiB).
    pub datagram_recv_buffer: usize,
    /// Datagrams the shim buffers for the caller before dropping (default 4096).
    pub recv_queue_len: u32,
    /// Per-path idle timeout in ms (default 300).
    pub path_idle_timeout_ms: u32,
    /// Per-path keep-alive interval in ms (default 100).
    pub path_keepalive_ms: u32,
    /// Connection idle timeout in ms (default: iroh's).
    pub conn_idle_timeout_ms: u32,
    /// Target send rate for new connections in bits/s (default 0 = unpaced until set).
    pub initial_target_bps: u64,
    /// AppRate burst credit in us of the target rate (default 20000; IROH_BURST_OFF = none).
    pub burst_us: u32,
    /// Stall on the selected path that raises IROH_EV_NO_ACK_PROGRESS, in ms
    /// (default 150; IROH_NO_ACK_OFF disables the event). The shim never uses less than
    /// 1.5 x the path's RTT + 25 ms, so a long path's normal ack delay is not a stall.
    pub no_ack_progress_ms: u32,
    /// Extra trusted root certificates (PEM, NUL-terminated, one or more CERTIFICATE blocks) for
    /// the TLS that relays and discovery use, on top of the built-in web roots. For a relay
    /// with a private CA (relay/lab-cert.sh); NULL = built-in roots only.
    pub relay_ca_pem: *const c_char,
}

#[derive(Clone, Copy, Debug)]
struct ConnConfig {
    send_buffer: usize,
    recv_buffer: usize,
    recv_queue: usize,
    path_idle: Duration,
    path_keepalive: Duration,
    conn_idle: Option<Duration>,
    target_bps: u64,
    burst_us: u64,
    no_ack_us: Option<u64>,
}

fn or<T: PartialEq + Default>(v: T, d: T) -> T {
    if v == T::default() { d } else { v }
}

impl ConnConfig {
    fn from_opts(o: &IrohBindOpts) -> Result<Self, String> {
        let path_idle = or(o.path_idle_timeout_ms, DEFAULT_PATH_IDLE_MS);
        let path_keepalive = or(o.path_keepalive_ms, DEFAULT_PATH_KEEPALIVE_MS);
        if path_keepalive >= path_idle {
            return Err(format!("path keep-alive ({path_keepalive} ms) must be below the idle timeout ({path_idle} ms)"));
        }
        let send_buffer = or(o.datagram_send_buffer, DEFAULT_SEND_BUFFER);
        if send_buffer < 4096 {
            return Err("datagram_send_buffer must be at least 4096".into());
        }
        Ok(Self {
            send_buffer,
            recv_buffer: or(o.datagram_recv_buffer, DEFAULT_RECV_BUFFER),
            recv_queue: or(o.recv_queue_len, DEFAULT_RECV_QUEUE) as usize,
            path_idle: Duration::from_millis(path_idle as u64),
            path_keepalive: Duration::from_millis(path_keepalive as u64),
            conn_idle: (o.conn_idle_timeout_ms != 0).then(|| Duration::from_millis(o.conn_idle_timeout_ms as u64)),
            target_bps: o.initial_target_bps,
            burst_us: match o.burst_us {
                IROH_BURST_OFF => 0,
                0 => DEFAULT_BURST_US as u64,
                v => v as u64,
            },
            no_ack_us: match o.no_ack_progress_ms {
                IROH_NO_ACK_OFF => None,
                0 => Some(DEFAULT_NO_ACK_MS as u64 * 1000),
                v => Some(v as u64 * 1000),
            },
        })
    }

    /// One transport config (and so one AppRate factory) per connection.
    fn transport(&self, factory: Arc<AppRateFactory>) -> Result<QuicTransportConfig, String> {
        let mut b = QuicTransportConfig::builder()
            .congestion_controller_factory(factory)
            .datagram_send_buffer_size(self.send_buffer)
            .datagram_receive_buffer_size(Some(self.recv_buffer))
            .default_path_max_idle_timeout(self.path_idle)
            .default_path_keep_alive_interval(self.path_keepalive);
        if let Some(d) = self.conn_idle {
            b = b.max_idle_timeout(Some(IdleTimeout::try_from(d).map_err(|e| format!("conn idle timeout: {e}"))?));
        }
        Ok(b.build())
    }
}

pub struct IrohEndpoint {
    ep: Endpoint,
    alpn: Vec<u8>,
    cfg: ConnConfig,
    /// Started by the first `iroh_endpoint_accept`.
    acceptor: Mutex<Option<Acceptor>>,
}

/// A handshake that completed, with the rate knob its transport config was built with.
type Accepted = (Connection, Arc<RateKnob>, Arc<AppRateFactory>);

/// Accepts incoming connections in the background and runs each handshake on its own task
/// (at most `MAX_HANDSHAKES`, each bounded by `ACCEPT_HANDSHAKE_TIMEOUT`), queueing the ones
/// that complete for `iroh_endpoint_accept`. So one peer that stalls its handshake holds
/// neither the caller nor anyone else's handshake.
struct Acceptor {
    rx: Arc<tokio::sync::Mutex<tokio::sync::mpsc::Receiver<Accepted>>>,
    task: tokio::task::AbortHandle,
}

impl Acceptor {
    fn start(endpoint: Endpoint, alpn: Vec<u8>, cfg: ConnConfig) -> Acceptor {
        let (tx, rx) = tokio::sync::mpsc::channel::<Accepted>(ACCEPTED_QUEUE);
        let task = runtime().spawn(async move {
            let mut running: VecDeque<tokio::task::AbortHandle> = VecDeque::new();
            while let Some(incoming) = endpoint.accept().await {
                running.retain(|h| !h.is_finished());
                if running.len() >= MAX_HANDSHAKES {
                    if let Some(oldest) = running.pop_front() {
                        oldest.abort();
                    }
                }
                let knob = Arc::new(RateKnob::new(cfg.target_bps, cfg.burst_us));
                let factory = AppRateFactory::new(knob.clone());
                let Ok(tc) = cfg.transport(factory.clone()) else { continue };
                let sc = endpoint.create_server_config_builder(vec![alpn.clone()]).set_transport_config(tc).build();
                let Ok(accepting) = incoming.accept_with(Arc::new(sc)) else { continue };
                let tx = tx.clone();
                let h = tokio::spawn(async move {
                    if let Ok(Ok(conn)) = tokio::time::timeout(ACCEPT_HANDSHAKE_TIMEOUT, accepting).await {
                        // Waits while the queue is full: the caller is slow to accept.
                        let _ = tx.send((conn, knob, factory)).await;
                    }
                });
                running.push_back(h.abort_handle());
            }
            for h in running {
                h.abort();
            }
        });
        Acceptor { rx: Arc::new(tokio::sync::Mutex::new(rx)), task: task.abort_handle() }
    }
}

unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, String> {
    if p.is_null() {
        return Ok(None);
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(Some)
        .map_err(|e| format!("invalid utf-8: {e}"))
}

unsafe fn bytes_arg<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p, len) } }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_bind(opts: *const IrohBindOpts, out: *mut *mut IrohEndpoint) -> i32 {
    if opts.is_null() || out.is_null() {
        return fail(IROH_ERR_INVALID, "null argument");
    }
    let opts = unsafe { &*opts };
    let cfg = match ConnConfig::from_opts(opts) {
        Ok(c) => c,
        Err(e) => return fail(IROH_ERR_INVALID, e),
    };
    let alpn = unsafe { bytes_arg(opts.alpn, opts.alpn_len) }.to_vec();
    let built = (|| -> Result<Endpoint, String> {
        let mut b = match opts.relay_mode {
            IROH_RELAY_DEFAULT => Endpoint::builder(presets::N0),
            IROH_RELAY_DISABLED => Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled),
            IROH_RELAY_CUSTOM | IROH_RELAY_CUSTOM_ONLY => {
                let urls = unsafe { opt_str(opts.relay_urls) }?.ok_or("relay_urls required")?;
                let urls = urls
                    .lines()
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .map(|u| RelayUrl::from_str(u).map_err(|e| format!("bad relay url {u}: {e}")))
                    .collect::<Result<Vec<_>, _>>()?;
                let preset = opts.relay_mode == IROH_RELAY_CUSTOM;
                if preset {
                    Endpoint::builder(presets::N0).relay_mode(RelayMode::custom(urls))
                } else {
                    Endpoint::builder(presets::Minimal).relay_mode(RelayMode::custom(urls))
                }
            }
            m => return Err(format!("unknown relay_mode {m}")),
        };
        if let Some(pem) = unsafe { opt_str(opts.relay_ca_pem) }? {
            let roots = CertificateDer::pem_slice_iter(pem.as_bytes())
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("bad relay_ca_pem: {e}"))?;
            if roots.is_empty() {
                return Err("relay_ca_pem holds no CERTIFICATE".into());
            }
            b = b.ca_tls_config(CaTlsConfig::embedded().with_extra_roots(roots));
        }
        if !opts.secret_key.is_null() {
            let mut k = [0u8; 32];
            k.copy_from_slice(unsafe { bytes_arg(opts.secret_key, 32) });
            b = b.secret_key(SecretKey::from_bytes(&k));
        }
        if !alpn.is_empty() {
            b = b.alpns(vec![alpn.clone()]);
        }
        if let Some(addr) = unsafe { opt_str(opts.bind_addr) }? {
            let sa = SocketAddr::from_str(addr).map_err(|e| format!("bad bind_addr {addr}: {e}"))?;
            b = b.clear_ip_transports().bind_addr(sa).map_err(|e| e.to_string())?;
        }
        run(b.bind()).map_err(|e| e.to_string())
    })();
    match built {
        Ok(ep) => {
            unsafe { *out = Box::into_raw(Box::new(IrohEndpoint { ep, alpn, cfg, acceptor: Mutex::new(None) })) };
            IROH_OK
        }
        Err(e) => fail(IROH_ERR_INTERNAL, e),
    }
}

/// Blocks until the endpoint has a home relay (or up to timeout_ms). Returns IROH_ERR_TIMEOUT on expiry.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_online(ep: *const IrohEndpoint, timeout_ms: u32) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    let endpoint = ep.ep.clone();
    match block_on_timeout(timeout_ms, async move { endpoint.online().await }) {
        Ok(()) => IROH_OK,
        Err(_) => fail(IROH_ERR_TIMEOUT, "timed out waiting for relay"),
    }
}

/// Writes the endpoint's ID (public key, z32/hex text) into buf, NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_id(ep: *const IrohEndpoint, buf: *mut c_char, cap: usize) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    unsafe { write_cstr(&ep.ep.id().to_string(), buf, cap, std::ptr::null_mut()) }
}

/// Writes a dialable ticket (EndpointTicket text) for this endpoint into buf, NUL-terminated.
/// `out_len` (optional) receives the length without the NUL, or the required length on IROH_ERR_TOO_SMALL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_ticket(
    ep: *const IrohEndpoint,
    buf: *mut c_char,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    let ticket = EndpointTicket::new(ep.ep.addr()).to_string();
    unsafe { write_cstr(&ticket, buf, cap, out_len) }
}

unsafe fn write_cstr(s: &str, buf: *mut c_char, cap: usize, out_len: *mut usize) -> i32 {
    if !out_len.is_null() {
        unsafe { *out_len = s.len() };
    }
    if buf.is_null() || cap < s.len() + 1 {
        return fail(IROH_ERR_TOO_SMALL, format!("buffer too small, need {}", s.len() + 1));
    }
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), buf as *mut u8, s.len());
        *buf.add(s.len()) = 0;
    }
    IROH_OK
}

/// Dials the endpoint described by `ticket` using `alpn`. Blocks up to timeout_ms.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_connect(
    ep: *const IrohEndpoint,
    ticket: *const c_char,
    alpn: *const u8,
    alpn_len: usize,
    timeout_ms: u32,
    out: *mut *mut IrohConn,
) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    let ticket = match unsafe { opt_str(ticket) } {
        Ok(Some(t)) => t,
        Ok(None) => return fail(IROH_ERR_INVALID, "null ticket"),
        Err(e) => return fail(IROH_ERR_INVALID, e),
    };
    let ticket = match EndpointTicket::from_str(ticket.trim()) {
        Ok(t) => t,
        Err(e) => return fail(IROH_ERR_INVALID, format!("bad ticket: {e}")),
    };
    let alpn = unsafe { bytes_arg(alpn, alpn_len) }.to_vec();
    let cfg = ep.cfg;
    let knob = Arc::new(RateKnob::new(cfg.target_bps, cfg.burst_us));
    let factory = AppRateFactory::new(knob.clone());
    let tc = match cfg.transport(factory.clone()) {
        Ok(tc) => tc,
        Err(e) => return fail(IROH_ERR_INVALID, e),
    };
    let endpoint = ep.ep.clone();
    let addr = ticket.endpoint_addr().clone();
    let fut = async move {
        let opts = ConnectOptions::new().with_transport_config(tc);
        endpoint.connect_with_opts(addr, &alpn, opts).await.map_err(|e| e.to_string())?.await.map_err(|e| e.to_string())
    };
    match block_on_timeout(timeout_ms, fut) {
        Ok(Ok(conn)) => match wrap_conn(conn, cfg, knob, factory) {
            Ok(c) => {
                unsafe { *out = c };
                IROH_OK
            }
            Err(e) => fail(IROH_ERR_INTERNAL, format!("connect: {e}")),
        },
        Ok(Err(e)) => fail(IROH_ERR_INTERNAL, format!("connect: {e}")),
        Err(_) => fail(IROH_ERR_TIMEOUT, "connect timed out"),
    }
}

/// Waits up to timeout_ms for an incoming connection whose handshake has completed.
/// Handshakes run in the background from the first call on (see `Acceptor`), each bounded
/// on its own, so the timeout bounds only the wait.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_accept(ep: *const IrohEndpoint, timeout_ms: u32, out: *mut *mut IrohConn) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    if ep.alpn.is_empty() {
        return fail(IROH_ERR_INVALID, "endpoint was bound without an ALPN (dial-only)");
    }
    if let Err(e) = ep.cfg.transport(AppRateFactory::new(Arc::new(RateKnob::new(ep.cfg.target_bps, ep.cfg.burst_us)))) {
        return fail(IROH_ERR_INVALID, e);
    }
    let rx = {
        let mut a = ep.acceptor.lock().unwrap();
        a.get_or_insert_with(|| Acceptor::start(ep.ep.clone(), ep.alpn.clone(), ep.cfg)).rx.clone()
    };
    let cfg = ep.cfg;
    let fut = async move {
        let mut rx = rx.lock().await;
        rx.recv().await
    };
    match block_on_timeout(timeout_ms, fut) {
        Err(_) => fail(IROH_ERR_TIMEOUT, "accept timed out"),
        Ok(None) => fail(IROH_ERR_CLOSED, "endpoint closed"),
        Ok(Some((conn, knob, factory))) => match wrap_conn(conn, cfg, knob, factory) {
            Ok(c) => {
                unsafe { *out = c };
                IROH_OK
            }
            Err(e) => fail(IROH_ERR_INTERNAL, format!("accept: {e}")),
        },
    }
}

/// Tells iroh the local network changed (interface up/down, new address, Wi-Fi to LTE), so
/// it re-runs its net report and tries new paths right away instead of on its own schedule.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_network_change(ep: *const IrohEndpoint) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    let endpoint = ep.ep.clone();
    runtime().spawn(async move { endpoint.network_change().await });
    IROH_OK
}

/// Closes the endpoint (gracefully, blocking briefly) and frees it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_free(ep: *mut IrohEndpoint) {
    if ep.is_null() {
        return;
    }
    let ep = unsafe { Box::from_raw(ep) };
    if let Some(a) = ep.acceptor.lock().unwrap().take() {
        a.task.abort();
    }
    run(async move { ep.ep.close().await });
}

// ---------------------------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------------------------

/// One path change or signal, polled with `iroh_conn_poll_event`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct IrohEvent {
    /// IROH_EV_*.
    pub kind: u32,
    /// Path the event is about, or IROH_PATH_NONE.
    pub path_id: u32,
    /// Shim clock (`iroh_shim_now_us`) when the shim saw the event.
    pub t_us: u64,
    /// LAGGED: events missed. NO_ACK_PROGRESS: stall in us. PATH_CLOSED: lost packets on the path.
    pub value: u64,
    /// 1 if the path goes through a relay.
    pub is_relay: u8,
    pub _pad: [u8; 7],
    /// Remote address of the path ("ip:port" or the relay URL), NUL-terminated, truncated.
    pub remote_addr: [c_char; 96],
}

impl IrohEvent {
    fn new(kind: u32, path_id: u32, value: u64) -> Self {
        Self { kind, path_id, t_us: apprate::now_us(), value, is_relay: 0, _pad: [0; 7], remote_addr: [0; 96] }
    }

    fn with_addr(mut self, a: &TransportAddr) -> Self {
        self.is_relay = a.is_relay() as u8;
        let s = match a {
            TransportAddr::Ip(sa) => sa.to_string(),
            TransportAddr::Relay(url) => url.to_string(),
            other => format!("{other:?}"),
        };
        let n = s.len().min(self.remote_addr.len() - 1);
        for (d, b) in self.remote_addr.iter_mut().zip(&s.as_bytes()[..n]) {
            *d = *b as c_char;
        }
        self
    }
}

#[derive(Default)]
struct TxState {
    /// Lengths of datagrams accepted but not yet known to be sent or evicted, oldest first.
    fifo: VecDeque<usize>,
    /// `frame_tx.datagram` at the last resolve.
    wire_base: u64,
}

struct Shared {
    knob: Arc<RateKnob>,
    factory: Arc<AppRateFactory>,
    cfg: ConnConfig,
    wake: Wakeup,
    /// Path ID -> its controller's counters.
    paths: Mutex<HashMap<u32, Arc<PathCounters>>>,
    selected_path: AtomicU32,
    /// Selections seen (PATH_SELECTED events), so a caller can see a change without events.
    selections: AtomicU32,
    /// A selected path whose controller could not be found yet: the monitor retries, so the
    /// target never stays on the old path's controller.
    pending_select: Mutex<Option<PathId>>,
    selected_id: Mutex<Option<PathId>>,
    events: Mutex<VecDeque<IrohEvent>>,
    events_dropped: AtomicU64,
    closed: AtomicBool,
    tx: Mutex<TxState>,
    tx_sent: AtomicU64,
    tx_wire: AtomicU64,
    tx_drops: AtomicU64,
    tx_queued: AtomicU64,
    rx_wire: AtomicU64,
    rx_from_quic: AtomicU64,
    rx_drops_quic: AtomicU64,
    rx_drops_shim: AtomicU64,
    rx_read: AtomicU64,
}

pub struct IrohConn {
    conn: Connection,
    sh: Arc<Shared>,
    rx: Mutex<Receiver<Bytes>>,
    tasks: Vec<tokio::task::AbortHandle>,
}

fn path_u32(id: PathId) -> u32 {
    id.to_string().parse().unwrap_or(IROH_PATH_NONE)
}

impl Shared {
    fn push_event(&self, ev: IrohEvent) {
        {
            let mut q = self.events.lock().unwrap();
            if q.len() >= EVENT_QUEUE {
                q.pop_front();
                self.events_dropped.fetch_add(1, Relaxed);
            }
            q.push_back(ev);
        }
        self.wake.signal();
    }

    fn mark_closed(&self) {
        if !self.closed.swap(true, Relaxed) {
            self.push_event(IrohEvent::new(IROH_EV_CONN_CLOSED, IROH_PATH_NONE, 0));
        }
    }

    /// Maps a path to its AppRate controller's counters (cached).
    fn counters(&self, conn: &Connection, id: PathId) -> Option<Arc<PathCounters>> {
        let key = path_u32(id);
        if let Some(c) = self.paths.lock().unwrap().get(&key) {
            return Some(c.clone());
        }
        let ctl = conn.congestion_state(id)?.into_any().downcast::<AppRate>().ok()?;
        self.paths.lock().unwrap().insert(key, ctl.counters.clone());
        Some(ctl.counters.clone())
    }

    /// Moves the target rate to `id`'s controller. If iroh has not built (or no longer
    /// reports) that controller yet, the move is retried by `retry_select`.
    fn select(&self, conn: &Connection, id: PathId) {
        self.selected_path.store(path_u32(id), Relaxed);
        *self.selected_id.lock().unwrap() = Some(id);
        let mut pending = self.pending_select.lock().unwrap();
        match self.counters(conn, id) {
            Some(c) => {
                self.knob.selected.store(c.ctl_index, Relaxed);
                *pending = None;
            }
            None => *pending = Some(id),
        }
    }

    fn retry_select(&self, conn: &Connection) {
        let id = *self.pending_select.lock().unwrap();
        if let Some(id) = id
            && path_u32(id) == self.selected_path.load(Relaxed)
        {
            self.select(conn, id);
        }
    }

    /// Keeps the target on the selected path's live controller. noq can replace a path's
    /// controller (a new one from the factory, with a new index) without a path event, which
    /// would leave the target on the old one and the path paced at `IDLE_PATH_BPS`.
    fn check_selected(&self, conn: &Connection) {
        let Some(id) = *self.selected_id.lock().unwrap() else { return };
        if self.pending_select.lock().unwrap().is_some() {
            return;
        }
        let key = path_u32(id);
        let Some(ctl) = conn.congestion_state(id).and_then(|c| c.into_any().downcast::<AppRate>().ok()) else { return };
        let index = ctl.counters.ctl_index;
        if self.knob.selected.load(Relaxed) != index {
            self.paths.lock().unwrap().insert(key, ctl.counters.clone());
            self.knob.selected.store(index, Relaxed);
            eprintln!("iroh-shim: path {key} has a new congestion controller ({index}); the target moved to it");
        }
    }

    /// The stall that counts as no ack progress on a path: the configured threshold, but at
    /// least 1.5 x its RTT (the larger of smoothed and latest) plus QUIC's 25 ms max ack delay,
    /// since an idle path's keep-alive is unacked for a whole RTT.
    fn stall_threshold(&self, c: &PathCounters) -> Option<u64> {
        self.cfg.no_ack_us.map(|t| t.max(c.rtt_cons_us.load(Relaxed) * 3 / 2 + 25_000))
    }

    /// Resolves which accepted datagrams have left the send buffer and how many were evicted.
    ///
    /// noq's send buffer is a FIFO: transmission and eviction both pop the front, so its
    /// contents are always the newest suffix of what we accepted. Its payload size (from
    /// `datagram_send_buffer_space`) tells us where that suffix starts; everything before it
    /// either went on the wire (`frame_tx.datagram`) or was evicted. Caller holds `tx`.
    fn resolve_tx(&self, conn: &Connection, st: &mut TxState) {
        // A consistent (space, stats) pair: no pop happened in between if space didn't move.
        let (mut space, mut stats);
        let mut tries = 0;
        loop {
            space = conn.datagram_send_buffer_space();
            stats = conn.stats();
            tries += 1;
            if conn.datagram_send_buffer_space() == space || tries >= 8 {
                break;
            }
        }
        let payload = self.cfg.send_buffer.saturating_sub(DGRAM_OVERHEAD).saturating_sub(space);
        let mut sum = 0usize;
        let mut k = st.fifo.len();
        while k > 0 && sum < payload {
            k -= 1;
            sum += st.fifo[k];
        }
        let wire = stats.frame_tx.datagram;
        let wire_delta = wire.saturating_sub(st.wire_base);
        let resolved = k as u64;
        if resolved > wire_delta {
            self.tx_drops.fetch_add(resolved - wire_delta, Relaxed);
        }
        st.fifo.drain(..k);
        st.wire_base = wire;
        self.tx_wire.store(wire, Relaxed);
        self.tx_queued.store(st.fifo.len() as u64, Relaxed);
    }
}

/// Wraps an established connection. Fails (closing the connection) only if the wakeup socket
/// pair cannot be made, e.g. when the process is out of file descriptors: with
/// `panic = "abort"` a panic here would let a peer that opens connections end the process.
fn wrap_conn(
    conn: Connection,
    cfg: ConnConfig,
    knob: Arc<RateKnob>,
    factory: Arc<AppRateFactory>,
) -> Result<*mut IrohConn, String> {
    let wake = match Wakeup::new() {
        Ok(w) => w,
        Err(e) => {
            conn.close(0u32.into(), b"");
            return Err(format!("wakeup socket: {e}"));
        }
    };
    let (tx, rx): (SyncSender<Bytes>, _) = std::sync::mpsc::sync_channel(cfg.recv_queue);
    let sh = Arc::new(Shared {
        knob,
        factory,
        cfg,
        wake,
        paths: Mutex::new(HashMap::new()),
        selected_path: AtomicU32::new(IROH_PATH_NONE),
        selections: AtomicU32::new(0),
        pending_select: Mutex::new(None),
        selected_id: Mutex::new(None),
        events: Mutex::new(VecDeque::new()),
        events_dropped: AtomicU64::new(0),
        closed: AtomicBool::new(false),
        tx: Mutex::new(TxState { fifo: VecDeque::new(), wire_base: conn.stats().frame_tx.datagram }),
        tx_sent: AtomicU64::new(0),
        tx_wire: AtomicU64::new(0),
        tx_drops: AtomicU64::new(0),
        tx_queued: AtomicU64::new(0),
        rx_wire: AtomicU64::new(0),
        rx_from_quic: AtomicU64::new(0),
        rx_drops_quic: AtomicU64::new(0),
        rx_drops_shim: AtomicU64::new(0),
        rx_read: AtomicU64::new(0),
    });
    // Subscribe before reading the current selection so no change falls in between.
    let mut events = conn.path_events();
    for p in conn.paths().iter() {
        if p.is_selected() {
            sh.select(&conn, p.id());
        }
    }
    let mut tasks = Vec::new();

    // Datagram reader: drains QUIC's receive buffer into the shim queue. On the
    // current-thread runtime nothing else runs between a drain and the stats read, so
    // `frame_rx.datagram - read` is exactly what QUIC's buffer dropped.
    {
        let (conn, sh) = (conn.clone(), sh.clone());
        tasks.push(
            runtime()
                .spawn(async move {
                    const BATCH: usize = 64;
                    let mut batch: Vec<Bytes> = vec![Bytes::new(); BATCH];
                    while let Ok(n) = conn.read_many_datagrams(&mut batch).await {
                        for d in batch.iter_mut().take(n) {
                            match tx.try_send(std::mem::take(d)) {
                                Ok(()) => {}
                                Err(TrySendError::Full(_)) => {
                                    sh.rx_drops_shim.fetch_add(1, Relaxed);
                                }
                                Err(TrySendError::Disconnected(_)) => return,
                            }
                        }
                        let total = sh.rx_from_quic.fetch_add(n as u64, Relaxed) + n as u64;
                        if n < BATCH {
                            let wire = conn.stats().frame_rx.datagram;
                            sh.rx_wire.store(wire, Relaxed);
                            sh.rx_drops_quic.store(wire.saturating_sub(total), Relaxed);
                        }
                        sh.wake.signal();
                    }
                    sh.mark_closed();
                })
                .abort_handle(),
        );
    }

    // Path events: forward to the caller and move the target rate on selection.
    {
        let (conn, sh) = (conn.clone(), sh.clone());
        tasks.push(
            runtime()
                .spawn(async move {
                    while let Some(ev) = events.next().await {
                        let ev = match ev {
                            PathEvent::Opened { id, remote_addr, .. } => {
                                let _ = sh.counters(&conn, id);
                                IrohEvent::new(IROH_EV_PATH_OPENED, path_u32(id), 0).with_addr(&remote_addr)
                            }
                            PathEvent::Selected { id, remote_addr, .. } => {
                                sh.select(&conn, id);
                                sh.selections.fetch_add(1, Relaxed);
                                IrohEvent::new(IROH_EV_PATH_SELECTED, path_u32(id), 0).with_addr(&remote_addr)
                            }
                            PathEvent::Closed { id, remote_addr, last_stats, .. } => {
                                sh.paths.lock().unwrap().remove(&path_u32(id));
                                IrohEvent::new(IROH_EV_PATH_CLOSED, path_u32(id), last_stats.lost_packets)
                                    .with_addr(&remote_addr)
                            }
                            PathEvent::Lagged { missed, .. } => IrohEvent::new(IROH_EV_LAGGED, IROH_PATH_NONE, missed),
                            _ => continue,
                        };
                        sh.push_event(ev);
                    }
                })
                .abort_handle(),
        );
    }

    // No-ack-progress monitor on the selected path; also retries a pending target move.
    {
        let (conn, sh) = (conn.clone(), sh.clone());
        tasks.push(
            runtime()
                .spawn(async move {
                    let mut tick = tokio::time::interval(MONITOR_TICK);
                    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                    let mut stalled = false;
                    loop {
                        tick.tick().await;
                        if conn.close_reason().is_some() {
                            sh.mark_closed();
                            return;
                        }
                        sh.retry_select(&conn);
                        sh.check_selected(&conn);
                        let sel = sh.knob.selected.load(Relaxed);
                        let ctl = {
                            let built = sh.factory.built.lock().unwrap();
                            if sel == NO_SELECTION { built.first().cloned() } else { built.get(sel as usize).cloned() }
                        };
                        let Some(ctl) = ctl else { continue };
                        let Some(threshold) = sh.stall_threshold(&ctl) else { continue };
                        let stall = ctl.ack_stall_us(apprate::now_us());
                        let path = sh.selected_path.load(Relaxed);
                        if !stalled && stall >= threshold {
                            stalled = true;
                            sh.push_event(IrohEvent::new(IROH_EV_NO_ACK_PROGRESS, path, stall));
                        } else if stalled && stall < threshold {
                            stalled = false;
                            sh.push_event(IrohEvent::new(IROH_EV_ACK_RESUMED, path, 0));
                        }
                    }
                })
                .abort_handle(),
        );
    }

    Ok(Box::into_raw(Box::new(IrohConn { conn, sh, rx: Mutex::new(rx), tasks })))
}

// ---------------------------------------------------------------------------------------------
// Datagrams
// ---------------------------------------------------------------------------------------------

/// Queues one unreliable datagram. Never blocks; the shim copies the bytes. If the send buffer
/// is full, the oldest queued datagrams are evicted (and counted in `send_drops`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_send_datagram(c: *const IrohConn, buf: *const u8, len: usize) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    if len == 0 {
        return fail(IROH_ERR_INVALID, "empty datagram");
    }
    let data = Bytes::copy_from_slice(unsafe { bytes_arg(buf, len) });
    let sh = &c.sh;
    let mut st = sh.tx.lock().unwrap();
    // Space only grows behind our back (the runtime pops); pushes happen under `tx`. So if
    // even counting every unresolved entry as queued the new datagram fits, nothing is evicted.
    let space = c.conn.datagram_send_buffer_space();
    let worst = sh.cfg.send_buffer.saturating_sub(DGRAM_OVERHEAD).saturating_sub(space)
        + st.fifo.len() * DGRAM_OVERHEAD;
    let may_evict = worst + len > sh.cfg.send_buffer;
    match c.conn.send_datagram(data) {
        Ok(()) => {}
        Err(iroh::endpoint::SendDatagramError::ConnectionLost(e)) => {
            return fail(IROH_ERR_CLOSED, format!("send_datagram: {e}"));
        }
        Err(iroh::endpoint::SendDatagramError::TooLarge) => {
            return fail(IROH_ERR_TOO_SMALL, "datagram larger than iroh_conn_max_datagram_size");
        }
        Err(e) => return fail(IROH_ERR_INTERNAL, format!("send_datagram: {e}")),
    }
    st.fifo.push_back(len);
    sh.tx_sent.fetch_add(1, Relaxed);
    if may_evict || st.fifo.len() >= TX_FIFO_RESOLVE {
        sh.resolve_tx(&c.conn, &mut st);
    }
    IROH_OK
}

/// Receives one datagram into buf. timeout_ms == 0 is non-blocking (IROH_ERR_AGAIN if empty).
/// On success `*out_len` is the datagram length. If cap is too small the datagram is dropped,
/// `*out_len` is set to its size and IROH_ERR_TOO_SMALL is returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_recv_datagram(
    c: *const IrohConn,
    buf: *mut u8,
    cap: usize,
    timeout_ms: u32,
    out_len: *mut usize,
) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    let rx = c.rx.lock().unwrap();
    let d = if timeout_ms == 0 {
        match rx.try_recv() {
            Ok(d) => d,
            Err(TryRecvError::Empty) => return IROH_ERR_AGAIN,
            Err(TryRecvError::Disconnected) => return fail(IROH_ERR_CLOSED, "connection closed"),
        }
    } else {
        match rx.recv_timeout(Duration::from_millis(timeout_ms as u64)) {
            Ok(d) => d,
            Err(RecvTimeoutError::Timeout) => return IROH_ERR_TIMEOUT,
            Err(RecvTimeoutError::Disconnected) => return fail(IROH_ERR_CLOSED, "connection closed"),
        }
    };
    c.sh.rx_read.fetch_add(1, Relaxed);
    if !out_len.is_null() {
        unsafe { *out_len = d.len() };
    }
    if d.len() > cap || (buf.is_null() && !d.is_empty()) {
        return fail(IROH_ERR_TOO_SMALL, "datagram larger than buffer");
    }
    // `copy_nonoverlapping` needs non-null pointers even for zero bytes, and a peer can send
    // an empty datagram into a NULL buffer.
    if !d.is_empty() {
        unsafe { std::ptr::copy_nonoverlapping(d.as_ptr(), buf, d.len()) };
    }
    IROH_OK
}

/// Largest datagram payload the peer currently accepts (0 if datagrams are unsupported).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_max_datagram_size(c: *const IrohConn) -> usize {
    unsafe { c.as_ref() }.and_then(|c| c.conn.max_datagram_size()).unwrap_or(0)
}

/// Datagrams dropped inside the shim because the caller did not drain the queue fast enough.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_local_drops(c: *const IrohConn) -> u64 {
    unsafe { c.as_ref() }.map(|c| c.sh.rx_drops_shim.load(Relaxed)).unwrap_or(0)
}

/// Writes the remote endpoint ID into buf, NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_remote_id(c: *const IrohConn, buf: *mut c_char, cap: usize) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    unsafe { write_cstr(&c.conn.remote_id().to_string(), buf, cap, std::ptr::null_mut()) }
}

/// Closes the connection with an application error code and frees the handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_free(c: *mut IrohConn, error_code: u32) {
    if c.is_null() {
        return;
    }
    let c = unsafe { Box::from_raw(c) };
    c.conn.close(error_code.into(), b"");
    for t in &c.tasks {
        t.abort();
    }
}

// ---------------------------------------------------------------------------------------------
// Rate, wakeup, events, stats
// ---------------------------------------------------------------------------------------------

/// Sets the pacing target (bits/s) for the connection's selected path; 0 removes pacing.
/// This is the core's capacity estimate, not the encoder bitrate. It moves with the path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_set_target_bitrate(c: *const IrohConn, bps: u64) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    c.sh.knob.target_bps.store(bps, Relaxed);
    IROH_OK
}

/// Sets AppRate's burst credit in microseconds of the target rate (0 = none).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_set_burst(c: *const IrohConn, burst_us: u32) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    c.sh.knob.burst_us.store(burst_us as u64, Relaxed);
    IROH_OK
}

/// The connection's pollable wakeup handle: an fd on Unix, a SOCKET on Windows. It becomes
/// readable when a datagram or event arrives or the connection closes. Valid until
/// `iroh_conn_free`. Call `iroh_conn_wakeup_clear` before draining.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_wakeup_handle(c: *const IrohConn) -> i64 {
    unsafe { c.as_ref() }.map(|c| c.sh.wake.handle()).unwrap_or(-1)
}

/// Drains the wakeup handle and re-arms it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_wakeup_clear(c: *const IrohConn) {
    if let Some(c) = unsafe { c.as_ref() } {
        c.sh.wake.clear();
    }
}

/// Pops the oldest pending event into `*out`. IROH_ERR_AGAIN if there is none.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_poll_event(c: *const IrohConn, out: *mut IrohEvent) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    match c.sh.events.lock().unwrap().pop_front() {
        Some(ev) => {
            unsafe { *out = ev };
            IROH_OK
        }
        None => IROH_ERR_AGAIN,
    }
}

/// Connection-wide counters. Datagram accounting is exact:
/// `dgram_sent == dgram_tx_wire + dgram_send_drops + dgram_send_queued` and
/// `dgram_rx_wire == dgram_read + dgram_recv_drops_quic + dgram_recv_drops_shim + dgram_recv_queued`
/// (the receive side once the shim's reader has drained QUIC's buffer).
#[repr(C)]
#[derive(Default)]
pub struct IrohConnStats {
    pub dgram_sent: u64,
    pub dgram_tx_wire: u64,
    pub dgram_send_drops: u64,
    pub dgram_send_queued: u64,
    pub dgram_rx_wire: u64,
    pub dgram_read: u64,
    pub dgram_recv_drops_quic: u64,
    pub dgram_recv_drops_shim: u64,
    pub dgram_recv_queued: u64,
    pub sent_packets: u64,
    pub lost_packets: u64,
    pub lost_bytes: u64,
    pub udp_tx_bytes: u64,
    pub udp_rx_bytes: u64,
    pub target_bps: u64,
    pub events_dropped: u64,
    pub selected_path: u32,
    pub path_count: u32,
    pub closed: u32,
    /// PATH_SELECTED events so far (a change of selected path bumps it).
    pub path_selections: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_stats(c: *const IrohConn, out: *mut IrohConnStats) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    let sh = &c.sh;
    {
        let mut st = sh.tx.lock().unwrap();
        sh.resolve_tx(&c.conn, &mut st);
    }
    let s = c.conn.stats();
    let rx_from_quic = sh.rx_from_quic.load(Relaxed);
    let read = sh.rx_read.load(Relaxed);
    let drops_shim = sh.rx_drops_shim.load(Relaxed);
    let o = IrohConnStats {
        dgram_sent: sh.tx_sent.load(Relaxed),
        dgram_tx_wire: sh.tx_wire.load(Relaxed),
        dgram_send_drops: sh.tx_drops.load(Relaxed),
        dgram_send_queued: sh.tx_queued.load(Relaxed),
        dgram_rx_wire: sh.rx_wire.load(Relaxed).max(rx_from_quic),
        dgram_read: read,
        dgram_recv_drops_quic: sh.rx_drops_quic.load(Relaxed),
        dgram_recv_drops_shim: drops_shim,
        dgram_recv_queued: rx_from_quic.saturating_sub(read + drops_shim),
        sent_packets: s.sent_packets,
        lost_packets: s.lost_packets,
        lost_bytes: s.lost_bytes,
        udp_tx_bytes: s.udp_tx.bytes,
        udp_rx_bytes: s.udp_rx.bytes,
        target_bps: sh.knob.target_bps.load(Relaxed),
        events_dropped: sh.events_dropped.load(Relaxed),
        selected_path: sh.selected_path.load(Relaxed),
        path_count: c.conn.paths().len() as u32,
        closed: (sh.closed.load(Relaxed) || c.conn.close_reason().is_some()) as u32,
        path_selections: sh.selections.load(Relaxed),
    };
    unsafe { *out = o };
    IROH_OK
}

/// Per-path stats, from iroh and from the path's AppRate controller.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct IrohPathStats {
    pub path_id: u32,
    pub is_relay: u8,
    pub is_selected: u8,
    /// 1 if the stall below exceeds the connection's no-ack-progress threshold.
    pub no_ack_progress: u8,
    pub _pad: u8,
    pub rtt_us: u64,
    pub min_rtt_us: u64,
    pub cwnd: u64,
    pub mtu: u64,
    pub sent_packets: u64,
    pub sent_bytes: u64,
    pub lost_packets: u64,
    pub lost_bytes: u64,
    pub congestion_events: u64,
    pub udp_tx_datagrams: u64,
    pub udp_rx_datagrams: u64,
    /// Base pacing rate this path's controller last reported (bits/s, 0 = unpaced).
    pub pacing_bps: u64,
    /// How long sent data has gone unacknowledged on this path, us (0 = all acked).
    pub ack_stall_us: u64,
    /// Shim clock time of the last ack on this path (0 = none yet).
    pub last_ack_us: u64,
    /// Remote address ("ip:port" or relay URL), NUL-terminated, truncated.
    pub remote_addr: [c_char; 96],
}

/// Writes up to `cap` path stats into `out`; `*out_n` receives the number of paths (which may
/// exceed `cap`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_path_stats(
    c: *const IrohConn,
    out: *mut IrohPathStats,
    cap: usize,
    out_n: *mut usize,
) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    let now = apprate::now_us();
    let paths = c.conn.paths();
    let mut n = 0usize;
    for p in paths.iter() {
        if n < cap && !out.is_null() {
            let s = p.stats();
            let ctl = c.sh.counters(&c.conn, p.id());
            let ld = |f: fn(&PathCounters) -> &AtomicU64| ctl.as_ref().map(|k| f(k).load(Relaxed)).unwrap_or(0);
            let stall = ctl.as_ref().map(|k| k.ack_stall_us(now)).unwrap_or(0);
            let row = IrohPathStats {
                path_id: path_u32(p.id()),
                is_relay: p.is_relay() as u8,
                is_selected: p.is_selected() as u8,
                no_ack_progress: ctl.as_ref().and_then(|k| c.sh.stall_threshold(k)).is_some_and(|t| stall >= t) as u8,
                _pad: 0,
                rtt_us: s.rtt.as_micros() as u64,
                min_rtt_us: ld(|k| &k.min_rtt_us),
                cwnd: s.cwnd,
                mtu: s.current_mtu as u64,
                sent_packets: s.sent_packets,
                sent_bytes: s.sent_bytes,
                lost_packets: s.lost_packets,
                lost_bytes: s.lost_bytes,
                congestion_events: s.congestion_events,
                udp_tx_datagrams: s.udp_tx.datagrams,
                udp_rx_datagrams: s.udp_rx.datagrams,
                pacing_bps: ld(|k| &k.pacing_bps),
                ack_stall_us: stall,
                last_ack_us: ld(|k| &k.last_ack_us),
                remote_addr: IrohEvent::new(0, 0, 0).with_addr(p.remote_addr()).remote_addr,
            };
            unsafe { *out.add(n) = row };
        }
        n += 1;
    }
    if !out_n.is_null() {
        unsafe { *out_n = n };
    }
    IROH_OK
}

// ---------------------------------------------------------------------------------------------
// Bidirectional streams
// ---------------------------------------------------------------------------------------------

pub struct IrohStream {
    send: Arc<tokio::sync::Mutex<SendStream>>,
    recv: Arc<tokio::sync::Mutex<RecvStream>>,
}

fn wrap_stream((send, recv): (SendStream, RecvStream)) -> *mut IrohStream {
    Box::into_raw(Box::new(IrohStream {
        send: Arc::new(tokio::sync::Mutex::new(send)),
        recv: Arc::new(tokio::sync::Mutex::new(recv)),
    }))
}

/// Opens a bidirectional stream. QUIC opens streams lazily: the peer's accept returns once
/// the first bytes are written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_open_bi(c: *const IrohConn, timeout_ms: u32, out: *mut *mut IrohStream) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    let conn = c.conn.clone();
    match block_on_timeout(timeout_ms, async move { conn.open_bi().await }) {
        Ok(Ok(s)) => {
            unsafe { *out = wrap_stream(s) };
            IROH_OK
        }
        Ok(Err(e)) => fail(IROH_ERR_CLOSED, format!("open_bi: {e}")),
        Err(_) => fail(IROH_ERR_TIMEOUT, "open_bi timed out"),
    }
}

/// Accepts a bidirectional stream opened by the peer (timeout_ms == 0 polls once).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_accept_bi(c: *const IrohConn, timeout_ms: u32, out: *mut *mut IrohStream) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    let conn = c.conn.clone();
    match block_on_timeout(timeout_ms, async move { conn.accept_bi().await }) {
        Ok(Ok(s)) => {
            unsafe { *out = wrap_stream(s) };
            IROH_OK
        }
        Ok(Err(e)) => fail(IROH_ERR_CLOSED, format!("accept_bi: {e}")),
        Err(_) if timeout_ms == 0 => IROH_ERR_AGAIN,
        Err(_) => fail(IROH_ERR_TIMEOUT, "accept_bi timed out"),
    }
}

/// Writes all of `buf` (blocking up to timeout_ms for flow control).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_stream_write(s: *const IrohStream, buf: *const u8, len: usize, timeout_ms: u32) -> i32 {
    let Some(s) = (unsafe { s.as_ref() }) else { return fail(IROH_ERR_INVALID, "null stream") };
    let data = unsafe { bytes_arg(buf, len) }.to_vec();
    let send = s.send.clone();
    match block_on_timeout(timeout_ms, async move { send.lock().await.write_all(&data).await }) {
        Ok(Ok(())) => IROH_OK,
        Ok(Err(e)) => fail(IROH_ERR_CLOSED, format!("write: {e}")),
        Err(_) => fail(IROH_ERR_TIMEOUT, "write timed out"),
    }
}

/// Writes as much of `buf` as the stream takes now, up to `timeout_ms` for the first byte
/// (`timeout_ms == 0` polls once: IROH_ERR_AGAIN when flow control has no room). Unlike
/// `iroh_stream_write`, a timeout never leaves part of `buf` written unreported, so it is safe
/// for non-blocking callers. Since ABI 0.2.1.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_stream_write_some(
    s: *const IrohStream,
    buf: *const u8,
    len: usize,
    timeout_ms: u32,
    out_written: *mut usize,
) -> i32 {
    let Some(s) = (unsafe { s.as_ref() }) else { return fail(IROH_ERR_INVALID, "null stream") };
    if out_written.is_null() {
        return fail(IROH_ERR_INVALID, "null out_written");
    }
    unsafe { *out_written = 0 };
    if len == 0 {
        return IROH_OK;
    }
    let data = unsafe { bytes_arg(buf, len) }.to_vec();
    let send = s.send.clone();
    // `SendStream::write` either writes some bytes and returns how many, or writes nothing,
    // so dropping it on the timeout loses no data.
    match block_on_timeout(timeout_ms, async move { send.lock().await.write(&data).await }) {
        Ok(Ok(n)) => {
            unsafe { *out_written = n };
            IROH_OK
        }
        Ok(Err(e)) => fail(IROH_ERR_CLOSED, format!("write: {e}")),
        Err(_) if timeout_ms == 0 => IROH_ERR_AGAIN,
        Err(_) => fail(IROH_ERR_TIMEOUT, "write timed out"),
    }
}

/// Reads up to `cap` bytes. `*out_len == 0` with IROH_OK means the peer finished the stream.
/// timeout_ms == 0 polls once (IROH_ERR_AGAIN if nothing is buffered).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_stream_read(
    s: *const IrohStream,
    buf: *mut u8,
    cap: usize,
    timeout_ms: u32,
    out_len: *mut usize,
) -> i32 {
    let Some(s) = (unsafe { s.as_ref() }) else { return fail(IROH_ERR_INVALID, "null stream") };
    if buf.is_null() || cap == 0 || out_len.is_null() {
        return fail(IROH_ERR_INVALID, "null or empty buffer");
    }
    let recv = s.recv.clone();
    match block_on_timeout(timeout_ms, async move { recv.lock().await.read_chunk(cap).await }) {
        Ok(Ok(Some(chunk))) => {
            unsafe {
                std::ptr::copy_nonoverlapping(chunk.as_ptr(), buf, chunk.len());
                *out_len = chunk.len();
            }
            IROH_OK
        }
        Ok(Ok(None)) => {
            unsafe { *out_len = 0 };
            IROH_OK
        }
        Ok(Err(e)) => fail(IROH_ERR_CLOSED, format!("read: {e}")),
        Err(_) if timeout_ms == 0 => IROH_ERR_AGAIN,
        Err(_) => fail(IROH_ERR_TIMEOUT, "read timed out"),
    }
}

/// Finishes the send side (the peer reads end-of-stream after the data).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_stream_finish(s: *const IrohStream) -> i32 {
    let Some(s) = (unsafe { s.as_ref() }) else { return fail(IROH_ERR_INVALID, "null stream") };
    let send = s.send.clone();
    match run(async move { send.lock().await.finish() }) {
        Ok(()) => IROH_OK,
        Err(e) => fail(IROH_ERR_CLOSED, format!("finish: {e}")),
    }
}

/// Frees the stream. A nonzero error_code resets the send side and stops the receive side;
/// 0 leaves an unfinished send side to be finished gracefully.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_stream_free(s: *mut IrohStream, error_code: u32) {
    if s.is_null() {
        return;
    }
    let s = unsafe { Box::from_raw(s) };
    run(async move {
        if error_code != 0 {
            let _ = s.send.lock().await.reset(error_code.into());
            let _ = s.recv.lock().await.stop(error_code.into());
        }
        drop(s);
    });
}

// ---------------------------------------------------------------------------------------------
// Boundary tests that need no runtime or sockets, so they also run under Miri:
//   cargo +nightly miri test --lib
// The calls that drive iroh are covered by the ASan fuzzer (fuzz/) and transport/iroh_test.zig.
// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn last_error() -> String {
        unsafe { CStr::from_ptr(iroh_last_error()) }.to_string_lossy().into_owned()
    }

    #[test]
    fn write_cstr_stays_inside_the_buffer() {
        let mut buf = [0x55u8; 8];
        let mut n = 0usize;
        // Exactly fits: 5 bytes + NUL, guard bytes untouched.
        let r = unsafe { write_cstr("hello", buf.as_mut_ptr() as *mut c_char, 6, &mut n) };
        assert_eq!(r, IROH_OK);
        assert_eq!(n, 5);
        assert_eq!(&buf[..6], b"hello\0");
        assert_eq!(&buf[6..], &[0x55, 0x55]);
        // One short: refused, nothing written, required length reported.
        let mut buf = [0x55u8; 8];
        let r = unsafe { write_cstr("hello", buf.as_mut_ptr() as *mut c_char, 5, &mut n) };
        assert_eq!(r, IROH_ERR_TOO_SMALL);
        assert_eq!(n, 5);
        assert_eq!(buf, [0x55u8; 8]);
        // NULL buffer and NULL out_len.
        let r = unsafe { write_cstr("x", std::ptr::null_mut(), 100, std::ptr::null_mut()) };
        assert_eq!(r, IROH_ERR_TOO_SMALL);
    }

    #[test]
    fn null_and_empty_arguments() {
        assert!(unsafe { bytes_arg(std::ptr::null(), 10) }.is_empty());
        let b = [1u8, 2];
        assert!(unsafe { bytes_arg(b.as_ptr(), 0) }.is_empty());
        assert_eq!(unsafe { opt_str(std::ptr::null()) }, Ok(None));
        let bad = [0xffu8, 0];
        assert!(unsafe { opt_str(bad.as_ptr() as *const c_char) }.is_err());

        let mut out: *mut IrohEndpoint = std::ptr::null_mut();
        assert_eq!(unsafe { iroh_endpoint_bind(std::ptr::null(), &mut out) }, IROH_ERR_INVALID);
        assert_eq!(unsafe { iroh_endpoint_online(std::ptr::null(), 0) }, IROH_ERR_INVALID);
        assert_eq!(unsafe { iroh_endpoint_id(std::ptr::null(), std::ptr::null_mut(), 0) }, IROH_ERR_INVALID);
        let mut conn: *mut IrohConn = std::ptr::null_mut();
        assert_eq!(unsafe { iroh_endpoint_accept(std::ptr::null(), 0, &mut conn) }, IROH_ERR_INVALID);
        assert_eq!(unsafe { iroh_conn_send_datagram(std::ptr::null(), b.as_ptr(), 2) }, IROH_ERR_INVALID);
        let mut n = 0usize;
        assert_eq!(
            unsafe { iroh_conn_recv_datagram(std::ptr::null(), std::ptr::null_mut(), 0, 0, &mut n) },
            IROH_ERR_INVALID
        );
        assert_eq!(unsafe { iroh_conn_max_datagram_size(std::ptr::null()) }, 0);
        assert_eq!(unsafe { iroh_conn_wakeup_handle(std::ptr::null()) }, -1);
        let mut s: *mut IrohStream = std::ptr::null_mut();
        assert_eq!(unsafe { iroh_conn_open_bi(std::ptr::null(), 0, &mut s) }, IROH_ERR_INVALID);
        assert_eq!(
            unsafe { iroh_stream_read(std::ptr::null(), std::ptr::null_mut(), 0, 0, &mut n) },
            IROH_ERR_INVALID
        );
        assert_eq!(unsafe { iroh_stream_finish(std::ptr::null()) }, IROH_ERR_INVALID);
        // Frees of NULL are no-ops.
        unsafe {
            iroh_endpoint_free(std::ptr::null_mut());
            iroh_conn_free(std::ptr::null_mut(), 0);
            iroh_stream_free(std::ptr::null_mut(), 0);
        }
        assert!(!last_error().is_empty());
    }

    fn zeroed_opts() -> IrohBindOpts {
        IrohBindOpts {
            secret_key: std::ptr::null(),
            alpn: std::ptr::null(),
            alpn_len: 0,
            relay_mode: 0,
            relay_urls: std::ptr::null(),
            bind_addr: std::ptr::null(),
            datagram_send_buffer: 0,
            datagram_recv_buffer: 0,
            recv_queue_len: 0,
            path_idle_timeout_ms: 0,
            path_keepalive_ms: 0,
            conn_idle_timeout_ms: 0,
            initial_target_bps: 0,
            burst_us: 0,
            no_ack_progress_ms: 0,
            relay_ca_pem: std::ptr::null(),
        }
    }

    #[test]
    fn bind_options_are_validated_before_anything_starts() {
        let c = ConnConfig::from_opts(&zeroed_opts()).unwrap();
        assert_eq!(c.send_buffer, DEFAULT_SEND_BUFFER);
        assert_eq!(c.burst_us, DEFAULT_BURST_US as u64);
        let mut o = zeroed_opts();
        o.path_idle_timeout_ms = 100;
        o.path_keepalive_ms = 100;
        assert!(ConnConfig::from_opts(&o).is_err());
        let mut o = zeroed_opts();
        o.datagram_send_buffer = 4095;
        assert!(ConnConfig::from_opts(&o).is_err());
        let mut o = zeroed_opts();
        o.burst_us = IROH_BURST_OFF;
        o.no_ack_progress_ms = IROH_NO_ACK_OFF;
        let c = ConnConfig::from_opts(&o).unwrap();
        assert_eq!(c.burst_us, 0);
        assert_eq!(c.no_ack_us, None);
        // A bad option fails in iroh_endpoint_bind without starting the runtime.
        let mut o = zeroed_opts();
        o.path_keepalive_ms = 5000;
        let mut out: *mut IrohEndpoint = std::ptr::null_mut();
        assert_eq!(unsafe { iroh_endpoint_bind(&o, &mut out) }, IROH_ERR_INVALID);
        assert!(out.is_null());
        assert!(last_error().contains("keep-alive"));
    }

    #[test]
    fn event_addresses_are_truncated_and_terminated() {
        let long = format!("https://{}.example/", "r".repeat(200));
        let ev = IrohEvent::new(1, 0, 0).with_addr(&TransportAddr::Relay(RelayUrl::from_str(&long).unwrap()));
        assert_eq!(ev.remote_addr[95], 0);
        assert_eq!(ev.is_relay, 1);
        let s = unsafe { CStr::from_ptr(ev.remote_addr.as_ptr()) }.to_str().unwrap();
        assert_eq!(s.len(), 95);
        assert!(long.starts_with(s));
    }
}
