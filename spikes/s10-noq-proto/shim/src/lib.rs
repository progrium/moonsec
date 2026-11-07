//! Spike S10: a sans-I/O C ABI over `noq-proto` (the QUIC state machine under iroh).
//!
//! The Zig side owns everything with a clock or a file descriptor: the UDP socket, the
//! event loop, timers, the pacer and the media queue. This library only turns bytes into
//! QUIC state and back. No threads, no tokio, no allocation outside noq-proto's own.
//!
//! One `Nq` is one endpoint with at most one connection (enough for a media pipe).
//! Time is passed in as CLOCK_MONOTONIC nanoseconds and mapped onto `std::time::Instant`
//! (which is CLOCK_MONOTONIC on Linux) relative to a base taken at creation.

use std::{
    collections::VecDeque,
    ffi::c_int,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    num::NonZeroUsize,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering::Relaxed},
    },
    time::{Duration, Instant},
};

use bytes::{Bytes, BytesMut};
use noq_proto::{
    ClientConfig, Connection, ConnectionHandle, DatagramEvent, Endpoint, EndpointConfig, Event,
    FourTuple, IdleTimeout, PathId, RttEstimator, SendDatagramError, ServerConfig,
    TransportConfig, VarInt,
    congestion::{Controller, ControllerFactory, ControllerMetrics},
    crypto::rustls::{QuicClientConfig, QuicServerConfig},
};

#[cfg(feature = "rv")]
mod rv;

const ALPN: &[u8] = b"moonsec/s10/0";
const SERVER_NAME: &str = "moonsec.media";

fn now_ns() -> u64 {
    let mut ts = std::mem::MaybeUninit::<[i64; 2]>::uninit();
    // struct timespec { time_t tv_sec; long tv_nsec; } on 64-bit Linux
    unsafe extern "C" {
        fn clock_gettime(clk: c_int, ts: *mut [i64; 2]) -> c_int;
    }
    unsafe { clock_gettime(1, ts.as_mut_ptr()) };
    let ts = unsafe { ts.assume_init() };
    ts[0] as u64 * 1_000_000_000 + ts[1] as u64
}

// ---------------------------------------------------------------------------
// Congestion controllers

#[derive(Debug, Default)]
pub struct CcCounters {
    pub congestion_events: AtomicU64,
    pub lost_bytes: AtomicU64,
    pub target_bps: AtomicU64,
}

/// Mode 0, "zig": QUIC never limits or paces. The window is above u32::MAX, which makes
/// noq-proto's pacer step aside (`pacing.rs`: "we disable pacing for extremely large
/// windows"). The Zig pacer is the only rate limiter. Loss is counted, never acted on.
///
/// Mode 1, "noq-rate": S3's `AppRate` semantics. noq-proto's own token-bucket pacer runs at
/// `target_bps` with a 2x BDP window. Used to A/B the pacer location with the same driver.
#[derive(Debug)]
struct Factory {
    mode: u32,
    c: Arc<CcCounters>,
}

#[derive(Debug, Clone)]
struct Cc {
    mode: u32,
    c: Arc<CcCounters>,
    mtu: u16,
    srtt: Duration,
}

const HUGE_WINDOW: u64 = 1 << 40;

impl ControllerFactory for Factory {
    fn build(self: Arc<Self>, _now: Instant, mtu: u16) -> Box<dyn Controller> {
        Box::new(Cc { mode: self.mode, c: self.c.clone(), mtu, srtt: Duration::from_millis(1) })
    }
}

impl Cc {
    fn rate(&self) -> u64 {
        self.c.target_bps.load(Relaxed) / 8
    }
}

impl Controller for Cc {
    fn on_ack(&mut self, _: Instant, _: Instant, _: u64, _: u64, _: bool, rtt: &RttEstimator) {
        self.srtt = rtt.get();
    }
    fn on_congestion_event(&mut self, _: Instant, _: Instant, _: bool, _: bool, lost: u64, _: u64) {
        self.c.congestion_events.fetch_add(1, Relaxed);
        self.c.lost_bytes.fetch_add(lost, Relaxed);
    }
    fn on_mtu_update(&mut self, mtu: u16) {
        self.mtu = mtu;
    }
    fn window(&self) -> u64 {
        if self.mode == 0 || self.rate() == 0 {
            return HUGE_WINDOW;
        }
        let rtt = self.srtt.max(Duration::from_millis(5));
        let bdp = (self.rate() as u128 * rtt.as_nanos() / 1_000_000_000) as u64;
        (2 * bdp).max(4 * self.mtu as u64)
    }
    fn metrics(&self) -> ControllerMetrics {
        let mut m = ControllerMetrics::default();
        m.congestion_window = self.window();
        if self.mode == 1 && self.rate() > 0 {
            m.pacing_rate = Some(self.rate());
            m.send_quantum = Some(2 * self.mtu as u64);
        }
        m
    }
    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }
    fn initial_window(&self) -> u64 {
        self.window()
    }
    fn into_any(self: Box<Self>) -> Box<dyn std::any::Any> {
        self
    }
}

// ---------------------------------------------------------------------------
// C types

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NqAddr {
    /// 4 or 6
    pub family: u16,
    /// host byte order
    pub port: u16,
    /// v4 uses the first 4 bytes
    pub ip: [u8; 16],
}

impl NqAddr {
    fn to_std(&self) -> SocketAddr {
        let ip = if self.family == 6 {
            IpAddr::V6(Ipv6Addr::from(self.ip))
        } else {
            IpAddr::V4(Ipv4Addr::new(self.ip[0], self.ip[1], self.ip[2], self.ip[3]))
        };
        SocketAddr::new(ip, self.port)
    }
    fn from_std(a: SocketAddr) -> Self {
        let mut ip = [0u8; 16];
        let family = match a.ip() {
            IpAddr::V4(v) => {
                ip[..4].copy_from_slice(&v.octets());
                4
            }
            IpAddr::V6(v) => {
                ip = v.octets();
                6
            }
        };
        Self { family, port: a.port(), ip }
    }
}

#[repr(C)]
pub struct NqConfig {
    pub is_server: c_int,
    /// 0 = Zig paces (QUIC unpaced, unlimited window), 1 = noq-proto pacer at `target_bps`.
    pub cc_mode: c_int,
    pub target_bps: u64,
    pub datagram_send_buffer: usize,
    pub datagram_recv_buffer: usize,
    pub idle_timeout_ms: u32,
    pub keepalive_ms: u32,
}

#[repr(C)]
#[derive(Default)]
pub struct NqStats {
    pub udp_tx: u64,
    pub udp_tx_bytes: u64,
    pub udp_rx: u64,
    pub udp_rx_bytes: u64,
    pub sent_packets: u64,
    pub lost_packets: u64,
    pub lost_bytes: u64,
    pub frame_tx_datagram: u64,
    pub frame_rx_datagram: u64,
    pub rtt_us: u64,
    pub cwnd: u64,
    pub congestion_events: u64,
    pub mtu: u64,
    /// Datagrams refused by `nq_send_datagram` because noq's send buffer was full.
    pub send_blocked: u64,
}

pub struct Nq {
    ep: Endpoint,
    conn: Option<(ConnectionHandle, Connection)>,
    client_cfg: Option<ClientConfig>,
    cert_der: Vec<u8>,
    base_inst: Instant,
    base_ns: u64,
    scratch: Vec<u8>,
    pending: VecDeque<(SocketAddr, Vec<u8>)>,
    cc: Arc<CcCounters>,
    send_blocked: u64,
}

impl Nq {
    fn inst(&self, ns: u64) -> Instant {
        if ns >= self.base_ns {
            self.base_inst + Duration::from_nanos(ns - self.base_ns)
        } else {
            self.base_inst - Duration::from_nanos(self.base_ns - ns)
        }
    }
    fn ns(&self, t: Instant) -> u64 {
        match t.checked_duration_since(self.base_inst) {
            Some(d) => self.base_ns + d.as_nanos() as u64,
            None => self.base_ns.saturating_sub((self.base_inst - t).as_nanos() as u64),
        }
    }
    /// Route endpoint events (CID issuance, drain) between the connection and the endpoint.
    fn pump_endpoint_events(&mut self) {
        if let Some((h, conn)) = self.conn.as_mut() {
            while let Some(ev) = conn.poll_endpoint_events() {
                if let Some(back) = self.ep.handle_event(*h, ev) {
                    conn.handle_event(back);
                }
            }
        }
    }
}

fn transport(cfg: &NqConfig, cc: Arc<CcCounters>) -> TransportConfig {
    let mut t = TransportConfig::default();
    t.datagram_receive_buffer_size(Some(cfg.datagram_recv_buffer.max(64 * 1024)));
    t.datagram_send_buffer_size(cfg.datagram_send_buffer.max(4 * 1024));
    t.congestion_controller_factory(Arc::new(Factory { mode: cfg.cc_mode as u32, c: cc }));
    if cfg.idle_timeout_ms > 0 {
        t.max_idle_timeout(Some(IdleTimeout::from(VarInt::from_u32(cfg.idle_timeout_ms))));
    }
    if cfg.keepalive_ms > 0 {
        t.keep_alive_interval(Some(Duration::from_millis(cfg.keepalive_ms as u64)));
    }
    t.enable_segmentation_offload(false);
    t
}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// Create an endpoint. A server generates a fresh self-signed certificate (read it back with
/// `nq_cert_der` and hand it to the client over an authenticated channel, e.g. an iroh
/// control stream). A client pins exactly that certificate.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_new(cfg: *const NqConfig, cert: *const u8, cert_len: usize) -> *mut Nq {
    let cfg = unsafe { &*cfg };
    let cc = Arc::new(CcCounters::default());
    cc.target_bps.store(cfg.target_bps, Relaxed);
    let tc = Arc::new(transport(cfg, cc.clone()));
    let mut cert_der = Vec::new();
    let mut server_cfg = None;
    let mut client_cfg = None;
    if cfg.is_server != 0 {
        let ck = rcgen::generate_simple_self_signed(vec![SERVER_NAME.into()]).expect("rcgen");
        cert_der = ck.cert.der().to_vec();
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(ck.signing_key.serialize_der().into());
        let mut rc = rustls::ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![ck.cert.der().clone()], key)
            .expect("server cert");
        rc.alpn_protocols = vec![ALPN.to_vec()];
        rc.max_early_data_size = 0;
        let mut sc = ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(rc).expect("quic server")));
        sc.transport_config(tc);
        server_cfg = Some(Arc::new(sc));
    } else {
        let der = unsafe { std::slice::from_raw_parts(cert, cert_len) }.to_vec();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(rustls::pki_types::CertificateDer::from(der)).expect("pinned cert");
        let mut rc = rustls::ClientConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
        rc.alpn_protocols = vec![ALPN.to_vec()];
        let mut cc_ = ClientConfig::new(Arc::new(QuicClientConfig::try_from(rc).expect("quic client")));
        cc_.transport_config(tc);
        client_cfg = Some(cc_);
    }
    let ep = Endpoint::new(Arc::new(EndpointConfig::default()), server_cfg, false);
    Box::into_raw(Box::new(Nq {
        ep,
        conn: None,
        client_cfg,
        cert_der,
        base_inst: Instant::now(),
        base_ns: now_ns(),
        scratch: Vec::with_capacity(64 * 1024),
        pending: VecDeque::new(),
        cc,
        send_blocked: 0,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_free(nq: *mut Nq) {
    if !nq.is_null() {
        drop(unsafe { Box::from_raw(nq) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_cert_der(nq: *mut Nq, buf: *mut u8, cap: usize) -> isize {
    let nq = unsafe { &*nq };
    if nq.cert_der.len() > cap {
        return -1;
    }
    unsafe { std::ptr::copy_nonoverlapping(nq.cert_der.as_ptr(), buf, nq.cert_der.len()) };
    nq.cert_der.len() as isize
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_connect(nq: *mut Nq, now: u64, to: *const NqAddr) -> c_int {
    let nq = unsafe { &mut *nq };
    let Some(cfg) = nq.client_cfg.clone() else { return -1 };
    let t = nq.inst(now);
    match nq.ep.connect(t, cfg, unsafe { (*to).to_std() }, SERVER_NAME) {
        Ok(c) => {
            nq.conn = Some(c);
            0
        }
        Err(_) => -2,
    }
}

/// Feed one received UDP datagram.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_handle(nq: *mut Nq, now: u64, from: *const NqAddr, data: *const u8, len: usize) {
    let nq = unsafe { &mut *nq };
    let t = nq.inst(now);
    let data = BytesMut::from(unsafe { std::slice::from_raw_parts(data, len) });
    let remote = unsafe { (*from).to_std() };
    nq.scratch.clear();
    match nq.ep.handle(t, FourTuple::new(remote, None), None, data, &mut nq.scratch) {
        Some(DatagramEvent::ConnectionEvent(h, ev)) => {
            if let Some((ch, conn)) = nq.conn.as_mut() {
                if *ch == h {
                    conn.handle_event(ev);
                }
            }
        }
        Some(DatagramEvent::NewConnection(inc)) => {
            if nq.conn.is_some() {
                nq.ep.ignore(inc);
            } else {
                let mut buf = Vec::new();
                match nq.ep.accept(inc, t, &mut buf, None) {
                    Ok(c) => nq.conn = Some(c),
                    Err(e) => {
                        if let Some(tx) = e.response {
                            nq.pending.push_back((tx.destination, buf[..tx.size].to_vec()));
                        }
                    }
                }
            }
        }
        Some(DatagramEvent::Response(tx)) => {
            nq.pending.push_back((tx.destination, nq.scratch[..tx.size].to_vec()));
        }
        None => {}
    }
    nq.pump_endpoint_events();
}

/// Produce the next UDP datagram to send, if any. Returns its length (0 = nothing to send).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_poll_transmit(nq: *mut Nq, now: u64, buf: *mut u8, cap: usize, to: *mut NqAddr) -> isize {
    let nq = unsafe { &mut *nq };
    if let Some((dst, data)) = nq.pending.pop_front() {
        let n = data.len().min(cap);
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), buf, n);
            *to = NqAddr::from_std(dst);
        }
        return n as isize;
    }
    let t = nq.inst(now);
    let Some((_, conn)) = nq.conn.as_mut() else { return 0 };
    nq.scratch.clear();
    let r = conn.poll_transmit(t, NonZeroUsize::MIN, &mut nq.scratch);
    let out = match r {
        Some(tx) => {
            let n = tx.size.min(cap);
            unsafe {
                std::ptr::copy_nonoverlapping(nq.scratch.as_ptr(), buf, n);
                *to = NqAddr::from_std(tx.destination);
            }
            n as isize
        }
        None => 0,
    };
    nq.pump_endpoint_events();
    out
}

/// Next deadline (CLOCK_MONOTONIC ns) at which `nq_handle_timeout` must be called; u64::MAX if none.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_timeout(nq: *mut Nq) -> u64 {
    let nq = unsafe { &mut *nq };
    match nq.conn.as_mut().and_then(|(_, c)| c.poll_timeout()) {
        Some(t) => nq.ns(t),
        None => u64::MAX,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_handle_timeout(nq: *mut Nq, now: u64) {
    let nq = unsafe { &mut *nq };
    let t = nq.inst(now);
    if let Some((_, c)) = nq.conn.as_mut() {
        c.handle_timeout(t);
    }
    nq.pump_endpoint_events();
}

pub const EV_NONE: c_int = 0;
pub const EV_CONNECTED: c_int = 1;
pub const EV_LOST: c_int = 2;
pub const EV_DATAGRAM: c_int = 3;
pub const EV_UNBLOCKED: c_int = 4;
pub const EV_OTHER: c_int = 9;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_poll_event(nq: *mut Nq) -> c_int {
    let nq = unsafe { &mut *nq };
    let Some((_, c)) = nq.conn.as_mut() else { return EV_NONE };
    match c.poll() {
        None => EV_NONE,
        Some(Event::Connected) => EV_CONNECTED,
        Some(Event::ConnectionLost { .. }) => EV_LOST,
        Some(Event::DatagramReceived) => EV_DATAGRAM,
        Some(Event::DatagramsUnblocked) => EV_UNBLOCKED,
        Some(_) => EV_OTHER,
    }
}

/// Queue one datagram. 0 = queued, 1 = noq's send buffer is full (nothing dropped; the caller
/// keeps it), -1 = too large / unsupported, -2 = no connection.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_send_datagram(nq: *mut Nq, data: *const u8, len: usize) -> c_int {
    let nq = unsafe { &mut *nq };
    let Some((_, c)) = nq.conn.as_mut() else { return -2 };
    let b = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    match c.datagrams().send(b, false) {
        Ok(()) => 0,
        Err(SendDatagramError::Blocked(_)) => {
            nq.send_blocked += 1;
            1
        }
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_recv_datagram(nq: *mut Nq, buf: *mut u8, cap: usize) -> isize {
    let nq = unsafe { &mut *nq };
    let Some((_, c)) = nq.conn.as_mut() else { return 0 };
    match c.datagrams().recv() {
        Some(b) => {
            let n = b.len().min(cap);
            unsafe { std::ptr::copy_nonoverlapping(b.as_ptr(), buf, n) };
            n as isize
        }
        None => 0,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_max_datagram(nq: *mut Nq) -> isize {
    let nq = unsafe { &mut *nq };
    nq.conn.as_mut().and_then(|(_, c)| c.datagrams().max_size()).map_or(-1, |n| n as isize)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_set_target_bps(nq: *mut Nq, bps: u64) {
    unsafe { &*nq }.cc.target_bps.store(bps, Relaxed);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_stats(nq: *mut Nq, out: *mut NqStats) {
    let nq = unsafe { &mut *nq };
    let mut s = NqStats::default();
    if let Some((_, c)) = nq.conn.as_mut() {
        let cs = c.stats();
        s.udp_tx = cs.udp_tx.datagrams;
        s.udp_tx_bytes = cs.udp_tx.bytes;
        s.udp_rx = cs.udp_rx.datagrams;
        s.udp_rx_bytes = cs.udp_rx.bytes;
        s.sent_packets = cs.sent_packets;
        s.lost_packets = cs.lost_packets;
        s.lost_bytes = cs.lost_bytes;
        s.frame_tx_datagram = cs.frame_tx.datagram;
        s.frame_rx_datagram = cs.frame_rx.datagram;
        if let Some(p) = c.path_stats(PathId::ZERO) {
            s.rtt_us = p.rtt.as_micros() as u64;
            s.cwnd = p.cwnd;
        }
        s.mtu = c.current_mtu() as u64;
    }
    s.congestion_events = nq.cc.congestion_events.load(Relaxed);
    s.send_blocked = nq.send_blocked;
    unsafe { *out = s };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_close(nq: *mut Nq, now: u64) {
    let nq = unsafe { &mut *nq };
    let t = nq.inst(now);
    if let Some((_, c)) = nq.conn.as_mut() {
        c.close(t, VarInt::from_u32(0), Bytes::from_static(b"done"));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_is_closed(nq: *mut Nq) -> c_int {
    let nq = unsafe { &mut *nq };
    nq.conn.as_ref().map_or(1, |(_, c)| c.is_closed() as c_int)
}
