//! Spike S3 driver: two iroh endpoints in one process over real UDP sockets,
//! the custom controller installed via iroh's builder on both sides, and a
//! datagram flood whose rate is set from outside the controller mid-connection.
//!
//! Usage: s3-congestion [--builtin] [--phase-secs N] [--app-paced] [--loss PCT] [--delay-ms MS]
//!   --builtin     use iroh's default controller (Cubic) for comparison
//!   --app-paced   sender paces itself at 95% of the phase target (as the core
//!                 rate controller would) instead of saturating the send buffer
//!   --loss/--delay-ms  route the client through an in-process lossy UDP proxy

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use bytes::{BufMut, Bytes, BytesMut};
use iroh::endpoint::{Connection, QuicTransportConfig, presets};
use iroh::{Endpoint, EndpointAddr, RelayMode, TransportAddr};
use tokio::net::UdpSocket;
use s3_congestion::{AppRate, AppRateFactory, RateKnob};
use tokio::sync::Mutex;

const ALPN: &[u8] = b"moonsec/s3/0";
const PAYLOAD: usize = 1150; // design doc video packet size

fn transport_config(factory: Option<Arc<AppRateFactory>>) -> QuicTransportConfig {
    let mut b = QuicTransportConfig::builder()
        // Datagram config is also on the builder.
        .datagram_send_buffer_size(256 * 1024)
        .datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    if let Some(f) = factory {
        b = b.congestion_controller_factory(f);
    }
    b.build()
}

async fn bind(cfg: QuicTransportConfig, alpns: Vec<Vec<u8>>, addr: Option<&str>) -> Result<Endpoint> {
    let mut b = Endpoint::builder(presets::Minimal);
    if let Some(a) = addr {
        // Single-family socket: lets the proxy test keep server (v6) and client
        // (v4) unable to reach each other directly, so iroh's NAT traversal
        // cannot open a side path around the lossy proxy.
        b = b.clear_ip_transports().bind_addr(a)?;
    }
    Ok(b
        .relay_mode(RelayMode::Disabled)
        .transport_config(cfg)
        .alpns(alpns)
        .bind()
        .await?)
}

/// Minimal lossy/delaying UDP proxy: client -> proxy_front -> proxy_back -> server.
fn spawn_proxy(
    front: UdpSocket,
    back: UdpSocket,
    server: std::net::SocketAddr,
    loss: f64,
    delay: Duration,
) -> Result<std::net::SocketAddr> {
    let front = Arc::new(front);
    let back = Arc::new(back);
    let front_addr = front.local_addr()?;
    let client_addr: Arc<Mutex<Option<std::net::SocketAddr>>> = Arc::default();
    let rng = Arc::new(AtomicU64::new(0x9E3779B97F4A7C15));
    let drop_it = move |rng: &AtomicU64| {
        // xorshift
        let mut x = rng.load(Relaxed);
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        rng.store(x, Relaxed);
        (x % 1_000_000) as f64 / 1_000_000.0 < loss
    };
    {
        let (front, back, ca, rng) = (front.clone(), back.clone(), client_addr.clone(), rng.clone());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok((n, from)) = front.recv_from(&mut buf).await {
                *ca.lock().await = Some(from);
                if drop_it(&rng) { continue; }
                let pkt = buf[..n].to_vec();
                let back = back.clone();
                tokio::spawn(async move {
                    if !delay.is_zero() { tokio::time::sleep(delay).await; }
                    let _ = back.send_to(&pkt, server).await;
                });
            }
        });
    }
    {
        let (front, back, ca) = (front.clone(), back.clone(), client_addr.clone());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok((n, _)) = back.recv_from(&mut buf).await {
                if drop_it(&rng) { continue; }
                let Some(to) = *ca.lock().await else { continue };
                let pkt = buf[..n].to_vec();
                let front = front.clone();
                tokio::spawn(async move {
                    if !delay.is_zero() { tokio::time::sleep(delay).await; }
                    let _ = front.send_to(&pkt, to).await;
                });
            }
        });
    }
    Ok(front_addr)
}

#[derive(Default)]
struct RxStats {
    bytes: AtomicU64,
    pkts: AtomicU64,
    max_seq: AtomicU64,
    delays_us: Mutex<Vec<u64>>,
}

fn pct(v: &mut [u64], p: f64) -> u64 {
    if v.is_empty() {
        return 0;
    }
    v.sort_unstable();
    v[((v.len() - 1) as f64 * p) as usize]
}

fn describe_paths(conn: &Connection, label: &str) {
    for p in conn.paths().iter() {
        let st = p.stats();
        let cc = conn.congestion_state(p.id());
        let (kind, extra) = match cc {
            Some(c) => match c.into_any().downcast::<AppRate>() {
                Ok(ours) => (
                    "AppRate (custom)",
                    format!(
                        "path#{} sent_calls={} acks={} cong_events={} srtt={}us",
                        ours.counters.path_index,
                        ours.counters.sent_calls.load(Relaxed),
                        ours.counters.ack_calls.load(Relaxed),
                        ours.counters.congestion_events.load(Relaxed),
                        ours.counters.srtt_us.load(Relaxed),
                    ),
                ),
                Err(_) => ("built-in", String::new()),
            },
            None => ("none", String::new()),
        };
        println!(
            "  [{label}] path {:?} remote={:?} selected={} relay={} rtt={:?} cwnd={} bw_est={:?} controller={} {}",
            p.id(),
            p.remote_addr(),
            p.is_selected(),
            p.is_relay(),
            st.rtt,
            st.cwnd,
            st.bandwidth_estimate,
            kind,
            extra
        );
    }
}

/// Move the calling thread into a fresh network namespace with only `lo` up.
/// Sockets created afterwards on this thread cannot reach the server's real
/// addresses, so the only route is the proxy, whose front socket lives here too.
fn enter_isolated_netns() -> Result<()> {
    unsafe {
        if libc::unshare(libc::CLONE_NEWNET) != 0 {
            bail!("unshare(CLONE_NEWNET): {}", std::io::Error::last_os_error());
        }
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        let mut ifr: libc::ifreq = std::mem::zeroed();
        for (i, b) in b"lo\0".iter().enumerate() {
            ifr.ifr_name[i] = *b as libc::c_char;
        }
        if libc::ioctl(fd, libc::SIOCGIFFLAGS, &mut ifr) != 0 {
            bail!("SIOCGIFFLAGS: {}", std::io::Error::last_os_error());
        }
        ifr.ifr_ifru.ifru_flags |= libc::IFF_UP as libc::c_short;
        if libc::ioctl(fd, libc::SIOCSIFFLAGS, &ifr) != 0 {
            bail!("SIOCSIFFLAGS: {}", std::io::Error::last_os_error());
        }
        libc::close(fd);
    }
    Ok(())
}

fn main() -> Result<()> {
    let proxied = std::env::args().any(|a| a == "--loss" || a == "--delay-ms");
    // In proxy mode everything runs on this one thread so the netns switch
    // applies to every socket the client side creates.
    let rt = if proxied {
        tokio::runtime::Builder::new_current_thread().enable_all().build()?
    } else {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()?
    };
    rt.block_on(run())
}

async fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let builtin = args.iter().any(|a| a == "--builtin");
    let phase_secs: u64 = args
        .iter()
        .position(|a| a == "--phase-secs")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.parse().unwrap())
        .unwrap_or(2);
    let app_paced = args.iter().any(|a| a == "--app-paced");
    let arg_f = |name: &str| -> f64 {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .map(|s| s.parse().unwrap())
            .unwrap_or(0.0)
    };
    let loss = arg_f("--loss") / 100.0;
    let delay = Duration::from_micros((arg_f("--delay-ms") * 1000.0) as u64);
    let pace_bps = Arc::new(AtomicU64::new(0));

    let knob = Arc::new(RateKnob::default());
    let tx_factory = (!builtin).then(|| AppRateFactory::new(knob.clone()));
    let rx_factory = (!builtin).then(|| AppRateFactory::new(Arc::new(RateKnob::default())));

    let proxied = loss > 0.0 || !delay.is_zero();
    let server = bind(transport_config(rx_factory.clone()), vec![ALPN.to_vec()], None).await?;
    let mut proxy_addr = None;
    if proxied {
        let back = UdpSocket::bind("127.0.0.1:0").await?; // root netns
        enter_isolated_netns()?;
        let front = UdpSocket::bind("127.0.0.1:0").await?; // isolated netns
        let port = server.bound_sockets()[0].port();
        proxy_addr = Some(spawn_proxy(front, back, ([127, 0, 0, 1], port).into(), loss, delay)?);
    }
    let cli_addr = proxied.then_some("127.0.0.1:0");
    let client = bind(transport_config(tx_factory.clone()), vec![], cli_addr).await?;
    println!(
        "mode={} server={} sockets={:?}",
        if builtin { "builtin" } else { "custom" },
        server.id().fmt_short(),
        server.bound_sockets()
    );

    let t0 = Instant::now();
    let rx = Arc::new(RxStats::default());

    // Receiver.
    // Per-connection controller on the accept side: a fresh factory handed to
    // `Incoming::accept_with`, separate from the endpoint-wide one. This is how
    // a host with several sessions gets one knob per session.
    let per_conn_factory = (!builtin).then(|| AppRateFactory::new(Arc::new(RateKnob::default())));
    let pcf = per_conn_factory.clone();
    let srv = server.clone();
    let rx2 = rx.clone();
    let recv_task = tokio::spawn(async move {
        let incoming = srv.accept().await.context("accept")?;
        let conn = match pcf {
            Some(f) => {
                let sc = srv
                    .create_server_config_builder(vec![ALPN.to_vec()])
                    .set_transport_config(transport_config(Some(f)))
                    .build();
                incoming.accept_with(Arc::new(sc))?.await?
            }
            None => incoming.await?,
        };
        loop {
            let d = match conn.read_datagram().await {
                Ok(d) => d,
                Err(_) => break,
            };
            let now_us = t0.elapsed().as_micros() as u64;
            let seq = u64::from_le_bytes(d[0..8].try_into().unwrap());
            let sent_us = u64::from_le_bytes(d[8..16].try_into().unwrap());
            rx2.bytes.fetch_add(d.len() as u64, Relaxed);
            rx2.pkts.fetch_add(1, Relaxed);
            rx2.max_seq.fetch_max(seq, Relaxed);
            rx2.delays_us.lock().await.push(now_us.saturating_sub(sent_us));
        }
        anyhow::Ok(())
    });

    let dial = if let Some(proxy) = proxy_addr {
        println!("via proxy {proxy}: loss={:.1}% one-way delay={:?}", loss * 100.0, delay);
        EndpointAddr::from_parts(server.id(), [TransportAddr::Ip(proxy)])
    } else {
        server.addr()
    };
    let conn = client.connect(dial, ALPN).await?;
    println!(
        "connected; max_datagram_size={:?} send_buffer_space={}",
        conn.max_datagram_size(),
        conn.datagram_send_buffer_space()
    );
    if let Some(f) = &tx_factory {
        println!("controllers built on client so far: {}", f.built_count());
    }

    // Sender: saturating, backpressured by the send buffer (which drains at
    // whatever rate the congestion controller + pacer allow).
    let stop = Arc::new(AtomicBool::new(false));
    let seq = Arc::new(AtomicU64::new(0));
    let send_conn = conn.clone();
    let stop2 = stop.clone();
    let seq2 = seq.clone();
    let pace2 = pace_bps.clone();
    let send_task = tokio::spawn(async move {
        let mut buf = BytesMut::with_capacity(PAYLOAD);
        // Token bucket for --app-paced.
        let mut tokens: f64 = 0.0;
        let mut last = Instant::now();
        while !stop2.load(Relaxed) {
            let rate = pace2.load(Relaxed) as f64 / 8.0;
            if rate > 0.0 {
                let now = Instant::now();
                tokens = (tokens + rate * (now - last).as_secs_f64()).min((rate * 0.002).max(4.0 * PAYLOAD as f64));
                last = now;
                if tokens < PAYLOAD as f64 {
                    tokio::time::sleep(Duration::from_micros(500)).await;
                    continue;
                }
                tokens -= PAYLOAD as f64;
            }
            buf.clear();
            buf.put_u64_le(seq2.fetch_add(1, Relaxed));
            buf.put_u64_le(t0.elapsed().as_micros() as u64);
            buf.resize(PAYLOAD, 0xAB);
            let b: Bytes = buf.split().freeze();
            if send_conn.send_datagram_wait(b).await.is_err() {
                break;
            }
        }
    });

    // Phases: target rate set from outside the controller, on a live connection.
    let phases: &[(&str, u64)] = &[
        ("unlimited", 0),
        ("40 Mbit/s", 40_000_000),
        ("10 Mbit/s", 10_000_000),
        ("2 Mbit/s", 2_000_000),
        ("25 Mbit/s", 25_000_000),
    ];
    println!();
    println!(
        "{:<11} {:>10} {:>10} {:>9} {:>9} {:>9}",
        "phase", "target", "rx Mbit/s", "rx pkts", "p50 us", "p99 us"
    );
    for (name, bps) in phases {
        knob.set_target_bps(*bps);
        if app_paced {
            let app = if *bps == 0 { 100_000_000 } else { bps * 95 / 100 };
            pace_bps.store(app, Relaxed);
        }
        // Settle, then measure.
        tokio::time::sleep(Duration::from_millis(300)).await;
        let b0 = rx.bytes.load(Relaxed);
        let p0 = rx.pkts.load(Relaxed);
        rx.delays_us.lock().await.clear();
        let start = Instant::now();
        tokio::time::sleep(Duration::from_secs(phase_secs)).await;
        let secs = start.elapsed().as_secs_f64();
        let bytes = rx.bytes.load(Relaxed) - b0;
        let pkts = rx.pkts.load(Relaxed) - p0;
        let mut d = std::mem::take(&mut *rx.delays_us.lock().await);
        let (p50, p99) = (pct(&mut d, 0.5), pct(&mut d, 0.99));
        println!(
            "{:<11} {:>10} {:>10.2} {:>9} {:>9} {:>9}",
            name,
            if *bps == 0 { "-".to_string() } else { format!("{}", bps / 1_000_000) },
            bytes as f64 * 8.0 / secs / 1e6,
            pkts,
            p50,
            p99
        );
        describe_paths(&conn, name);
    }

    stop.store(true, Relaxed);
    tokio::time::sleep(Duration::from_millis(200)).await;

    println!();
    let sent = seq.load(Relaxed);
    let got = rx.pkts.load(Relaxed);
    let stats = conn.stats();
    println!(
        "app datagrams: queued={} received={} (gap={}); quic lost_packets={} congestion_events path-level shown above",
        sent,
        got,
        sent.saturating_sub(got),
        stats.lost_packets
    );
    describe_paths(&conn, "final");
    if let Some(f) = &tx_factory {
        let built = f.built.lock().unwrap();
        println!("client controllers built: {}", built.len());
        for c in built.iter() {
            println!(
                "  path#{} sent={}B acked={}B cong_events={} lost={}B mtu={}",
                c.path_index,
                c.sent_bytes.load(Relaxed),
                c.acked_bytes.load(Relaxed),
                c.congestion_events.load(Relaxed),
                c.lost_bytes.load(Relaxed),
                c.mtu.load(Relaxed)
            );
        }
        println!(
            "server controllers built: endpoint-wide factory={} per-connection factory={}",
            rx_factory.as_ref().unwrap().built_count(),
            per_conn_factory.as_ref().unwrap().built_count()
        );
        if built.is_empty() {
            bail!("custom factory was never invoked");
        }
    }

    conn.close(0u32.into(), b"done");
    send_task.abort();
    client.close().await;
    server.close().await;
    let _ = recv_task.await;
    Ok(())
}
