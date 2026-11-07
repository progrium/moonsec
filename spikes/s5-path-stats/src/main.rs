//! Spike S5: can we observe direct vs relayed path and per-path RTT/loss from iroh,
//! and do path changes and stats reach the application within 100 ms?
//!
//! Runs everything on one Linux box (needs root for iptables, and tcpdump):
//! a local iroh relay, a "host" endpoint and a "client" endpoint bound to fixed
//! loopback ports. Direct UDP between the two ports is blocked or degraded with
//! iptables so the run walks through:
//!
//!   A  relay forced     (direct UDP dropped, connection comes up over the relay)
//!   B  direct allowed   (rule removed, hole punch upgrades to a direct path)
//!   C  loss on direct   (every Nth direct packet dropped; watch lost_packets)
//!   D  direct broken    (direct UDP dropped again; watch fallback to relay)
//!
//! Ground truth for "when did the path really change" comes from tcpdump on lo,
//! which sees only packets that made it past iptables.

use std::{
    collections::BTreeMap,
    fmt::Write as _,
    fs,
    io::{BufRead, BufReader},
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use iroh::{
    Endpoint, RelayMode, TransportAddr,
    endpoint::{Connection, PathEvent, QuicTransportConfig, presets},
    tls::CaTlsConfig,
};
use tokio_stream::StreamExt;

const ALPN: &[u8] = b"moonsec/s5";
const HOST_PORT: u16 = 47001;
const CLIENT_PORT: u16 = 47002;
const PKT: usize = 1150; // video packet size from the design
const PPS: u64 = 2000; // ~18 Mbit/s of payload
const LOSS_EVERY: u32 = 20; // 5% deterministic loss on the direct path in phase C

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()
}

// ---------- iptables helpers ----------

fn ipt(op: &str, extra: &[&str]) -> Result<()> {
    let ports = format!("{HOST_PORT},{CLIENT_PORT}");
    for bin in ["iptables", "ip6tables"] {
        let mut args = vec![
            op, "OUTPUT", "-o", "lo", "-p", "udp", "-m", "multiport", "--sports", &ports, "-m",
            "multiport", "--dports", &ports,
        ];
        args.extend_from_slice(extra);
        args.extend_from_slice(&["-j", "DROP"]);
        let st = Command::new(bin).args(&args).status()?;
        if !st.success() {
            bail!("{bin} {args:?} failed");
        }
    }
    Ok(())
}
fn block_direct(on: bool) -> Result<()> {
    ipt(if on { "-I" } else { "-D" }, &[])
}
fn loss_direct(on: bool) -> Result<()> {
    let every = LOSS_EVERY.to_string();
    ipt(
        if on { "-I" } else { "-D" },
        &["-m", "statistic", "--mode", "nth", "--every", &every, "--packet", "0"],
    )
}
fn cleanup_rules() {
    while block_direct(false).is_ok() {}
    while loss_direct(false).is_ok() {}
}

// ---------- tcpdump ground truth ----------

#[derive(Clone, Debug)]
struct Wire {
    t: f64,
    kind: WireKind,
    len: usize,
}
#[derive(Clone, Copy, Debug, PartialEq)]
enum WireKind {
    DirectHostToClient,
    DirectClientToHost,
    RelayTcp,
}

fn spawn_tcpdump(relay_port: u16, out: Arc<Mutex<Vec<Wire>>>) -> Result<std::process::Child> {
    let filter = format!(
        "(udp and (src port {HOST_PORT} or src port {CLIENT_PORT}) and (dst port {HOST_PORT} or dst port {CLIENT_PORT})) or (tcp port {relay_port})"
    );
    let mut child = Command::new("tcpdump")
        .args(["-i", "lo", "-n", "-tt", "-l", "-q", "--immediate-mode", &filter])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("spawn tcpdump")?;
    let stdout = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            // 1730000000.123456 IP 127.0.0.1.47001 > 127.0.0.1.47002: UDP, length 1200
            // 1730000000.123456 IP 127.0.0.1.5555 > 127.0.0.1.40000: tcp 1234
            let mut it = line.split_whitespace();
            let Some(t) = it.next().and_then(|s| s.parse::<f64>().ok()) else { continue };
            let toks: Vec<&str> = line.split_whitespace().collect();
            let len = toks.last().and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            let kind = if line.contains("UDP") {
                if toks.get(2).is_some_and(|s| s.ends_with(&format!(".{HOST_PORT}"))) {
                    WireKind::DirectHostToClient
                } else {
                    WireKind::DirectClientToHost
                }
            } else {
                WireKind::RelayTcp
            };
            out.lock().unwrap().push(Wire { t, kind, len });
        }
    });
    Ok(child)
}

// ---------- application-side observations ----------

#[derive(Clone, Debug)]
struct Ev {
    t: f64,
    side: &'static str,
    kind: &'static str,
    id: String,
    relay: bool,
    addr: String,
    extra: String,
}

#[derive(Clone, Debug)]
struct Sample {
    t: f64,
    id: String,
    relay: bool,
    selected: bool,
    rtt_us: u128,
    sent: u64,
    lost: u64,
    cwnd: u64,
    poll_ns: u128,
}

fn addr_relay(a: &TransportAddr) -> bool {
    a.is_relay()
}

fn watch_events(side: &'static str, conn: &Connection, log: Arc<Mutex<Vec<Ev>>>) {
    let mut events = conn.path_events();
    tokio::spawn(async move {
        while let Some(ev) = events.next().await {
            let t = now();
            let e = match ev {
                PathEvent::Opened { id, remote_addr, .. } => Ev {
                    t, side, kind: "opened", id: format!("{id:?}"),
                    relay: addr_relay(&remote_addr), addr: format!("{remote_addr:?}"), extra: String::new(),
                },
                PathEvent::Selected { id, remote_addr, .. } => Ev {
                    t, side, kind: "selected", id: format!("{id:?}"),
                    relay: addr_relay(&remote_addr), addr: format!("{remote_addr:?}"), extra: String::new(),
                },
                PathEvent::Closed { id, remote_addr, last_stats, .. } => Ev {
                    t, side, kind: "closed", id: format!("{id:?}"),
                    relay: addr_relay(&remote_addr), addr: format!("{remote_addr:?}"),
                    extra: format!("rtt={:?} sent={} lost={}", last_stats.rtt, last_stats.sent_packets, last_stats.lost_packets),
                },
                PathEvent::Lagged { missed, .. } => Ev {
                    t, side, kind: "lagged", id: String::new(), relay: false, addr: String::new(),
                    extra: format!("missed={missed}"),
                },
                other => Ev {
                    t, side, kind: "other", id: String::new(), relay: false, addr: String::new(),
                    extra: format!("{other:?}"),
                },
            };
            println!("[{:.3}] {side:<6} {:<8} {} relay={} {} {}", e.t, e.kind, e.id, e.relay, e.addr, e.extra);
            log.lock().unwrap().push(e);
        }
    });
}

/// Polls `Connection::paths()` every millisecond on a dedicated thread, the way a
/// shim would before handing stats to Zig.
fn sample_stats(conn: Connection, log: Arc<Mutex<Vec<Sample>>>, stop: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            let t = now();
            let t0 = Instant::now();
            let paths = conn.paths();
            let mut rows = Vec::with_capacity(paths.len());
            for p in paths.iter() {
                let s = p.stats();
                rows.push((format!("{:?}", p.id()), p.is_relay(), p.is_selected(), s));
            }
            let poll_ns = t0.elapsed().as_nanos();
            let mut l = log.lock().unwrap();
            for (id, relay, selected, s) in rows {
                l.push(Sample {
                    t, id, relay, selected, rtt_us: s.rtt.as_micros(),
                    sent: s.sent_packets, lost: s.lost_packets, cwnd: s.cwnd, poll_ns,
                });
            }
            drop(l);
            std::thread::sleep(Duration::from_millis(1));
        }
    });
}

async fn endpoint(relay_map: iroh::RelayMap, port: u16) -> Result<Endpoint> {
    let mut tc = QuicTransportConfig::builder();
    if let Ok(ms) = std::env::var("S5_PATH_IDLE_MS") {
        tc = tc.default_path_max_idle_timeout(Duration::from_millis(ms.parse()?));
    }
    if let Ok(ms) = std::env::var("S5_PATH_KEEPALIVE_MS") {
        tc = tc.default_path_keep_alive_interval(Duration::from_millis(ms.parse()?));
    }
    let ep = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Custom(relay_map))
        .ca_tls_config(CaTlsConfig::insecure_skip_verify())
        .alpns(vec![ALPN.to_vec()])
        .transport_config(tc.build())
        .bind_addr(format!("127.0.0.1:{port}").as_str())?
        .bind()
        .await?;
    Ok(ep)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<()> {
    let out_dir = std::env::args().nth(1).unwrap_or_else(|| "results/run".into());
    fs::create_dir_all(&out_dir)?;
    let phase_a = Duration::from_secs(4);
    let phase_b_max = Duration::from_secs(15);
    let phase_c = Duration::from_secs(4);
    let phase_d_max = Duration::from_secs(40);

    cleanup_rules();
    block_direct(true)?;
    let mut marks: Vec<(String, f64)> = vec![("block_direct".into(), now())];

    let (relay_map, relay_url, _relay_guard) = iroh::test_utils::run_relay_server().await?;
    let relay_port = relay_url.port().context("relay port")?;
    println!("relay at {relay_url}");

    let wire = Arc::new(Mutex::new(Vec::<Wire>::new()));
    let mut tcpdump = spawn_tcpdump(relay_port, wire.clone())?;
    tokio::time::sleep(Duration::from_millis(1500)).await;

    let host = endpoint(relay_map.clone(), HOST_PORT).await?;
    let client = endpoint(relay_map.clone(), CLIENT_PORT).await?;
    host.online().await;
    client.online().await;
    let mut host_addr = host.addr();
    println!("host addrs: {:?}", host_addr.addrs);
    println!("client addrs: {:?}", client.addr().addrs);
    host_addr.addrs.retain(|a| a.is_relay()); // dial by key + relay only

    let events = Arc::new(Mutex::new(Vec::<Ev>::new()));
    let samples = Arc::new(Mutex::new(Vec::<Sample>::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let rx_count = Arc::new(AtomicU64::new(0));
    let rx_times = Arc::new(Mutex::new(Vec::<f64>::with_capacity(200_000)));

    // host: accept, watch events, count datagrams
    let host_task = {
        let host = host.clone();
        let events = events.clone();
        let rx_count = rx_count.clone();
        let rx_times = rx_times.clone();
        tokio::spawn(async move {
            let conn = host.accept().await.unwrap().await.unwrap();
            watch_events("host", &conn, events);
            while let Ok(_d) = conn.read_datagram().await {
                rx_count.fetch_add(1, Ordering::Relaxed);
                rx_times.lock().unwrap().push(now());
            }
        })
    };

    marks.push(("connect_start".into(), now()));
    let conn = client.connect(host_addr, ALPN).await?;
    marks.push(("connected".into(), now()));
    watch_events("client", &conn, events.clone());
    sample_stats(conn.clone(), samples.clone(), stop.clone());

    // client: constant-rate datagram sender (2 pkts per ms)
    let sender = {
        let conn = conn.clone();
        let stop = stop.clone();
        tokio::spawn(async move {
            let payload = bytes::Bytes::from(vec![0u8; PKT]);
            let mut tick = tokio::time::interval(Duration::from_millis(1));
            let per_tick = PPS / 1000;
            let mut dropped_local = 0u64;
            while !stop.load(Ordering::Relaxed) {
                tick.tick().await;
                for _ in 0..per_tick {
                    if conn.send_datagram(payload.clone()).is_err() {
                        dropped_local += 1;
                    }
                }
            }
            dropped_local
        })
    };

    // ---- A: relay forced ----
    println!("== A: relay forced for {phase_a:?}");
    tokio::time::sleep(phase_a).await;

    // ---- B: allow direct ----
    block_direct(false)?;
    let t_unblock = now();
    marks.push(("unblock_direct".into(), t_unblock));
    println!("== B: direct allowed at {t_unblock:.3}");
    let deadline = Instant::now() + phase_b_max;
    loop {
        let sel_direct = events.lock().unwrap().iter().any(|e| {
            e.side == "client" && e.kind == "selected" && !e.relay && e.t >= t_unblock
        });
        if sel_direct || Instant::now() > deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    tokio::time::sleep(Duration::from_secs(3)).await; // let it settle

    // ---- C: loss on direct ----
    loss_direct(true)?;
    let t_loss = now();
    marks.push(("loss_on".into(), t_loss));
    println!("== C: 1/{LOSS_EVERY} loss on direct at {t_loss:.3}");
    tokio::time::sleep(phase_c).await;
    loss_direct(false)?;
    marks.push(("loss_off".into(), now()));
    tokio::time::sleep(Duration::from_secs(2)).await;

    // ---- D: break direct ----
    block_direct(true)?;
    let t_block = now();
    marks.push(("block_direct_again".into(), t_block));
    println!("== D: direct blocked at {t_block:.3}");
    let deadline = Instant::now() + phase_d_max;
    loop {
        let back_to_relay = events.lock().unwrap().iter().any(|e| {
            e.side == "client" && e.kind == "selected" && e.relay && e.t >= t_block
        });
        if back_to_relay || Instant::now() > deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    marks.push(("end".into(), now()));

    stop.store(true, Ordering::Relaxed);
    let dropped_local = sender.await?;
    conn.close(0u32.into(), b"done");
    tokio::time::sleep(Duration::from_millis(200)).await;
    host_task.abort();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let _ = tcpdump.kill();
    cleanup_rules();

    // ---------- write raw data ----------
    let events = events.lock().unwrap().clone();
    let samples = samples.lock().unwrap().clone();
    let wire = wire.lock().unwrap().clone();
    let mut s = String::from("t,side,kind,id,relay,addr,extra\n");
    for e in &events {
        let _ = writeln!(s, "{:.6},{},{},{},{},\"{}\",\"{}\"", e.t, e.side, e.kind, e.id, e.relay, e.addr, e.extra);
    }
    fs::write(format!("{out_dir}/events.csv"), s)?;
    let mut s = String::from("t,id,relay,selected,rtt_us,sent,lost,cwnd,poll_ns\n");
    for x in &samples {
        let _ = writeln!(s, "{:.6},{},{},{},{},{},{},{},{}", x.t, x.id, x.relay, x.selected, x.rtt_us, x.sent, x.lost, x.cwnd, x.poll_ns);
    }
    fs::write(format!("{out_dir}/stats.csv"), s)?;
    let mut s = String::from("name,t\n");
    for (n, t) in &marks {
        let _ = writeln!(s, "{n},{t:.6}");
    }
    fs::write(format!("{out_dir}/marks.csv"), s)?;

    // ---------- analysis ----------
    let ms = |a: f64, b: f64| (b - a) * 1000.0;
    let first_ev = |side: &str, kind: &str, relay: bool, after: f64| {
        events.iter().find(|e| e.side == side && e.kind == kind && e.relay == relay && e.t >= after).map(|e| e.t)
    };
    let big = |w: &&Wire| w.len >= 1000;
    let mut r = String::new();
    let _ = writeln!(r, "# S5 run summary\n");
    let _ = writeln!(r, "datagrams sent ~{} pps of {PKT} B; host received {}; sender-side send_datagram errors {dropped_local}\n", PPS, rx_count.load(Ordering::Relaxed));

    // A
    let a_paths: BTreeMap<String, bool> = samples.iter().filter(|x| x.t < t_unblock).map(|x| (x.id.clone(), x.relay)).collect();
    let a_rtt: Vec<u128> = samples.iter().filter(|x| x.t < t_unblock && x.relay && x.selected).map(|x| x.rtt_us).collect();
    let a_direct_wire = wire.iter().filter(|w| w.t < t_unblock && w.kind != WireKind::RelayTcp).count();
    let _ = writeln!(r, "## A: relay forced");
    let _ = writeln!(r, "- open paths seen before unblock: {a_paths:?}");
    let _ = writeln!(r, "- direct UDP packets on the wire before unblock: {a_direct_wire}");
    if let (Some(min), Some(max)) = (a_rtt.iter().min(), a_rtt.iter().max()) {
        let _ = writeln!(r, "- relay path RTT (selected): min {:.2} ms, max {:.2} ms, last {:.2} ms", *min as f64 / 1e3, *max as f64 / 1e3, *a_rtt.last().unwrap() as f64 / 1e3);
    }

    // B
    let _ = writeln!(r, "\n## B: direct allowed");
    let w_c2h = wire.iter().find(|w| w.t >= t_unblock && w.kind == WireKind::DirectClientToHost).map(|w| w.t);
    let w_h2c = wire.iter().find(|w| w.t >= t_unblock && w.kind == WireKind::DirectHostToClient).map(|w| w.t);
    let w_bidir = match (w_c2h, w_h2c) { (Some(a), Some(b)) => Some(a.max(b)), _ => None };
    let w_data = wire.iter().filter(big).find(|w| w.t >= t_unblock && w.kind == WireKind::DirectClientToHost).map(|w| w.t);
    let e_open = first_ev("client", "opened", false, t_unblock);
    let e_sel = first_ev("client", "selected", false, t_unblock);
    let h_open = first_ev("host", "opened", false, t_unblock);
    let h_sel = first_ev("host", "selected", false, t_unblock);
    let fmt = |o: Option<f64>, base: f64| o.map(|t| format!("{:+.1} ms", ms(base, t))).unwrap_or("never".into());
    let _ = writeln!(r, "relative to unblock:");
    let _ = writeln!(r, "- first direct packet on wire (client->host): {}", fmt(w_c2h, t_unblock));
    let _ = writeln!(r, "- direct packets both ways: {}", fmt(w_bidir, t_unblock));
    let _ = writeln!(r, "- first full-size datagram on direct: {}", fmt(w_data, t_unblock));
    let _ = writeln!(r, "- client Opened(direct): {}  Selected(direct): {}", fmt(e_open, t_unblock), fmt(e_sel, t_unblock));
    let _ = writeln!(r, "- host   Opened(direct): {}  Selected(direct): {}", fmt(h_open, t_unblock), fmt(h_sel, t_unblock));
    if let (Some(b), Some(o)) = (w_bidir, e_open) {
        let _ = writeln!(r, "- **event lag: client Opened after first bidirectional direct packet: {:.1} ms**", ms(b, o));
    }
    if let (Some(d), Some(sl)) = (w_data, e_sel) {
        let _ = writeln!(r, "- **event lag: client Selected vs first data on direct: {:+.1} ms** (negative = event before data moved)", ms(d, sl));
    }
    let b_rtt: Vec<u128> = samples.iter().filter(|x| x.t > t_unblock && x.t < t_loss && !x.relay).map(|x| x.rtt_us).collect();
    if let (Some(min), Some(max)) = (b_rtt.iter().min(), b_rtt.iter().max()) {
        let _ = writeln!(r, "- direct path RTT: min {:.3} ms, max {:.3} ms", *min as f64 / 1e3, *max as f64 / 1e3);
    }
    let both: Vec<&Sample> = samples.iter().filter(|x| x.t > t_unblock && x.t < t_loss).collect();
    let concurrently_open = both.iter().any(|x| x.relay) && both.iter().any(|x| !x.relay);
    let _ = writeln!(r, "- relay and direct paths open at the same time with separate stats: {concurrently_open}");

    // C
    let _ = writeln!(r, "\n## C: 1/{LOSS_EVERY} loss on direct");
    let direct_ids: Vec<String> = samples.iter().filter(|x| !x.relay && x.t > t_loss).map(|x| x.id.clone()).collect();
    let did = direct_ids.first().cloned().unwrap_or_default();
    let base_lost = samples.iter().filter(|x| x.id == did && x.t <= t_loss).map(|x| x.lost).last().unwrap_or(0);
    let base_sent = samples.iter().filter(|x| x.id == did && x.t <= t_loss).map(|x| x.sent).last().unwrap_or(0);
    let first_loss = samples.iter().find(|x| x.id == did && x.t > t_loss && x.lost > base_lost).map(|x| x.t);
    let t_loss_off = marks.iter().find(|m| m.0 == "loss_off").unwrap().1;
    let end_c = samples.iter().filter(|x| x.id == did && x.t <= t_loss_off).last();
    let _ = writeln!(r, "- first lost_packets increment on direct path: {}", fmt(first_loss, t_loss));
    let first_drop_bound = LOSS_EVERY as f64 / PPS as f64 * 1000.0;
    let _ = writeln!(r, "  (first injected drop happens within ~{first_drop_bound:.0} ms of loss_on at this send rate)");
    if let Some(e) = end_c {
        let sent = e.sent - base_sent;
        let lost = e.lost - base_lost;
        let _ = writeln!(r, "- during C: sent {sent}, lost {lost} => {:.2}% (injected {:.2}% one way at client egress plus same on acks)", 100.0 * lost as f64 / sent.max(1) as f64, 100.0 / LOSS_EVERY as f64);
    }
    let rel_lost: Vec<u64> = samples.iter().filter(|x| x.relay && x.t > t_loss && x.t < t_loss_off).map(|x| x.lost).collect();
    let _ = writeln!(r, "- relay path lost_packets during C: {:?}..{:?}", rel_lost.first(), rel_lost.last());

    // D
    let _ = writeln!(r, "\n## D: direct broken again");
    let d_sel = first_ev("client", "selected", true, t_block);
    let d_close = first_ev("client", "closed", false, t_block);
    let d_data = wire.iter().filter(big).find(|w| w.t >= t_block + 0.0 && w.kind == WireKind::RelayTcp).map(|w| w.t);
    let last_direct_ok = wire.iter().filter(|w| w.kind != WireKind::RelayTcp).map(|w| w.t).fold(0.0, f64::max);
    let _ = writeln!(r, "relative to block:");
    let _ = writeln!(r, "- last direct packet on wire: {:+.1} ms", ms(t_block, last_direct_ok));
    let _ = writeln!(r, "- first full-size packet on relay TCP: {}", fmt(d_data, t_block));
    let _ = writeln!(r, "- client Selected(relay): {}  Closed(direct): {}", fmt(d_sel, t_block), fmt(d_close, t_block));
    if let (Some(d), Some(sl)) = (d_data, d_sel) {
        let _ = writeln!(r, "- **event lag: Selected(relay) vs first data on relay: {:+.1} ms**", ms(d, sl));
    }
    let rtt_d: Vec<(f64, u128)> = samples.iter().filter(|x| x.t > t_block && !x.relay).map(|x| (ms(t_block, x.t), x.rtt_us)).collect();
    if let Some(last) = rtt_d.last() {
        let _ = writeln!(r, "- direct path RTT estimate kept reporting until {:+.0} ms (last {:.2} ms)", last.0, last.1 as f64 / 1e3);
    }

    // media outage as seen by the receiver
    let rx_times = rx_times.lock().unwrap().clone();
    let gap = |from: f64, to: f64| {
        let mut prev = from;
        let mut worst = 0.0f64;
        for &t in rx_times.iter().filter(|&&t| t >= from && t <= to) {
            worst = worst.max(t - prev);
            prev = t;
        }
        worst * 1000.0
    };
    let t_end = marks.iter().find(|m| m.0 == "end").unwrap().1;
    let _ = writeln!(r, "\n## Receiver-side datagram gaps (longest gap in host receive)");
    let _ = writeln!(r, "- B (relay -> direct switch): {:.1} ms", gap(t_unblock, t_loss));
    let _ = writeln!(r, "- D (direct blackholed -> relay): {:.1} ms", gap(t_block, t_end));

    // stats polling cost
    let mut polls: Vec<u128> = samples.iter().map(|x| x.poll_ns).collect();
    polls.sort();
    if !polls.is_empty() {
        let p = |q: f64| polls[((polls.len() - 1) as f64 * q) as usize] as f64 / 1e3;
        let _ = writeln!(r, "\n## Stats polling cost (Connection::paths() + stats() for all paths)");
        let _ = writeln!(r, "- p50 {:.1} us, p99 {:.1} us, max {:.1} us over {} polls", p(0.5), p(0.99), p(1.0), polls.len());
    }

    println!("\n{r}");
    fs::write(format!("{out_dir}/summary.md"), &r)?;
    host.close().await;
    client.close().await;
    Ok(())
}
