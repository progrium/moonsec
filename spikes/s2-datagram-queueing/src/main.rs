//! Spike S2: does iroh (noq) add hidden queueing or silent drops to datagrams under load?
//!
//! Subcommands:
//!   recv   - iroh endpoint that accepts one connection and logs per-datagram one-way delay
//!   send   - iroh endpoint that connects and paces datagrams at a target rate
//!   udprecv / udpsend - the same over a raw UDP socket, as the no-iroh baseline
//!   proxy  - userspace one-way delay line (the sandbox kernel has no netem), bidirectional
//!
//! All processes run on one host in separate network namespaces, so CLOCK_MONOTONIC is shared
//! and the one-way delay (recv_ts - send_ts) is exact.

use std::{
    collections::VecDeque,
    fs::File,
    io::{BufWriter, Write},
    net::{SocketAddr, UdpSocket},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use clap::{Parser, Subcommand, ValueEnum};
use iroh::{
    Endpoint, EndpointAddr, RelayMode, SecretKey, TransportAddr,
    endpoint::{QuicTransportConfig, presets},
};

mod apprate;

const ALPN: &[u8] = b"moonsec/s2bench/0";
const HDR: usize = 32;

fn now_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

/// Sleep until `t` (monotonic ns); coarse sleep then spin for the last stretch.
fn sleep_until(t: u64) {
    loop {
        let n = now_ns();
        if n >= t {
            return;
        }
        let left = t - n;
        if left > 200_000 {
            std::thread::sleep(Duration::from_nanos(left - 150_000));
        } else {
            std::hint::spin_loop();
        }
    }
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum Pattern {
    /// Evenly paced packets.
    Smooth,
    /// Video-like: each frame's bytes are handed over back-to-back at `fps`.
    Frames,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum SendMode {
    /// `send_datagram`: never blocks; drops the oldest queued datagram when the buffer is full.
    Drop,
    /// `send_datagram_wait`: waits for buffer space (backpressure).
    Wait,
}

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Args, Clone)]
struct SendArgs {
    /// Target address.
    #[arg(long)]
    to: SocketAddr,
    /// Offered load in Mbit/s (UDP payload bytes).
    #[arg(long)]
    mbps: f64,
    /// Datagram payload size in bytes.
    #[arg(long, default_value_t = 1100)]
    size: usize,
    #[arg(long, default_value_t = 10.0)]
    secs: f64,
    #[arg(long, value_enum, default_value_t = Pattern::Smooth)]
    pattern: Pattern,
    #[arg(long, default_value_t = 60.0)]
    fps: f64,
    /// JSON summary output path.
    #[arg(long)]
    out: String,
}

#[derive(Subcommand)]
enum Cmd {
    Recv {
        #[arg(long)]
        bind: SocketAddr,
        #[arg(long, default_value_t = 7)]
        seed: u8,
        /// CSV of per-datagram samples.
        #[arg(long)]
        csv: String,
        #[arg(long)]
        out: String,
        /// Datagram receive buffer in bytes (noq default 1.25 MB).
        #[arg(long)]
        rbuf: Option<usize>,
    },
    Send {
        #[command(flatten)]
        a: SendArgs,
        #[arg(long)]
        bind: SocketAddr,
        #[arg(long, default_value_t = 7)]
        seed: u8,
        #[arg(long, value_enum, default_value_t = SendMode::Drop)]
        mode: SendMode,
        /// Datagram send buffer in bytes (noq default 1 MiB).
        #[arg(long)]
        sbuf: Option<usize>,
        /// Congestion controller: `cubic` (iroh default) or `apprate` (S3's app-driven pacer).
        #[arg(long, default_value = "cubic")]
        cc: String,
        /// AppRate target in Mbit/s of QUIC payload; default is 1.05x the offered load.
        #[arg(long)]
        target_mbps: Option<f64>,
        /// AppRate burst credit in microseconds at the target rate (0 = noq's ~2 ms bucket).
        #[arg(long, default_value_t = 0)]
        burst_us: u64,
        /// Seconds of warm-up traffic at the target rate before measured traffic starts.
        #[arg(long, default_value_t = 2.0)]
        warmup: f64,
    },
    UdpRecv {
        #[arg(long)]
        bind: SocketAddr,
        #[arg(long)]
        csv: String,
        #[arg(long)]
        secs: f64,
    },
    UdpSend {
        #[command(flatten)]
        a: SendArgs,
        #[arg(long)]
        bind: SocketAddr,
    },
    /// Bidirectional delay line: packets from the `a` side are delayed and forwarded to `b`
    /// from the `b_bind` socket, and replies from `b` go back to the last `a` peer.
    Proxy {
        #[arg(long)]
        a_bind: SocketAddr,
        #[arg(long)]
        b_bind: SocketAddr,
        #[arg(long)]
        b: SocketAddr,
        /// One-way delay in microseconds, applied in both directions.
        #[arg(long)]
        delay_us: u64,
    },
}

fn write_header(buf: &mut [u8], seq: u64, frame: u64, frame_ts: u64) {
    buf[0..8].copy_from_slice(&seq.to_le_bytes());
    buf[16..24].copy_from_slice(&frame.to_le_bytes());
    buf[24..32].copy_from_slice(&frame_ts.to_le_bytes());
    buf[8..16].copy_from_slice(&now_ns().to_le_bytes());
}

fn parse_header(b: &[u8]) -> (u64, u64, u64, u64) {
    let g = |i: usize| u64::from_le_bytes(b[i..i + 8].try_into().unwrap());
    (g(0), g(8), g(16), g(24))
}

/// Drive a send schedule; `emit` is called with (seq, frame, frame_start_ts, is_warmup).
fn schedule(a: &SendArgs, warmup: f64, mut emit: impl FnMut(u64, u64, u64, bool) -> Result<()>) -> Result<u64> {
    let bytes_per_sec = a.mbps * 1e6 / 8.0;
    let total_secs = warmup + a.secs;
    let start = now_ns() + 1_000_000;
    let mut seq = 0u64;
    match a.pattern {
        Pattern::Smooth => {
            let interval = 1e9 * a.size as f64 / bytes_per_sec;
            let n = (total_secs * 1e9 / interval) as u64;
            let warm_n = (warmup * 1e9 / interval) as u64;
            for i in 0..n {
                let t = start + (i as f64 * interval) as u64;
                sleep_until(t);
                emit(seq, i, t, i < warm_n)?;
                seq += 1;
            }
        }
        Pattern::Frames => {
            let per_frame = ((bytes_per_sec / a.fps) / a.size as f64).round().max(1.0) as u64;
            let n_frames = (total_secs * a.fps) as u64;
            let warm_frames = (warmup * a.fps) as u64;
            for f in 0..n_frames {
                let t = start + (f as f64 * 1e9 / a.fps) as u64;
                sleep_until(t);
                for _ in 0..per_frame {
                    emit(seq, f, t, f < warm_frames)?;
                    seq += 1;
                }
            }
        }
    }
    Ok(seq)
}

fn endpoint_builder(seed: u8, bind: SocketAddr, rbuf: Option<usize>, sbuf: Option<usize>) -> Result<iroh::endpoint::Builder> {
    endpoint_builder_cc(seed, bind, rbuf, sbuf, None)
}

fn endpoint_builder_cc(
    seed: u8,
    bind: SocketAddr,
    rbuf: Option<usize>,
    sbuf: Option<usize>,
    cc: Option<Arc<apprate::AppRateFactory>>,
) -> Result<iroh::endpoint::Builder> {
    let mut tc = QuicTransportConfig::builder();
    if let Some(f) = cc {
        tc = tc.congestion_controller_factory(f);
    }
    if let Some(r) = rbuf {
        tc = tc.datagram_receive_buffer_size(Some(r));
    }
    if let Some(s) = sbuf {
        tc = tc.datagram_send_buffer_size(s);
    }
    Ok(Endpoint::builder(presets::Minimal)
        .secret_key(SecretKey::from_bytes(&[seed; 32]))
        .relay_mode(RelayMode::Disabled)
        .clear_ip_transports()
        .bind_addr(bind)?
        .transport_config(tc.build()))
}

fn path_summary(conn: &iroh::endpoint::Connection) -> Vec<serde_json::Value> {
    conn.paths()
        .iter()
        .map(|p| {
            let s = p.stats();
            serde_json::json!({
                "rtt_us": s.rtt.as_micros() as u64,
                "cwnd": s.cwnd,
                "congestion_events": s.congestion_events,
                "lost_packets": s.lost_packets,
                "sent_packets": s.sent_packets,
                "udp_tx": s.udp_tx.datagrams,
                "udp_rx": s.udp_rx.datagrams,
                "mtu": s.current_mtu,
            })
        })
        .collect()
}

fn conn_summary(conn: &iroh::endpoint::Connection) -> serde_json::Value {
    let s = conn.stats();
    serde_json::json!({
        "frame_tx_datagram": s.frame_tx.datagram,
        "frame_rx_datagram": s.frame_rx.datagram,
        "udp_tx": s.udp_tx.datagrams,
        "udp_tx_bytes": s.udp_tx.bytes,
        "udp_rx": s.udp_rx.datagrams,
        "udp_rx_bytes": s.udp_rx.bytes,
        "sent_packets": s.sent_packets,
        "lost_packets": s.lost_packets,
        "lost_bytes": s.lost_bytes,
        "paths": path_summary(conn),
    })
}

async fn run_recv(bind: SocketAddr, seed: u8, csv: String, out: String, rbuf: Option<usize>) -> Result<()> {
    let ep = endpoint_builder(seed, bind, rbuf, None)?.alpns(vec![ALPN.to_vec()]).bind().await?;
    eprintln!("recv id {}", ep.id());
    let inc = ep.accept().await.context("no incoming")?;
    let conn = inc.await?;
    let mut w = BufWriter::new(File::create(&csv)?);
    writeln!(w, "seq,send_ns,frame,frame_ns,recv_ns")?;
    let mut n = 0u64;
    loop {
        match conn.read_datagram().await {
            Ok(d) => {
                let r = now_ns();
                let (seq, s, f, ft) = parse_header(&d);
                writeln!(w, "{seq},{s},{f},{ft},{r}")?;
                n += 1;
            }
            Err(_) => break,
        }
    }
    w.flush()?;
    let j = serde_json::json!({"app_received": n, "conn": conn_summary(&conn)});
    std::fs::write(&out, serde_json::to_string_pretty(&j)?)?;
    ep.close().await;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_send(
    a: SendArgs,
    bind: SocketAddr,
    seed: u8,
    mode: SendMode,
    sbuf: Option<usize>,
    warmup: f64,
    cc: String,
    target_mbps: Option<f64>,
    burst_us: u64,
) -> Result<()> {
    let factory = match cc.as_str() {
        "cubic" => None,
        "apprate" => {
            let knob = Arc::new(apprate::RateKnob::default());
            // The knob paces QUIC packet bytes; scale payload Mbit/s by the ~30 B/datagram overhead.
            let t = target_mbps.unwrap_or(a.mbps * 1.05) * 1e6 * (a.size as f64 + 30.0) / a.size as f64;
            knob.set_target_bps(t as u64);
            knob.burst_us.store(burst_us, Ordering::Relaxed);
            Some(apprate::AppRateFactory::new(knob))
        }
        other => bail!("unknown cc {other}"),
    };
    let ep = endpoint_builder_cc(seed.wrapping_add(1), bind, None, sbuf, factory.clone())?.bind().await?;
    let peer = SecretKey::from_bytes(&[seed; 32]).public();
    let addr = EndpointAddr::from_parts(peer, [TransportAddr::Ip(a.to)]);
    let conn = ep.connect(addr, ALPN).await?;
    let max = conn.max_datagram_size().context("datagrams unsupported")?;
    if a.size > max {
        bail!("size {} > max datagram {}", a.size, max);
    }
    let rt = tokio::runtime::Handle::current();
    let conn2 = conn.clone();
    let a2 = a.clone();
    // Track sender-side buffer pressure: how often the send buffer was too full to take a
    // datagram without evicting an older one (the only signal noq gives for send-side drops).
    let would_drop = Arc::new(AtomicU64::new(0));
    let min_space = Arc::new(AtomicU64::new(u64::MAX));
    let wd = would_drop.clone();
    let ms = min_space.clone();
    let res = tokio::task::spawn_blocking(move || -> Result<(u64, u64)> {
        if let Some(cpu) = std::env::var("S2_GEN_CPU").ok().and_then(|v| v.parse().ok()) {
            pin_current(Some(cpu), 0);
        }
        let mut buf = vec![0u8; a2.size];
        let mut warm = 0u64;
        let sent = schedule(&a2, warmup, |seq, f, ft, is_warm| {
            let space = conn2.datagram_send_buffer_space();
            ms.fetch_min(space as u64, Ordering::Relaxed);
            if space < a2.size {
                wd.fetch_add(1, Ordering::Relaxed);
            }
            if is_warm {
                warm += 1;
            }
            write_header(&mut buf, seq, f, ft);
            let b = Bytes::copy_from_slice(&buf);
            match mode {
                SendMode::Drop => conn2.send_datagram(b)?,
                SendMode::Wait => rt.block_on(conn2.send_datagram_wait(b))?,
            }
            Ok(())
        })?;
        Ok((sent, warm))
    })
    .await??;
    // Let the queue drain, then snapshot stats and close.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let j = serde_json::json!({
        "app_sent": res.0,
        "warmup_sent": res.1,
        "send_buffer_would_drop": would_drop.load(Ordering::Relaxed),
        "send_buffer_min_space": min_space.load(Ordering::Relaxed),
        "max_datagram": max,
        "cc": cc,
        "cc_paths_built": factory.as_ref().map(|f| f.built_count()),
        "burst_us": burst_us,
        "conn": conn_summary(&conn),
    });
    std::fs::write(&a.out, serde_json::to_string_pretty(&j)?)?;
    conn.close(0u32.into(), b"done");
    ep.close().await;
    Ok(())
}

fn run_udp_recv(bind: SocketAddr, csv: String, secs: f64) -> Result<()> {
    let s = UdpSocket::bind(bind)?;
    s.set_read_timeout(Some(Duration::from_millis(200)))?;
    let mut w = BufWriter::new(File::create(&csv)?);
    writeln!(w, "seq,send_ns,frame,frame_ns,recv_ns")?;
    let mut buf = [0u8; 2048];
    let deadline = now_ns() + (secs * 1e9) as u64;
    while now_ns() < deadline {
        if let Ok((n, _)) = s.recv_from(&mut buf) {
            let r = now_ns();
            if n >= HDR {
                let (seq, st, f, ft) = parse_header(&buf);
                writeln!(w, "{seq},{st},{f},{ft},{r}")?;
            }
        }
    }
    w.flush()?;
    Ok(())
}

fn run_udp_send(a: SendArgs, bind: SocketAddr) -> Result<()> {
    let s = UdpSocket::bind(bind)?;
    let mut buf = vec![0u8; a.size];
    let mut errs = 0u64;
    let sent = schedule(&a, 2.0, |seq, f, ft, _| {
        write_header(&mut buf, seq, f, ft);
        if s.send_to(&buf, a.to).is_err() {
            errs += 1;
        }
        Ok(())
    })?;
    std::fs::write(&a.out, serde_json::to_string_pretty(&serde_json::json!({"app_sent": sent, "warmup_secs": 2.0, "send_errors": errs}))?)?;
    Ok(())
}

fn run_proxy(a_bind: SocketAddr, b_bind: SocketAddr, b: SocketAddr, delay_us: u64) -> Result<()> {
    let sa = UdpSocket::bind(a_bind)?;
    let sb = UdpSocket::bind(b_bind)?;
    sa.set_nonblocking(true)?;
    sb.set_nonblocking(true)?;
    // Large socket buffers so the delay line itself never drops: overflow must happen at the
    // TBF qdisc (the emulated bottleneck), where it is counted.
    for s in [&sa, &sb] {
        use std::os::fd::AsRawFd;
        let v: libc::c_int = 16 << 20;
        for opt in [libc::SO_SNDBUFFORCE, libc::SO_RCVBUFFORCE] {
            unsafe {
                libc::setsockopt(s.as_raw_fd(), libc::SOL_SOCKET, opt, &v as *const _ as *const libc::c_void, 4);
            }
        }
    }
    let delay = delay_us * 1000;
    let mut a_peer: Option<SocketAddr> = None;
    // (release_ns, to_b, data)
    let mut q_ab: VecDeque<(u64, Vec<u8>)> = VecDeque::new();
    let mut q_ba: VecDeque<(u64, Vec<u8>)> = VecDeque::new();
    let mut buf = [0u8; 65536];
    let stop = Arc::new(AtomicBool::new(false));
    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        let mut idle = true;
        while let Ok((n, from)) = sa.recv_from(&mut buf) {
            a_peer = Some(from);
            q_ab.push_back((now_ns() + delay, buf[..n].to_vec()));
            idle = false;
        }
        while let Ok((n, _)) = sb.recv_from(&mut buf) {
            q_ba.push_back((now_ns() + delay, buf[..n].to_vec()));
            idle = false;
        }
        let t = now_ns();
        while q_ab.front().is_some_and(|(r, _)| *r <= t) {
            let (_, d) = q_ab.pop_front().unwrap();
            let _ = sb.send_to(&d, b);
            idle = false;
        }
        while q_ba.front().is_some_and(|(r, _)| *r <= t) {
            let (_, d) = q_ba.pop_front().unwrap();
            if let Some(p) = a_peer {
                let _ = sa.send_to(&d, p);
            }
            idle = false;
        }
        if idle {
            std::hint::spin_loop();
        }
    }
}

fn pin_current(cpu: Option<usize>, prio: i32) {
    unsafe {
        if let Some(cpu) = cpu {
            let mut set: libc::cpu_set_t = std::mem::zeroed();
            libc::CPU_SET(cpu, &mut set);
            if libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set) != 0 {
                eprintln!("warning: affinity");
            }
        }
        // prio 0 resets to SCHED_OTHER: the generator thread would otherwise inherit the
        // runtime thread's SCHED_FIFO, spin, and get RT-throttled 50 ms every second.
        let p = libc::sched_param { sched_priority: prio.max(0) };
        let pol = if prio > 0 { libc::SCHED_FIFO } else { libc::SCHED_OTHER };
        if libc::pthread_setschedparam(libc::pthread_self(), pol, &p) != 0 {
            eprintln!("warning: sched");
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Proxy { a_bind, b_bind, b, delay_us } => run_proxy(a_bind, b_bind, b, delay_us),
        Cmd::UdpRecv { bind, csv, secs } => run_udp_recv(bind, csv, secs),
        Cmd::UdpSend { a, bind } => run_udp_send(a, bind),
        cmd => {
            // S10 baseline: S2_CT_CPU / S2_CT_PRIO run iroh on one current-thread runtime on this
            // (pinned, SCHED_FIFO) thread, the shim's design since S4. Default: 2-worker runtime.
            let ct_cpu: Option<usize> = std::env::var("S2_CT_CPU").ok().and_then(|v| v.parse().ok());
            let rt = if let Some(cpu) = ct_cpu {
                let prio: i32 = std::env::var("S2_CT_PRIO").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
                pin_current(Some(cpu), prio);
                tokio::runtime::Builder::new_current_thread().enable_all().build()?
            } else {
                tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?
            };
            rt.block_on(async move {
                match cmd {
                    Cmd::Recv { bind, seed, csv, out, rbuf } => run_recv(bind, seed, csv, out, rbuf).await,
                    Cmd::Send { a, bind, seed, mode, sbuf, warmup, cc, target_mbps, burst_us } => run_send(a, bind, seed, mode, sbuf, warmup, cc, target_mbps, burst_us).await,
                    _ => unreachable!(),
                }
            })
        }
    }
}
