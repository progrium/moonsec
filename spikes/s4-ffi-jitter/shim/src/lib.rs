//! S4 spike shim: measures the jitter added between a Zig caller handing a
//! datagram to the Rust shim and that datagram reaching the socket.
//!
//! Probe points (all CLOCK_MONOTONIC, nanoseconds):
//!   t0  Zig, immediately before calling `s4_send` (carried in the payload header)
//!   t1  first instruction of `s4_send` (shim entry)
//!   t2  tokio task picks the datagram up (raw-async modes only)
//!   t3  `sendmsg`/`sendto` entry, captured by an interposer on the libc symbol
//!   t4  same syscall returns
//!
//! Modes:
//!   0 RAW_DIRECT  shim entry calls sendto() synchronously (floor: FFI + syscall)
//!   1 RAW_MT      shim entry -> mpsc -> task on a multi-thread tokio runtime -> UdpSocket
//!   2 RAW_CT      same, but a current-thread runtime on one dedicated (optionally pinned, RT) thread
//!   3 IROH_MT     shim entry -> iroh Connection::send_datagram, endpoint on multi-thread runtime
//!   4 IROH_CT     same, endpoint on a dedicated current-thread runtime thread
//!   5 RAW_THREAD  baseline without tokio: std mpsc -> blocking recv on a plain OS thread -> send()
//!   6 RAW_SPIN    baseline without wakeups: plain OS thread busy-polls std mpsc -> send()
//!
//! Platforms: Linux (SCHED_FIFO + CPU affinity) and macOS. macOS has no CPU
//! pinning on Apple Silicon, and the `prio` argument selects a scheduling
//! policy instead of a SCHED_FIFO priority (see `pin_and_prio`).
//!
//! Payload header: [u64 seq][u64 t0][u64 magic]. In RAW modes the interposer reads the
//! seq straight from the iov. In IROH modes the payload is encrypted, so the interposer
//! records every large send and the analysis matches by time (sends are spaced).

use std::ffi::{c_char, c_int, c_void, CStr};
use std::io::Write;
use std::net::{SocketAddr, UdpSocket as StdUdp};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};

use bytes::Bytes;

const MAGIC: u64 = 0x5334_4a49_5454_4552; // "S4JITTER"
const MAX_SEQ: usize = 1 << 21;
const MAX_EVENTS: usize = 1 << 22;
const ALPN: &[u8] = b"moonsec/s4/0";

pub const RAW_DIRECT: c_int = 0;
pub const RAW_MT: c_int = 1;
pub const RAW_CT: c_int = 2;
pub const IROH_MT: c_int = 3;
pub const IROH_CT: c_int = 4;
pub const RAW_THREAD: c_int = 5;
pub const RAW_SPIN: c_int = 6;

// macOS: CLOCK_UPTIME_RAW is mach_absolute_time in ns (CLOCK_MONOTONIC there is
// only microsecond-granular).
#[cfg(target_os = "macos")]
const CLOCK: libc::clockid_t = libc::CLOCK_UPTIME_RAW;
#[cfg(not(target_os = "macos"))]
const CLOCK: libc::clockid_t = libc::CLOCK_MONOTONIC;

#[inline(always)]
pub fn now_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(CLOCK, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

#[cfg(target_os = "macos")]
#[allow(deprecated)] // libc points at mach2 for mach_timebase_info
mod mac {
    use std::ffi::c_int;
    extern "C" {
        pub fn mach_wait_until(deadline: u64) -> c_int;
    }
    #[repr(C)]
    pub struct TcPolicy {
        pub period: u32,
        pub computation: u32,
        pub constraint: u32,
        pub preemptible: u32,
    }
    pub fn timebase() -> (u64, u64) {
        let mut tb = libc::mach_timebase_info { numer: 0, denom: 0 };
        unsafe { libc::mach_timebase_info(&mut tb) };
        (tb.numer as u64, tb.denom as u64)
    }
    pub fn ns_to_abs(ns: u64) -> u64 {
        let (n, d) = timebase();
        ns * d / n
    }
    fn env_us(k: &str, d: u64) -> u64 {
        std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d)
    }
    /// Mach real-time ("time-constraint") policy, the one Core Audio uses. The
    /// thread is promised `computation` of CPU within `constraint` of waking,
    /// every `period`. Tunable via S4_TC_{PERIOD,COMP,CONSTR}_US.
    pub fn time_constraint() -> c_int {
        let p = TcPolicy {
            period: ns_to_abs(env_us("S4_TC_PERIOD_US", 1000) * 1000) as u32,
            computation: ns_to_abs(env_us("S4_TC_COMP_US", 250) * 1000) as u32,
            constraint: ns_to_abs(env_us("S4_TC_CONSTR_US", 1000) * 1000) as u32,
            preemptible: 1,
        };
        unsafe {
            libc::thread_policy_set(
                libc::pthread_mach_thread_np(libc::pthread_self()),
                libc::THREAD_TIME_CONSTRAINT_POLICY as u32,
                &p as *const TcPolicy as *mut i32,
                4,
            )
        }
    }
}

/// Sleep until `now_ns() >= t` (absolute). Exported for the Zig harness.
#[no_mangle]
pub extern "C" fn s4_sleep_until(t: u64) {
    #[cfg(target_os = "macos")]
    unsafe {
        // CLOCK_UPTIME_RAW ns -> mach absolute ticks
        mac::mach_wait_until(mac::ns_to_abs(t));
    }
    #[cfg(not(target_os = "macos"))]
    unsafe {
        let ts = libc::timespec { tv_sec: (t / 1_000_000_000) as _, tv_nsec: (t % 1_000_000_000) as _ };
        while libc::clock_nanosleep(CLOCK, libc::TIMER_ABSTIME, &ts, std::ptr::null_mut()) != 0 {}
    }
}

// ---------------------------------------------------------------------------
// Preallocated probe storage (no allocation on the hot path).

struct Probes {
    t0: Box<[AtomicU64]>,
    t1: Box<[AtomicU64]>,
    t2: Box<[AtomicU64]>,
    t3: Box<[AtomicU64]>,
    t4: Box<[AtomicU64]>,
    // raw syscall event log (used by IROH modes): entry, exit, total len, segments
    ev: Box<[[AtomicU64; 4]]>,
    ev_n: AtomicUsize,
    max_seq: AtomicUsize,
    min_big_len: AtomicUsize,
}

fn zeros(n: usize) -> Box<[AtomicU64]> {
    (0..n).map(|_| AtomicU64::new(0)).collect()
}

static PROBES: OnceLock<Probes> = OnceLock::new();
static RECORDING: AtomicBool = AtomicBool::new(false);

fn probes() -> &'static Probes {
    PROBES.get_or_init(|| Probes {
        t0: zeros(MAX_SEQ),
        t1: zeros(MAX_SEQ),
        t2: zeros(MAX_SEQ),
        t3: zeros(MAX_SEQ),
        t4: zeros(MAX_SEQ),
        ev: (0..MAX_EVENTS)
            .map(|_| [AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0)])
            .collect(),
        ev_n: AtomicUsize::new(0),
        max_seq: AtomicUsize::new(0),
        min_big_len: AtomicUsize::new(usize::MAX),
    })
}

fn parse_hdr(p: &[u8]) -> Option<(usize, u64)> {
    if p.len() < 24 {
        return None;
    }
    let seq = u64::from_le_bytes(p[0..8].try_into().ok()?);
    let t0 = u64::from_le_bytes(p[8..16].try_into().ok()?);
    let m = u64::from_le_bytes(p[16..24].try_into().ok()?);
    if m != MAGIC || seq as usize >= MAX_SEQ {
        return None;
    }
    Some((seq as usize, t0))
}

// ---------------------------------------------------------------------------
// libc interposers. The final executable links this archive before libc.so, so
// every sendmsg/sendto made by noq-udp, mio and std resolves here; we forward to
// the real symbol via dlsym(RTLD_NEXT).

type SendmsgFn = unsafe extern "C" fn(c_int, *const libc::msghdr, c_int) -> isize;
type SendtoFn = unsafe extern "C" fn(
    c_int,
    *const c_void,
    usize,
    c_int,
    *const libc::sockaddr,
    libc::socklen_t,
) -> isize;

static REAL_SENDMSG: OnceLock<usize> = OnceLock::new();
static REAL_SENDTO: OnceLock<usize> = OnceLock::new();
static INTERPOSED_CALLS: AtomicU64 = AtomicU64::new(0);

fn real(name: &CStr, cell: &OnceLock<usize>) -> usize {
    *cell.get_or_init(|| {
        let p = unsafe { libc::dlsym(libc::RTLD_NEXT, name.as_ptr()) } as usize;
        assert!(p != 0, "dlsym RTLD_NEXT failed");
        p
    })
}

#[allow(dead_code)]
const SOL_UDP: c_int = 17;
#[allow(dead_code)]
const UDP_SEGMENT: c_int = 103;

#[cfg(target_os = "macos")]
fn gso_segment(_msg: &libc::msghdr) -> Option<usize> {
    None // no UDP GSO on macOS
}

#[cfg(not(target_os = "macos"))]
fn gso_segment(msg: &libc::msghdr) -> Option<usize> {
    unsafe {
        let mut c = libc::CMSG_FIRSTHDR(msg);
        while !c.is_null() {
            if (*c).cmsg_level == SOL_UDP && (*c).cmsg_type == UDP_SEGMENT {
                let d = libc::CMSG_DATA(c) as *const u16;
                return Some(d.read_unaligned() as usize);
            }
            c = libc::CMSG_NXTHDR(msg, c);
        }
    }
    None
}

fn record_event(t3: u64, t4: u64, len: usize, segs: usize) {
    let p = probes();
    let i = p.ev_n.fetch_add(1, Ordering::Relaxed);
    if i < MAX_EVENTS {
        p.ev[i][0].store(t3, Ordering::Relaxed);
        p.ev[i][1].store(t4, Ordering::Relaxed);
        p.ev[i][2].store(len as u64, Ordering::Relaxed);
        p.ev[i][3].store(segs as u64, Ordering::Relaxed);
    }
}

fn record_seq(buf: &[u8], t3: u64, t4: u64) -> bool {
    if let Some((seq, _)) = parse_hdr(buf) {
        let p = probes();
        p.t3[seq].store(t3, Ordering::Relaxed);
        p.t4[seq].store(t4, Ordering::Relaxed);
        true
    } else {
        false
    }
}

#[no_mangle]
pub unsafe extern "C" fn sendmsg(fd: c_int, msg: *const libc::msghdr, flags: c_int) -> isize {
    let f: SendmsgFn = std::mem::transmute(real(c"sendmsg", &REAL_SENDMSG));
    if !RECORDING.load(Ordering::Relaxed) {
        return f(fd, msg, flags);
    }
    INTERPOSED_CALLS.fetch_add(1, Ordering::Relaxed);
    let t3 = now_ns();
    let r = f(fd, msg, flags);
    let t4 = now_ns();
    let m = &*msg;
    let mut len = 0usize;
    for i in 0..m.msg_iovlen as usize {
        len += (*m.msg_iov.add(i)).iov_len;
    }
    // Plain-text RAW payload? Then we can tag by seq directly.
    if m.msg_iovlen >= 1 {
        let iov = &*m.msg_iov;
        let s = std::slice::from_raw_parts(iov.iov_base as *const u8, iov.iov_len);
        if record_seq(s, t3, t4) {
            return r;
        }
    }
    if len >= probes().min_big_len.load(Ordering::Relaxed) {
        let segs = match gso_segment(m) {
            Some(seg) if seg > 0 => len.div_ceil(seg),
            _ => 1,
        };
        record_event(t3, t4, len, segs);
    }
    r
}

#[no_mangle]
pub unsafe extern "C" fn sendto(
    fd: c_int,
    buf: *const c_void,
    len: usize,
    flags: c_int,
    addr: *const libc::sockaddr,
    alen: libc::socklen_t,
) -> isize {
    let f: SendtoFn = std::mem::transmute(real(c"sendto", &REAL_SENDTO));
    if !RECORDING.load(Ordering::Relaxed) {
        return f(fd, buf, len, flags, addr, alen);
    }
    INTERPOSED_CALLS.fetch_add(1, Ordering::Relaxed);
    let t3 = now_ns();
    let r = f(fd, buf, len, flags, addr, alen);
    let t4 = now_ns();
    let s = std::slice::from_raw_parts(buf as *const u8, len);
    if !record_seq(s, t3, t4) && len >= probes().min_big_len.load(Ordering::Relaxed) {
        record_event(t3, t4, len, 1);
    }
    r
}

type SendFn = unsafe extern "C" fn(c_int, *const c_void, usize, c_int) -> isize;
static REAL_SEND: OnceLock<usize> = OnceLock::new();

#[no_mangle]
pub unsafe extern "C" fn send(fd: c_int, buf: *const c_void, len: usize, flags: c_int) -> isize {
    let f: SendFn = std::mem::transmute(real(c"send", &REAL_SEND));
    if !RECORDING.load(Ordering::Relaxed) {
        return f(fd, buf, len, flags);
    }
    INTERPOSED_CALLS.fetch_add(1, Ordering::Relaxed);
    let t3 = now_ns();
    let r = f(fd, buf, len, flags);
    let t4 = now_ns();
    record_seq(std::slice::from_raw_parts(buf as *const u8, len), t3, t4);
    r
}

// ---------------------------------------------------------------------------
// Thread placement helpers (also exported so Zig and the shim use the same code).

/// macOS: no CPU pinning on Apple Silicon (THREAD_AFFINITY_POLICY is only a
/// hint, and unsupported on arm64), so `cpu` is ignored. `rt_prio` picks the
/// policy:
///   0  leave the thread alone (inherits the process default QoS)
///   1  QOS_CLASS_USER_INTERACTIVE
///   2  Mach time-constraint (real-time) policy
///   3  pthread SCHED_FIFO at max priority
///   4  QOS_CLASS_USER_INTERACTIVE, then time-constraint
#[cfg(target_os = "macos")]
fn pin_and_prio(_cpu: c_int, rt_prio: c_int) -> c_int {
    unsafe {
        match rt_prio {
            0 => 0,
            1 => libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0),
            2 => mac::time_constraint(),
            3 => {
                let mut p: libc::sched_param = std::mem::zeroed();
                p.sched_priority = libc::sched_get_priority_max(libc::SCHED_FIFO);
                libc::pthread_setschedparam(libc::pthread_self(), libc::SCHED_FIFO, &p)
            }
            4 => {
                libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0)
                    | mac::time_constraint()
            }
            _ => -1,
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn pin_and_prio(cpu: c_int, rt_prio: c_int) -> c_int {
    let mut rc = 0;
    unsafe {
        if cpu >= 0 {
            let mut set: libc::cpu_set_t = std::mem::zeroed();
            libc::CPU_SET(cpu as usize, &mut set);
            if libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set) != 0 {
                rc |= 1;
            }
        }
        if rt_prio > 0 {
            let p = libc::sched_param { sched_priority: rt_prio };
            if libc::pthread_setschedparam(libc::pthread_self(), libc::SCHED_FIFO, &p) != 0 {
                rc |= 2;
            }
        }
    }
    rc
}

#[no_mangle]
pub extern "C" fn s4_pin_current_thread(cpu: c_int, rt_prio: c_int) -> c_int {
    pin_and_prio(cpu, rt_prio)
}

#[no_mangle]
pub extern "C" fn s4_now_ns() -> u64 {
    now_ns()
}

// ---------------------------------------------------------------------------
// Shim state

enum Sender {
    Direct { sock: StdUdp },
    Chan { tx: tokio::sync::mpsc::UnboundedSender<Bytes> },
    Std { tx: std::sync::mpsc::Sender<Bytes> },
    Iroh { conn: iroh::endpoint::Connection },
}

pub struct Shim {
    mode: c_int,
    sender: Sender,
    received: Arc<AtomicU64>,
    _rt: Option<tokio::runtime::Runtime>,
    _threads: Vec<std::thread::JoinHandle<()>>,
    _keep: Vec<Box<dyn std::any::Any + Send>>,
}

#[repr(C)]
pub struct S4Config {
    pub mode: c_int,
    /// CPU to pin the dedicated runtime thread to (CT modes); -1 = no pin
    pub rt_cpu: c_int,
    /// SCHED_FIFO priority for the dedicated runtime thread (CT modes); 0 = normal
    pub rt_prio: c_int,
    /// worker threads for MT modes (0 = tokio default)
    pub mt_workers: c_int,
    /// sendmsg payloads at least this big are logged as events (IROH modes)
    pub min_big_len: c_int,
}

fn spawn_ct_thread<F, Fut>(cpu: c_int, prio: c_int, f: F) -> std::thread::JoinHandle<()>
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()>,
{
    std::thread::Builder::new()
        .name("s4-rt".into())
        .spawn(move || {
            pin_and_prio(cpu, prio);
            let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            rt.block_on(f());
        })
        .unwrap()
}

fn sink_socket() -> (StdUdp, SocketAddr, Arc<AtomicU64>, std::thread::JoinHandle<()>) {
    let rx = StdUdp::bind("127.0.0.1:0").unwrap();
    let addr = rx.local_addr().unwrap();
    let n = Arc::new(AtomicU64::new(0));
    let n2 = n.clone();
    let h = std::thread::spawn(move || {
        let mut b = [0u8; 2048];
        while rx.recv(&mut b).is_ok() {
            n2.fetch_add(1, Ordering::Relaxed);
        }
    });
    (StdUdp::bind("127.0.0.1:0").unwrap(), addr, n, h)
}

async fn iroh_pair(
    received: Arc<AtomicU64>,
) -> anyhow::Result<(iroh::Endpoint, iroh::Endpoint, iroh::endpoint::Connection)> {
    use iroh::endpoint::{presets, QuicTransportConfig};
    use iroh::{Endpoint, EndpointAddr, RelayMode};
    let tc = || {
        QuicTransportConfig::builder()
            .mtu_discovery_config(None) // no PMTU probes polluting the large-send log
            .datagram_receive_buffer_size(Some(8 << 20))
            .datagram_send_buffer_size(8 << 20)
            .build()
    };
    let server = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        .alpns(vec![ALPN.to_vec()])
        .transport_config(tc())
        .bind_addr("127.0.0.1:0")?
        .bind()
        .await?;
    let client = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        .transport_config(tc())
        .bind_addr("127.0.0.1:0")?
        .bind()
        .await?;
    let saddr = server
        .bound_sockets()
        .into_iter()
        .find(|a| a.is_ipv4())
        .ok_or_else(|| anyhow::anyhow!("no v4 socket"))?;
    let target = EndpointAddr::new(server.id()).with_ip_addr(saddr);
    let srv = server.clone();
    tokio::spawn(async move {
        while let Some(inc) = srv.accept().await {
            let received = received.clone();
            tokio::spawn(async move {
                let Ok(c) = inc.await else { return };
                while c.read_datagram().await.is_ok() {
                    received.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
    });
    let conn = client.connect(target, ALPN).await?;
    Ok((server, client, conn))
}

/// Create a shim instance. Returns null on failure.
#[no_mangle]
pub extern "C" fn s4_init(cfg: *const S4Config) -> *mut Shim {
    let cfg = unsafe { &*cfg };
    let p = probes();
    if cfg.min_big_len > 0 {
        p.min_big_len.store(cfg.min_big_len as usize, Ordering::Relaxed);
    }
    let mut received = Arc::new(AtomicU64::new(0));
    let mut threads = Vec::new();
    let mut keep: Vec<Box<dyn std::any::Any + Send>> = Vec::new();
    let mt_rt = || {
        let mut b = tokio::runtime::Builder::new_multi_thread();
        if cfg.mt_workers > 0 {
            b.worker_threads(cfg.mt_workers as usize);
        }
        // Optional: apply a scheduling policy to every worker (S4_MT_PRIO, same
        // codes as rt_prio). Stock shims leave workers alone; default unset.
        if let Some(pr) = std::env::var("S4_MT_PRIO").ok().and_then(|v| v.parse::<c_int>().ok()) {
            b.on_thread_start(move || {
                pin_and_prio(-1, pr);
            });
        }
        b.enable_all().build().unwrap()
    };
    let res: anyhow::Result<(Sender, Option<tokio::runtime::Runtime>)> = (|| match cfg.mode {
        RAW_DIRECT => {
            let (sock, dst, n, h) = sink_socket();
            sock.connect(dst)?;
            threads.push(h);
            received = n;
            Ok((Sender::Direct { sock }, None))
        }
        RAW_MT | RAW_CT => {
            let (sock, dst, n, h) = sink_socket();
            threads.push(h);
            received = n;
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Bytes>();
            let task = async move {
                sock.set_nonblocking(true).unwrap();
                let sock = tokio::net::UdpSocket::from_std(sock).unwrap();
                while let Some(b) = rx.recv().await {
                    if let Some((seq, _)) = parse_hdr(&b) {
                        probes().t2[seq].store(now_ns(), Ordering::Relaxed);
                    }
                    let _ = sock.send_to(&b, dst).await;
                }
            };
            if cfg.mode == RAW_MT {
                let rt = mt_rt();
                rt.spawn(task);
                Ok((Sender::Chan { tx }, Some(rt)))
            } else {
                threads.push(spawn_ct_thread(cfg.rt_cpu, cfg.rt_prio, move || task));
                Ok((Sender::Chan { tx }, None))
            }
        }
        RAW_THREAD | RAW_SPIN => {
            let (sock, dst, n, h) = sink_socket();
            threads.push(h);
            received = n;
            sock.connect(dst)?;
            let (tx, rx) = std::sync::mpsc::channel::<Bytes>();
            let spin = cfg.mode == RAW_SPIN;
            let (cpu, prio) = (cfg.rt_cpu, cfg.rt_prio);
            threads.push(std::thread::spawn(move || {
                pin_and_prio(cpu, prio);
                loop {
                    let b = if spin {
                        match rx.try_recv() {
                            Ok(b) => b,
                            Err(std::sync::mpsc::TryRecvError::Empty) => {
                                std::hint::spin_loop();
                                continue;
                            }
                            Err(_) => break,
                        }
                    } else {
                        match rx.recv() {
                            Ok(b) => b,
                            Err(_) => break,
                        }
                    };
                    if let Some((seq, _)) = parse_hdr(&b) {
                        probes().t2[seq].store(now_ns(), Ordering::Relaxed);
                    }
                    let _ = sock.send(&b);
                }
            }));
            Ok((Sender::Std { tx }, None))
        }
        IROH_MT => {
            let rt = mt_rt();
            let (s, c, conn) = rt.block_on(iroh_pair(received.clone()))?;
            keep.push(Box::new((s, c)));
            Ok((Sender::Iroh { conn }, Some(rt)))
        }
        IROH_CT => {
            let (otx, orx) = std::sync::mpsc::channel();
            let r2 = received.clone();
            let _ = &mut received;
            threads.push(spawn_ct_thread(cfg.rt_cpu, cfg.rt_prio, move || async move {
                match iroh_pair(r2).await {
                    Ok((s, c, conn)) => {
                        otx.send(Ok(conn)).unwrap();
                        let _keep = (s, c);
                        std::future::pending::<()>().await;
                    }
                    Err(e) => otx.send(Err(e)).unwrap(),
                }
            }));
            let conn = orx.recv()??;
            Ok((Sender::Iroh { conn }, None))
        }
        m => anyhow::bail!("bad mode {m}"),
    })();
    match res {
        Ok((sender, rt)) => {
            RECORDING.store(true, Ordering::Relaxed);
            Box::into_raw(Box::new(Shim {
                mode: cfg.mode,
                sender,
                received,
                _rt: rt,
                _threads: threads,
                _keep: keep,
            }))
        }
        Err(e) => {
            eprintln!("s4_init failed: {e:#}");
            std::ptr::null_mut()
        }
    }
}

/// Hot path. `buf` is owned by the caller (Zig); we copy into a Bytes before
/// handing off, as a real shim would.
#[no_mangle]
pub extern "C" fn s4_send(shim: *mut Shim, buf: *const u8, len: usize) -> c_int {
    let t1 = now_ns();
    let shim = unsafe { &*shim };
    let data = unsafe { std::slice::from_raw_parts(buf, len) };
    if let Some((seq, t0)) = parse_hdr(data) {
        let p = probes();
        p.t0[seq].store(t0, Ordering::Relaxed);
        p.t1[seq].store(t1, Ordering::Relaxed);
        p.max_seq.fetch_max(seq + 1, Ordering::Relaxed);
    }
    match &shim.sender {
        Sender::Direct { sock } => match sock.send(data) {
            Ok(_) => 0,
            Err(_) => -1,
        },
        Sender::Chan { tx } => match tx.send(Bytes::copy_from_slice(data)) {
            Ok(_) => 0,
            Err(_) => -1,
        },
        Sender::Std { tx } => match tx.send(Bytes::copy_from_slice(data)) {
            Ok(_) => 0,
            Err(_) => -1,
        },
        Sender::Iroh { conn } => match conn.send_datagram(Bytes::copy_from_slice(data)) {
            Ok(_) => 0,
            Err(_) => -1,
        },
    }
}

#[no_mangle]
pub extern "C" fn s4_max_datagram(shim: *mut Shim) -> c_int {
    let shim = unsafe { &*shim };
    match &shim.sender {
        Sender::Iroh { conn } => conn.max_datagram_size().map(|v| v as c_int).unwrap_or(-1),
        _ => 65000,
    }
}

#[no_mangle]
pub extern "C" fn s4_received(shim: *mut Shim) -> u64 {
    unsafe { &*shim }.received.load(Ordering::Relaxed)
}

/// Write probes to `<prefix>.seq.csv` and `<prefix>.ev.csv`.
#[no_mangle]
pub extern "C" fn s4_dump(shim: *mut Shim, prefix: *const c_char) -> c_int {
    RECORDING.store(false, Ordering::Relaxed);
    let shim = unsafe { &*shim };
    let prefix = unsafe { CStr::from_ptr(prefix) }.to_string_lossy().into_owned();
    let p = probes();
    let go = || -> std::io::Result<()> {
        let mut f = std::io::BufWriter::new(std::fs::File::create(format!("{prefix}.seq.csv"))?);
        writeln!(f, "seq,t0,t1,t2,t3,t4")?;
        for i in 0..p.max_seq.load(Ordering::Relaxed) {
            writeln!(
                f,
                "{},{},{},{},{},{}",
                i,
                p.t0[i].load(Ordering::Relaxed),
                p.t1[i].load(Ordering::Relaxed),
                p.t2[i].load(Ordering::Relaxed),
                p.t3[i].load(Ordering::Relaxed),
                p.t4[i].load(Ordering::Relaxed)
            )?;
        }
        let mut f = std::io::BufWriter::new(std::fs::File::create(format!("{prefix}.ev.csv"))?);
        writeln!(f, "t3,t4,len,segs")?;
        for i in 0..p.ev_n.load(Ordering::Relaxed).min(MAX_EVENTS) {
            let e = &p.ev[i];
            writeln!(
                f,
                "{},{},{},{}",
                e[0].load(Ordering::Relaxed),
                e[1].load(Ordering::Relaxed),
                e[2].load(Ordering::Relaxed),
                e[3].load(Ordering::Relaxed)
            )?;
        }
        Ok(())
    };
    eprintln!(
        "s4_dump: mode={} interposed_calls={} events={} received={}",
        shim.mode,
        INTERPOSED_CALLS.load(Ordering::Relaxed),
        p.ev_n.load(Ordering::Relaxed),
        shim.received.load(Ordering::Relaxed)
    );
    match go() {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("dump failed: {e}");
            -1
        }
    }
}
