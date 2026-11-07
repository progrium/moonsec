//! moonsec iroh shim: a minimal C ABI over iroh 1.x.
//!
//! Spike S1 surface: bind, connect (by ticket), accept, unreliable datagrams.
//! Conventions:
//! - Every function returns an `int32_t` status (0 = ok, negative = error) unless noted.
//! - On error, `iroh_last_error()` returns a thread-local, NUL-terminated message that
//!   stays valid until the next shim call on the same thread.
//! - The caller (Zig) owns every buffer that crosses the boundary; the shim never
//!   returns heap memory except opaque handles, which are freed with their `_free` call.
//! - Blocking calls run on a shared tokio runtime owned by the shim.
#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::net::SocketAddr;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TryRecvError, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use iroh::endpoint::{Connection, presets};
use iroh::{Endpoint, RelayMode, RelayUrl, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;

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

/// Inbound datagrams buffered per connection before the shim starts dropping (and counting).
const RECV_QUEUE: usize = 4096;

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

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("iroh-shim")
            .enable_all()
            .build()
            .expect("failed to start tokio runtime")
    })
}

/// Runs `fut` on the shim runtime with a timeout. The timer must be created inside the
/// runtime, so wrap it in an async block rather than building it on the caller's thread.
fn block_on_timeout<F: std::future::Future>(
    timeout_ms: u32,
    fut: F,
) -> Result<F::Output, tokio::time::error::Elapsed> {
    let d = Duration::from_millis(timeout_ms as u64);
    runtime().block_on(async move { tokio::time::timeout(d, fut).await })
}

pub struct IrohEndpoint {
    ep: Endpoint,
}

pub struct IrohConn {
    conn: Connection,
    rx: Mutex<Receiver<bytes::Bytes>>,
    dropped: Arc<AtomicU64>,
}

/// Options for `iroh_endpoint_bind`. All pointers may be NULL unless noted.
#[repr(C)]
pub struct IrohBindOpts {
    /// 32-byte Ed25519 secret key; NULL generates a fresh key.
    pub secret_key: *const u8,
    /// ALPN accepted for incoming connections (required to accept; may be NULL for dial-only).
    pub alpn: *const u8,
    pub alpn_len: usize,
    /// One of IROH_RELAY_*.
    pub relay_mode: u32,
    /// Newline-separated relay URLs, used when relay_mode == IROH_RELAY_CUSTOM.
    pub relay_urls: *const c_char,
    /// Optional IPv4 bind address such as "127.0.0.1:0" or "0.0.0.0:4433".
    pub bind_addr: *const c_char,
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

/// Returns the shim ABI version as (major << 16) | (minor << 8) | patch.
#[unsafe(no_mangle)]
pub extern "C" fn iroh_shim_version() -> u32 {
    0x00_01_00
}

/// Returns the last error message for the calling thread (never NULL).
#[unsafe(no_mangle)]
pub extern "C" fn iroh_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_bind(
    opts: *const IrohBindOpts,
    out: *mut *mut IrohEndpoint,
) -> i32 {
    if opts.is_null() || out.is_null() {
        return fail(IROH_ERR_INVALID, "null argument");
    }
    let opts = unsafe { &*opts };
    let built = (|| -> Result<Endpoint, String> {
        let mut b = match opts.relay_mode {
            IROH_RELAY_DEFAULT => Endpoint::builder(presets::N0),
            IROH_RELAY_DISABLED => Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled),
            IROH_RELAY_CUSTOM => {
                let urls = unsafe { opt_str(opts.relay_urls) }?.ok_or("relay_urls required")?;
                let urls = urls
                    .lines()
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .map(|u| RelayUrl::from_str(u).map_err(|e| format!("bad relay url {u}: {e}")))
                    .collect::<Result<Vec<_>, _>>()?;
                Endpoint::builder(presets::N0).relay_mode(RelayMode::custom(urls))
            }
            m => return Err(format!("unknown relay_mode {m}")),
        };
        if !opts.secret_key.is_null() {
            let mut k = [0u8; 32];
            k.copy_from_slice(unsafe { bytes_arg(opts.secret_key, 32) });
            b = b.secret_key(SecretKey::from_bytes(&k));
        }
        let alpn = unsafe { bytes_arg(opts.alpn, opts.alpn_len) };
        if !alpn.is_empty() {
            b = b.alpns(vec![alpn.to_vec()]);
        }
        if let Some(addr) = unsafe { opt_str(opts.bind_addr) }? {
            let sa = SocketAddr::from_str(addr).map_err(|e| format!("bad bind_addr {addr}: {e}"))?;
            b = b.clear_ip_transports().bind_addr(sa).map_err(|e| e.to_string())?;
        }
        runtime().block_on(b.bind()).map_err(|e| e.to_string())
    })();
    match built {
        Ok(ep) => {
            unsafe { *out = Box::into_raw(Box::new(IrohEndpoint { ep })) };
            IROH_OK
        }
        Err(e) => fail(IROH_ERR_INTERNAL, e),
    }
}

/// Blocks until the endpoint has a home relay (or up to timeout_ms). Returns IROH_ERR_TIMEOUT on expiry.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_online(ep: *const IrohEndpoint, timeout_ms: u32) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    let r = block_on_timeout(timeout_ms, ep.ep.online());
    match r {
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

fn wrap_conn(conn: Connection) -> *mut IrohConn {
    let (tx, rx): (SyncSender<bytes::Bytes>, _) = std::sync::mpsc::sync_channel(RECV_QUEUE);
    let dropped = Arc::new(AtomicU64::new(0));
    let reader = conn.clone();
    let drops = dropped.clone();
    runtime().spawn(async move {
        while let Ok(d) = reader.read_datagram().await {
            match tx.try_send(d) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => {
                    drops.fetch_add(1, Ordering::Relaxed);
                }
                Err(TrySendError::Disconnected(_)) => break,
            }
        }
    });
    Box::into_raw(Box::new(IrohConn { conn, rx: Mutex::new(rx), dropped }))
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
    let fut = ep.ep.connect(ticket.endpoint_addr().clone(), &alpn);
    match block_on_timeout(timeout_ms, fut) {
        Ok(Ok(conn)) => {
            unsafe { *out = wrap_conn(conn) };
            IROH_OK
        }
        Ok(Err(e)) => fail(IROH_ERR_INTERNAL, format!("connect: {e}")),
        Err(_) => fail(IROH_ERR_TIMEOUT, "connect timed out"),
    }
}

/// Waits up to timeout_ms for an incoming connection and completes its handshake.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_accept(
    ep: *const IrohEndpoint,
    timeout_ms: u32,
    out: *mut *mut IrohConn,
) -> i32 {
    let Some(ep) = (unsafe { ep.as_ref() }) else { return fail(IROH_ERR_INVALID, "null endpoint") };
    if out.is_null() {
        return fail(IROH_ERR_INVALID, "null out");
    }
    let endpoint = ep.ep.clone();
    let fut = async move {
        let incoming = endpoint.accept().await.ok_or((IROH_ERR_CLOSED, "endpoint closed".to_string()))?;
        incoming.await.map_err(|e| (IROH_ERR_INTERNAL, format!("accept: {e}")))
    };
    match block_on_timeout(timeout_ms, fut) {
        Ok(Ok(conn)) => {
            unsafe { *out = wrap_conn(conn) };
            IROH_OK
        }
        Ok(Err((code, msg))) => fail(code, msg),
        Err(_) => fail(IROH_ERR_TIMEOUT, "accept timed out"),
    }
}

/// Closes the endpoint (gracefully, blocking briefly) and frees it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_endpoint_free(ep: *mut IrohEndpoint) {
    if ep.is_null() {
        return;
    }
    let ep = unsafe { Box::from_raw(ep) };
    runtime().block_on(ep.ep.close());
}

/// Queues one unreliable datagram. Never blocks; the shim copies the bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_send_datagram(c: *const IrohConn, buf: *const u8, len: usize) -> i32 {
    let Some(c) = (unsafe { c.as_ref() }) else { return fail(IROH_ERR_INVALID, "null conn") };
    let data = bytes::Bytes::copy_from_slice(unsafe { bytes_arg(buf, len) });
    match c.conn.send_datagram(data) {
        Ok(()) => IROH_OK,
        Err(e) => fail(IROH_ERR_INTERNAL, format!("send_datagram: {e}")),
    }
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
    if !out_len.is_null() {
        unsafe { *out_len = d.len() };
    }
    if d.len() > cap || (buf.is_null() && !d.is_empty()) {
        return fail(IROH_ERR_TOO_SMALL, "datagram larger than buffer");
    }
    unsafe { std::ptr::copy_nonoverlapping(d.as_ptr(), buf, d.len()) };
    IROH_OK
}

/// Largest datagram payload the peer currently accepts (0 if datagrams are unsupported).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_max_datagram_size(c: *const IrohConn) -> usize {
    unsafe { c.as_ref() }.and_then(|c| c.conn.max_datagram_size()).unwrap_or(0)
}

/// Datagrams dropped inside the shim because Zig did not drain the queue fast enough.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iroh_conn_local_drops(c: *const IrohConn) -> u64 {
    unsafe { c.as_ref() }.map(|c| c.dropped.load(Ordering::Relaxed)).unwrap_or(0)
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
}
