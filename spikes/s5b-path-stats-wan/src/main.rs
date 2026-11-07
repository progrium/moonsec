//! Spike S5b: S5 (iroh path visibility) rerun across a real network.
//!
//! Two machines, one binary:
//!
//!   host   (Linux, root): binds one iroh endpoint per transport config on fixed UDP
//!          ports, streams ~18 Mbit/s of 1150-byte datagrams to whoever connects, echoes
//!          RTT probes, and applies impairments to its own direct-path UDP port when the
//!          client asks: iptables (block, random loss) and tc netem (delay, jitter).
//!          Relay traffic is TLS over TCP to the n0 relays and is never touched.
//!   client (any OS): dials the host by key + relay URL only, so every connection starts
//!          on the relay and has to hole-punch to go direct. Drives the test plan over a
//!          control stream, logs path events, polls path stats every 1 ms, sends RTT
//!          probes and records every media datagram it receives.
//!
//! At the end the host ships its own event/stat/wire logs back over the control stream,
//! so all raw data lands on the client. `analyze.py` turns a run directory into a summary.

use std::{
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
use bytes::{BufMut, BytesMut};
use iroh::{
    Endpoint, EndpointAddr, RelayMode, RelayUrl,
    endpoint::{BindOpts, Connection, PathEvent, QuicTransportConfig, presets},
};
use tokio::io::AsyncBufReadExt;
use tokio_stream::StreamExt;

const ALPN: &[u8] = b"moonsec/s5b";
const PKT: usize = 1150;

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()
}

// ---------------------------------------------------------------- shared logging

#[derive(Default)]
struct Logs {
    events: Mutex<String>,
    samples: Mutex<String>,
}

impl Logs {
    fn new() -> Arc<Self> {
        let l = Logs::default();
        l.events.lock().unwrap().push_str("t,side,kind,id,relay,addr,extra\n");
        l.samples
            .lock()
            .unwrap()
            .push_str("t,id,relay,selected,rtt_us,sent,lost,lost_bytes,cwnd,cong,udp_tx,udp_rx,poll_ns\n");
        Arc::new(l)
    }
}

fn watch_events(side: &'static str, conn: &Connection, logs: Arc<Logs>, verbose: bool) {
    let mut events = conn.path_events();
    tokio::spawn(async move {
        while let Some(ev) = events.next().await {
            let t = now();
            let (kind, id, relay, addr, extra) = match ev {
                PathEvent::Opened { id, remote_addr, .. } => {
                    ("opened", format!("{id:?}"), remote_addr.is_relay(), format!("{remote_addr:?}"), String::new())
                }
                PathEvent::Selected { id, remote_addr, .. } => {
                    ("selected", format!("{id:?}"), remote_addr.is_relay(), format!("{remote_addr:?}"), String::new())
                }
                PathEvent::Closed { id, remote_addr, last_stats, .. } => (
                    "closed",
                    format!("{id:?}"),
                    remote_addr.is_relay(),
                    format!("{remote_addr:?}"),
                    format!(
                        "rtt={:?} sent={} lost={}",
                        last_stats.rtt, last_stats.sent_packets, last_stats.lost_packets
                    ),
                ),
                PathEvent::Lagged { missed, .. } => {
                    ("lagged", String::new(), false, String::new(), format!("missed={missed}"))
                }
                other => ("other", String::new(), false, String::new(), format!("{other:?}")),
            };
            if verbose {
                println!("[{t:.3}] {side:<6} {kind:<8} {id} relay={relay} {addr} {extra}");
            }
            let _ = writeln!(
                logs.events.lock().unwrap(),
                "{t:.6},{side},{kind},{id},{relay},\"{addr}\",\"{extra}\""
            );
        }
    });
}

/// Polls `Connection::paths()` every `every` on its own thread, as a shim would.
fn sample_stats(conn: Connection, logs: Arc<Logs>, stop: Arc<AtomicBool>, every: Duration) {
    std::thread::spawn(move || {
        let mut buf = String::new();
        while !stop.load(Ordering::Relaxed) {
            let t = now();
            let t0 = Instant::now();
            let paths = conn.paths();
            let rows: Vec<_> = paths
                .iter()
                .map(|p| (format!("{:?}", p.id()), p.is_relay(), p.is_selected(), p.stats()))
                .collect();
            let poll_ns = t0.elapsed().as_nanos();
            for (id, relay, sel, s) in rows {
                let _ = writeln!(
                    buf,
                    "{t:.6},{id},{relay},{sel},{},{},{},{},{},{},{},{},{poll_ns}",
                    s.rtt.as_micros(),
                    s.sent_packets,
                    s.lost_packets,
                    s.lost_bytes,
                    s.cwnd,
                    s.congestion_events,
                    s.udp_tx.datagrams,
                    s.udp_rx.datagrams,
                );
            }
            if buf.len() > 64 * 1024 {
                logs.samples.lock().unwrap().push_str(&buf);
                buf.clear();
            }
            std::thread::sleep(every);
        }
        logs.samples.lock().unwrap().push_str(&buf);
    });
}

fn transport_config(idle_ms: Option<u64>, keepalive_ms: Option<u64>) -> QuicTransportConfig {
    let mut tc = QuicTransportConfig::builder();
    if let Some(ms) = idle_ms {
        tc = tc.default_path_max_idle_timeout(Duration::from_millis(ms));
    }
    if let Some(ms) = keepalive_ms {
        tc = tc.default_path_keep_alive_interval(Duration::from_millis(ms));
    }
    tc.build()
}

/// "300:100" -> (Some(300), Some(100)); "-" -> defaults.
fn parse_cfg(s: &str) -> Result<(Option<u64>, Option<u64>)> {
    if s == "-" || s == "default" {
        return Ok((None, None));
    }
    let (a, b) = s.split_once(':').context("cfg is idle_ms:keepalive_ms or -")?;
    Ok((Some(a.parse()?), Some(b.parse()?)))
}

// ---------------------------------------------------------------- host impairments

fn sh(cmd: &str, args: &[&str]) -> Result<()> {
    let st = Command::new(cmd).args(args).stderr(Stdio::null()).status().with_context(|| format!("run {cmd}"))?;
    if !st.success() {
        bail!("{cmd} {} failed", args.join(" "));
    }
    Ok(())
}

#[derive(Clone, Copy, Default, Debug)]
struct Impair {
    blocked: bool,
    loss_pct: f64,
}

struct Firewall {
    port: u16,
    v6: bool,
}

impl Firewall {
    fn chains(&self) -> (String, String) {
        (format!("S5B_{}_IN", self.port), format!("S5B_{}_OUT", self.port))
    }
    fn bins(&self) -> Vec<&'static str> {
        if self.v6 { vec!["iptables", "ip6tables"] } else { vec!["iptables"] }
    }
    fn setup(port: u16) -> Result<Self> {
        let v6 = Command::new("ip6tables").arg("-L").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
        let fw = Firewall { port, v6 };
        fw.teardown();
        let (cin, cout) = fw.chains();
        let p = port.to_string();
        for b in fw.bins() {
            sh(b, &["-N", &cin])?;
            sh(b, &["-N", &cout])?;
            sh(b, &["-I", "INPUT", "-p", "udp", "--dport", &p, "-j", &cin])?;
            sh(b, &["-I", "OUTPUT", "-p", "udp", "--sport", &p, "-j", &cout])?;
        }
        Ok(fw)
    }
    fn apply(&self, s: Impair) -> Result<()> {
        let (cin, cout) = self.chains();
        for b in self.bins() {
            sh(b, &["-F", &cin])?;
            sh(b, &["-F", &cout])?;
            if s.blocked {
                sh(b, &["-A", &cin, "-j", "DROP"])?;
                sh(b, &["-A", &cout, "-j", "DROP"])?;
            } else if s.loss_pct > 0.0 {
                // host -> client only, so the host's own lost_packets is the thing to check
                let p = format!("{:.4}", s.loss_pct / 100.0);
                sh(b, &["-A", &cout, "-m", "statistic", "--mode", "random", "--probability", &p, "-j", "DROP"])?;
            }
        }
        Ok(())
    }
    fn teardown(&self) {
        let (cin, cout) = self.chains();
        let p = self.port.to_string();
        for b in ["iptables", "ip6tables"] {
            while sh(b, &["-D", "INPUT", "-p", "udp", "--dport", &p, "-j", &cin]).is_ok() {}
            while sh(b, &["-D", "OUTPUT", "-p", "udp", "--sport", &p, "-j", &cout]).is_ok() {}
            let _ = sh(b, &["-F", &cin]);
            let _ = sh(b, &["-F", &cout]);
            let _ = sh(b, &["-X", &cin]);
            let _ = sh(b, &["-X", &cout]);
        }
    }
}

/// tc netem on egress, scoped to our UDP source ports via a 4-band prio qdisc.
struct Netem {
    dev: String,
}

impl Netem {
    fn setup(ports: &[u16]) -> Result<Self> {
        let out = Command::new("ip").args(["route", "get", "1.1.1.1"]).output()?;
        let s = String::from_utf8_lossy(&out.stdout);
        let dev = s
            .split_whitespace()
            .skip_while(|t| *t != "dev")
            .nth(1)
            .context("no default dev")?
            .to_string();
        let _ = sh("tc", &["qdisc", "del", "dev", &dev, "root"]);
        sh("tc", &["qdisc", "add", "dev", &dev, "root", "handle", "1:", "prio", "bands", "4", "priomap", "1", "2", "2", "2", "1", "2", "0", "0", "1", "1", "1", "1", "1", "1", "1", "1"])?;
        sh("tc", &["qdisc", "add", "dev", &dev, "parent", "1:4", "handle", "40:", "netem", "delay", "0ms", "limit", "100000"])?;
        for p in ports {
            let p = p.to_string();
            sh("tc", &["filter", "add", "dev", &dev, "parent", "1:", "protocol", "ip", "prio", "1", "u32", "match", "ip", "sport", &p, "0xffff", "flowid", "1:4"])?;
            let _ = sh("tc", &["filter", "add", "dev", &dev, "parent", "1:", "protocol", "ipv6", "prio", "2", "u32", "match", "ip6", "sport", &p, "0xffff", "flowid", "1:4"]);
        }
        println!("netem on {dev} for ports {ports:?}");
        Ok(Netem { dev })
    }
    fn set(&self, delay_ms: f64, jitter_ms: f64) -> Result<()> {
        let d = format!("{delay_ms}ms");
        let j = format!("{jitter_ms}ms");
        let mut args = vec!["qdisc", "change", "dev", &self.dev, "parent", "1:4", "handle", "40:", "netem", "delay", &d];
        if jitter_ms > 0.0 {
            args.extend_from_slice(&[&j, "distribution", "normal"]);
        }
        args.extend_from_slice(&["limit", "100000"]);
        sh("tc", &args)
    }
    fn teardown(&self) {
        let _ = sh("tc", &["qdisc", "del", "dev", &self.dev, "root"]);
    }
}

// ---------------------------------------------------------------- host wire capture

fn spawn_tcpdump(ports: &[u16], out: Arc<Mutex<String>>) -> Result<std::process::Child> {
    let filter = ports.iter().map(|p| format!("udp port {p}")).collect::<Vec<_>>().join(" or ");
    let mut child = Command::new("tcpdump")
        .args(["-i", "any", "-n", "-tt", "-l", "-q", "--immediate-mode", &filter])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("spawn tcpdump")?;
    let stdout = child.stdout.take().unwrap();
    let ports: Vec<String> = ports.iter().map(|p| format!(".{p}")).collect();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            // 1730000000.123456 eth0  Out IP 1.2.3.4.47001 > 5.6.7.8.1234: UDP, length 1200
            let toks: Vec<&str> = line.split_whitespace().collect();
            let Some(t) = toks.first().and_then(|s| s.parse::<f64>().ok()) else { continue };
            let Some(ip) = toks.iter().position(|s| *s == "IP" || *s == "IP6") else { continue };
            let (Some(src), Some(dst)) = (toks.get(ip + 1), toks.get(ip + 3)) else { continue };
            let len = toks.last().and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            let (dir, port, peer) = if let Some(p) = ports.iter().find(|p| src.ends_with(*p)) {
                ("out", p, dst.trim_end_matches(':'))
            } else if let Some(p) = ports.iter().find(|p| dst.trim_end_matches(':').ends_with(*p)) {
                ("in", p, *src)
            } else {
                continue;
            };
            let _ = writeln!(out.lock().unwrap(), "{t:.6},{dir},{},{peer},{len}", &port[1..]);
        }
    });
    Ok(child)
}

// ---------------------------------------------------------------- host

struct HostShared {
    netem: Option<Netem>,
    wire: Arc<Mutex<String>>,
}

async fn run_host() -> Result<()> {
    let base: u16 = std::env::var("S5B_BASE_PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(47001);
    let cfgs = std::env::var("S5B_CONFIGS").unwrap_or_else(|_| "idle300=300:100,idle1000=1000:200,default=-".into());
    let mut specs = vec![];
    for (i, c) in cfgs.split(',').enumerate() {
        let (name, cfg) = c.split_once('=').context("S5B_CONFIGS entries are name=idle:keepalive")?;
        specs.push((name.to_string(), parse_cfg(cfg)?, base + i as u16));
    }
    let ports: Vec<u16> = specs.iter().map(|s| s.2).collect();
    let netem = match Netem::setup(&ports) {
        Ok(n) => Some(n),
        Err(e) => {
            eprintln!("netem unavailable ({e:#}); delay commands will fail");
            None
        }
    };
    let wire = Arc::new(Mutex::new(String::from("t,dir,port,peer,len\n")));
    let mut tcpdump = spawn_tcpdump(&ports, wire.clone()).ok();
    if tcpdump.is_none() {
        eprintln!("tcpdump unavailable; no wire log");
    }
    let shared = Arc::new(HostShared { netem, wire });

    let mut fws = vec![];
    let mut tasks = vec![];
    for (name, (idle, ka), port) in specs {
        let fw = match Firewall::setup(port) {
            Ok(f) => Some(Arc::new(f)),
            Err(e) => {
                eprintln!("firewall unavailable on {port} ({e:#}); block/loss commands will fail");
                None
            }
        };
        fws.extend(fw.clone());
        let ep = Endpoint::builder(presets::Minimal)
            .relay_mode(RelayMode::Default)
            .alpns(vec![ALPN.to_vec()])
            .transport_config(transport_config(idle, ka))
            .clear_ip_transports()
            .bind_addr(format!("0.0.0.0:{port}").as_str())?
            .bind_addr_with_opts(format!("[::]:{port}").as_str(), BindOpts::default().set_is_required(false))?
            .bind()
            .await?;
        ep.online().await;
        let addr = ep.addr();
        let relay = addr.relay_urls().next().map(|u| u.to_string()).unwrap_or_default();
        println!("CONFIG {name} port={port} idle={idle:?} keepalive={ka:?}");
        println!("  client cmd: s5b client {} {relay} <out_dir> <plan>  (env S5B_CFG={})",
            ep.id(), idle.map(|i| format!("{i}:{}", ka.unwrap())).unwrap_or("-".into()));
        println!("  addrs: {:?}", addr.addrs);
        let shared = shared.clone();
        tasks.push(tokio::spawn(async move {
            while let Some(inc) = ep.accept().await {
                let fw = fw.clone();
                let shared = shared.clone();
                let name = name.clone();
                tokio::spawn(async move {
                    match inc.await {
                        Ok(conn) => {
                            println!("[{:.3}] {name}: connection from {}", now(), conn.remote_id());
                            if let Err(e) = host_session(conn, fw.as_deref(), port, &shared).await {
                                println!("[{:.3}] {name}: session ended: {e:#}", now());
                            }
                            if let Some(fw) = &fw {
                                let _ = fw.apply(Impair::default());
                            }
                            if let Some(n) = &shared.netem {
                                let _ = n.set(0.0, 0.0);
                            }
                        }
                        Err(e) => println!("accept failed: {e:#}"),
                    }
                });
            }
        }));
    }

    tokio::signal::ctrl_c().await?;
    println!("cleaning up");
    for fw in &fws {
        fw.teardown();
    }
    if let Some(n) = &shared.netem {
        n.teardown();
    }
    if let Some(t) = tcpdump.as_mut() {
        let _ = t.kill();
    }
    Ok(())
}

async fn host_session(conn: Connection, fw: Option<&Firewall>, port: u16, shared: &HostShared) -> Result<()> {
    let fw_apply = |s: Impair| fw.context("no firewall").and_then(|f| f.apply(s));
    let t_start = now();
    let logs = Logs::new();
    let stop = Arc::new(AtomicBool::new(false));
    watch_events("host", &conn, logs.clone(), false);
    let pps = Arc::new(AtomicU64::new(0));

    // datagrams: echo probes
    {
        let conn = conn.clone();
        tokio::spawn(async move {
            while let Ok(d) = conn.read_datagram().await {
                if d.first() == Some(&1) && d.len() >= 17 {
                    let mut b = BytesMut::with_capacity(25);
                    b.put_u8(2);
                    b.put_slice(&d[1..17]);
                    b.put_f64(now());
                    let _ = conn.send_datagram(b.freeze());
                }
            }
        });
    }
    // media sender
    {
        let conn = conn.clone();
        let stop = stop.clone();
        let pps = pps.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(1));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Burst);
            let mut seq = 0u64;
            let mut credit = 0.0f64;
            while !stop.load(Ordering::Relaxed) {
                tick.tick().await;
                credit += pps.load(Ordering::Relaxed) as f64 / 1000.0;
                while credit >= 1.0 {
                    credit -= 1.0;
                    let mut b = BytesMut::with_capacity(PKT);
                    b.put_u8(0);
                    b.put_u64(seq);
                    b.put_f64(now());
                    b.resize(PKT, 0);
                    seq += 1;
                    let _ = conn.send_datagram(b.freeze());
                }
            }
        });
    }

    let (mut send, recv) = conn.accept_bi().await?;
    let mut lines = tokio::io::BufReader::new(recv).lines();
    let mut state = Impair::default();
    let mut sampling = false;
    while let Some(line) = lines.next_line().await? {
        let toks: Vec<&str> = line.split_whitespace().collect();
        let arg = |i: usize| toks.get(i).and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
        let mut res = Ok(());
        match toks.first().copied().unwrap_or("") {
            "sample" if !sampling => {
                sampling = true;
                sample_stats(conn.clone(), logs.clone(), stop.clone(), Duration::from_millis(arg(1).max(1.0) as u64));
            }
            "media" => pps.store(arg(1) as u64, Ordering::Relaxed),
            "block" => { state.blocked = true; res = fw_apply(state); }
            "unblock" => { state.blocked = false; res = fw_apply(state); }
            "loss" => { state.loss_pct = arg(1); res = fw_apply(state); }
            "delay" => res = shared.netem.as_ref().context("no netem").and_then(|n| n.set(arg(1), arg(2))),
            "blackout" => {
                let ms = arg(1);
                state.blocked = true;
                res = fw_apply(state);
                let t_on = now();
                tokio::time::sleep(Duration::from_secs_f64(ms / 1000.0)).await;
                state.blocked = false;
                res = res.and(fw_apply(state));
                send.write_all(format!("ok blackout_on {t_on:.6}\n").as_bytes()).await?;
            }
            "logs" => {
                stop.store(true, Ordering::Relaxed);
                pps.store(0, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_millis(50)).await;
                let wire: String = {
                    let w = shared.wire.lock().unwrap();
                    let mut out = String::from("t,dir,port,peer,len\n");
                    let port = port.to_string();
                    for l in w.lines().skip(1) {
                        let mut f = l.split(',');
                        let t: f64 = f.next().and_then(|s| s.parse().ok()).unwrap_or(0.0);
                        let _ = f.next();
                        if t >= t_start - 1.0 && f.next() == Some(port.as_str()) {
                            out.push_str(l);
                            out.push('\n');
                        }
                    }
                    out
                };
                let blob = format!(
                    "=== host_events.csv\n{}=== host_stats.csv\n{}=== host_wire.csv\n{}",
                    logs.events.lock().unwrap(),
                    logs.samples.lock().unwrap(),
                    wire
                );
                send.write_all(format!("LOGS {}\n", blob.len()).as_bytes()).await?;
                send.write_all(blob.as_bytes()).await?;
                continue;
            }
            "bye" => break,
            _ => {}
        }
        let t = now();
        match res {
            Ok(()) => send.write_all(format!("ok {} {t:.6}\n", toks.first().unwrap_or(&"")).as_bytes()).await?,
            Err(e) => send.write_all(format!("err {} {t:.6} {e:#}\n", toks.first().unwrap_or(&"")).as_bytes()).await?,
        }
    }
    stop.store(true, Ordering::Relaxed);
    let _ = send.finish();
    let _ = tokio::time::timeout(Duration::from_secs(2), conn.closed()).await;
    Ok(())
}

// ---------------------------------------------------------------- client

struct Ctl {
    send: iroh::endpoint::SendStream,
    lines: tokio::io::Lines<tokio::io::BufReader<iroh::endpoint::RecvStream>>,
    marks: String,
}

impl Ctl {
    /// Sends a command, records client send time and host apply time.
    async fn cmd(&mut self, c: &str) -> Result<f64> {
        let t_send = now();
        println!("[{t_send:.3}] >> {c}");
        self.send.write_all(format!("{c}\n").as_bytes()).await?;
        let reply = self.lines.next_line().await?.context("control closed")?;
        let t_reply = now();
        let toks: Vec<&str> = reply.split_whitespace().collect();
        let host_t: f64 = toks.get(2).and_then(|s| s.parse().ok()).unwrap_or(0.0);
        if toks.first() != Some(&"ok") {
            println!("   !! {reply}");
        }
        let _ = writeln!(self.marks, "{},{t_send:.6},{t_reply:.6},{host_t:.6}", c.replace(' ', "_"));
        Ok(host_t)
    }
}

struct ClientRun {
    conn: Connection,
    ep: Endpoint,
    logs: Arc<Logs>,
    stop: Arc<AtomicBool>,
    rx: Arc<Mutex<String>>,
    probes: Arc<Mutex<String>>,
    t_bind: f64,
    t_online: f64,
    t_connect: f64,
    t_connected: f64,
}

async fn client_connect(id: &str, relay: &str, sample_ms: u64, record: bool) -> Result<ClientRun> {
    let (idle, ka) = parse_cfg(&std::env::var("S5B_CFG").unwrap_or("-".into()))?;
    let t_bind = now();
    let ep = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Default)
        .alpns(vec![ALPN.to_vec()])
        .transport_config(transport_config(idle, ka))
        .bind()
        .await?;
    ep.online().await;
    let t_online = now();
    let addr = EndpointAddr::new(id.parse()?).with_relay_url(relay.parse::<RelayUrl>()?);
    let logs = Logs::new();
    let t_connect = now();
    let conn = ep.connect(addr, ALPN).await?;
    let t_connected = now();
    watch_events("client", &conn, logs.clone(), true);
    let stop = Arc::new(AtomicBool::new(false));
    if sample_ms > 0 {
        sample_stats(conn.clone(), logs.clone(), stop.clone(), Duration::from_millis(sample_ms));
    }
    let rx = Arc::new(Mutex::new(String::from("t,seq,host_t\n")));
    let probes = Arc::new(Mutex::new(String::from("seq,t_send,t_recv,host_t\n")));
    {
        let conn = conn.clone();
        let rx = rx.clone();
        let probes = probes.clone();
        tokio::spawn(async move {
            let mut buf = String::new();
            while let Ok(d) = conn.read_datagram().await {
                let t = now();
                match d.first() {
                    Some(0) if record && d.len() >= 17 => {
                        let seq = u64::from_be_bytes(d[1..9].try_into().unwrap());
                        let ht = f64::from_be_bytes(d[9..17].try_into().unwrap());
                        let _ = writeln!(buf, "{t:.6},{seq},{ht:.6}");
                        if buf.len() > 64 * 1024 {
                            rx.lock().unwrap().push_str(&buf);
                            buf.clear();
                        }
                    }
                    Some(2) if d.len() >= 25 => {
                        let seq = u64::from_be_bytes(d[1..9].try_into().unwrap());
                        let ts = f64::from_be_bytes(d[9..17].try_into().unwrap());
                        let ht = f64::from_be_bytes(d[17..25].try_into().unwrap());
                        let _ = writeln!(probes.lock().unwrap(), "{seq},{ts:.6},{t:.6},{ht:.6}");
                    }
                    _ => {}
                }
            }
            rx.lock().unwrap().push_str(&buf);
        });
    }
    // RTT probes every 10 ms
    {
        let conn = conn.clone();
        let stop = stop.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_millis(10));
            let mut seq = 0u64;
            while !stop.load(Ordering::Relaxed) {
                tick.tick().await;
                let mut b = BytesMut::with_capacity(17);
                b.put_u8(1);
                b.put_u64(seq);
                b.put_f64(now());
                seq += 1;
                let _ = conn.send_datagram(b.freeze());
            }
        });
    }
    Ok(ClientRun { conn, ep, logs, stop, rx, probes, t_bind, t_online, t_connect, t_connected })
}

fn has_event(logs: &Logs, side: &str, kind: &str, relay: bool, after: f64) -> Option<f64> {
    let ev = logs.events.lock().unwrap();
    ev.lines().skip(1).find_map(|l| {
        let f: Vec<&str> = l.splitn(6, ',').collect();
        let t: f64 = f[0].parse().ok()?;
        (t >= after && f[1] == side && f[2] == kind && f[4] == relay.to_string()).then_some(t)
    })
}

async fn wait_event(logs: &Logs, kind: &str, relay: bool, after: f64, max: Duration) -> Option<f64> {
    let deadline = Instant::now() + max;
    loop {
        if let Some(t) = has_event(logs, "client", kind, relay, after) {
            return Some(t);
        }
        if Instant::now() > deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

async fn back_to_direct(conn: &Connection, max: Duration) {
    let deadline = Instant::now() + max;
    while Instant::now() < deadline {
        if conn.paths().iter().any(|p| p.is_selected() && !p.is_relay()) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    println!("   !! not back on direct after {max:?}");
}

async fn hold(s: f64) {
    tokio::time::sleep(Duration::from_secs_f64(s)).await;
}

async fn run_client(id: String, relay: String, out: String, plan: String) -> Result<()> {
    fs::create_dir_all(&out)?;
    let (plan_name, plan_arg) = plan.split_once(':').unwrap_or((plan.as_str(), ""));
    if plan_name == "punch" {
        return run_punch(&id, &relay, &out, plan_arg.parse().unwrap_or(10)).await;
    }
    let pps: u64 = std::env::var("S5B_PPS").ok().and_then(|s| s.parse().ok()).unwrap_or(2000);
    let quick: f64 = std::env::var("S5B_HOLD_SCALE").ok().and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let h = |s: f64| hold(s * quick);

    // The connection starts on the relay (dialed by key + relay URL) and hole-punches;
    // the plan then forces relay and direct with the host firewall.
    let run = client_connect(&id, &relay, 1, true).await?;
    let (send, recv) = run.conn.open_bi().await?;
    let mut ctl = Ctl { send, lines: tokio::io::BufReader::new(recv).lines(), marks: String::from("cmd,t_send,t_reply,host_t\n") };
    let _ = writeln!(ctl.marks, "bind,{:.6},{:.6},0", run.t_bind, run.t_online);
    let _ = writeln!(ctl.marks, "connect,{:.6},{:.6},0", run.t_connect, run.t_connected);
    ctl.cmd("sample 1").await?;
    ctl.cmd(&format!("media {pps}")).await?;

    let first_direct = wait_event(&run.logs, "selected", false, run.t_connect, Duration::from_secs(20)).await;
    println!("natural time to direct: {:?} ms", first_direct.map(|t| (t - run.t_connect) * 1e3));

    match plan_name {
        "soak" => {
            let secs: f64 = plan_arg.parse().unwrap_or(300.0);
            ctl.cmd("mark soak").await.ok();
            h(secs).await;
        }
        "full" => {
            h(5.0).await;
            // A/B: force relay, then allow direct
            ctl.cmd("block").await?;
            let t = now();
            let r = wait_event(&run.logs, "selected", true, t, Duration::from_secs(40)).await;
            println!("block -> relay: {:?} ms", r.map(|x| (x - t) * 1e3));
            h(5.0).await;
            ctl.cmd("unblock").await?;
            let t = now();
            let d = wait_event(&run.logs, "selected", false, t, Duration::from_secs(30)).await;
            println!("unblock -> direct: {:?} ms", d.map(|x| (x - t) * 1e3));
            h(15.0).await; // baseline
            for pct in [2.0, 5.0, 20.0] {
                ctl.cmd(&format!("loss {pct}")).await?;
                h(10.0).await;
                ctl.cmd("loss 0").await?;
                h(4.0).await;
            }
            for (d, j) in [(25.0, 0.0), (50.0, 0.0), (100.0, 0.0), (150.0, 0.0), (250.0, 0.0), (400.0, 0.0), (0.0, 0.0), (20.0, 10.0), (40.0, 30.0), (0.0, 0.0)] {
                ctl.cmd(&format!("delay {d} {j}")).await?;
                h(if d == 0.0 { 5.0 } else { 12.0 }).await;
                // make sure we are back on direct before the next step
                back_to_direct(&run.conn, Duration::from_secs(20)).await;
            }
            for ms in [50, 100, 150, 200, 250, 300, 400, 600] {
                ctl.cmd(&format!("blackout {ms}")).await?;
                h(6.0).await;
                back_to_direct(&run.conn, Duration::from_secs(20)).await;
            }
            ctl.cmd("block").await?;
            let t = now();
            let r = wait_event(&run.logs, "selected", true, t, Duration::from_secs(40)).await;
            println!("block -> relay: {:?} ms", r.map(|x| (x - t) * 1e3));
            h(3.0).await;
            ctl.cmd("unblock").await?;
            let t = now();
            let d = wait_event(&run.logs, "selected", false, t, Duration::from_secs(30)).await;
            println!("unblock -> direct: {:?} ms", d.map(|x| (x - t) * 1e3));
            h(5.0).await;
        }
        other => bail!("unknown plan {other}"),
    }

    // collect host logs
    ctl.send.write_all(b"logs\n").await?;
    let hdr = loop {
        let l = ctl.lines.next_line().await?.context("control closed before logs")?;
        if l.starts_with("LOGS ") {
            break l;
        }
    };
    let n: usize = hdr[5..].trim().parse()?;
    let mut blob = vec![0u8; n];
    {
        use tokio::io::AsyncReadExt;
        ctl.lines.get_mut().read_exact(&mut blob).await?;
    }
    let blob = String::from_utf8_lossy(&blob);
    for part in blob.split("=== ").filter(|s| !s.is_empty()) {
        let (name, body) = part.split_once('\n').unwrap_or((part, ""));
        fs::write(format!("{out}/{}", name.trim()), body)?;
    }
    ctl.send.write_all(b"bye\n").await?;
    run.stop.store(true, Ordering::Relaxed);
    tokio::time::sleep(Duration::from_millis(300)).await;
    fs::write(format!("{out}/client_events.csv"), run.logs.events.lock().unwrap().as_str())?;
    fs::write(format!("{out}/client_stats.csv"), run.logs.samples.lock().unwrap().as_str())?;
    fs::write(format!("{out}/client_rx.csv"), run.rx.lock().unwrap().as_str())?;
    fs::write(format!("{out}/client_probes.csv"), run.probes.lock().unwrap().as_str())?;
    fs::write(format!("{out}/marks.csv"), &ctl.marks)?;
    fs::write(
        format!("{out}/meta.txt"),
        format!("plan={plan}\ncfg={}\npps={pps}\nhold_scale={quick}\n", std::env::var("S5B_CFG").unwrap_or("-".into())),
    )?;
    run.conn.close(0u32.into(), b"done");
    run.ep.close().await;
    println!("wrote {out}");
    Ok(())
}

async fn run_punch(id: &str, relay: &str, out: &str, n: usize) -> Result<()> {
    let mut csv = String::from("trial,bind_to_online_ms,connect_ms,opened_direct_ms,selected_direct_ms,direct_addr\n");
    for i in 0..n {
        let run = client_connect(id, relay, 0, false).await?;
        let (mut send, _recv) = run.conn.open_bi().await?;
        let sel = wait_event(&run.logs, "selected", false, run.t_connect, Duration::from_secs(20)).await;
        let open = has_event(&run.logs, "client", "opened", false, run.t_connect);
        let addr = {
            let ev = run.logs.events.lock().unwrap();
            ev.lines().find(|l| l.contains(",selected,") && l.contains(",false,")).map(|l| l.split('"').nth(1).unwrap_or("").to_string()).unwrap_or_default()
        };
        let ms = |o: Option<f64>| o.map(|t| format!("{:.1}", (t - run.t_connect) * 1e3)).unwrap_or("never".into());
        let row = format!(
            "{i},{:.1},{:.1},{},{},\"{addr}\"",
            (run.t_online - run.t_bind) * 1e3,
            (run.t_connected - run.t_connect) * 1e3,
            ms(open),
            ms(sel)
        );
        println!("punch {row}");
        let _ = writeln!(csv, "{row}");
        let _ = send.write_all(b"bye\n").await;
        run.stop.store(true, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(200)).await;
        run.conn.close(0u32.into(), b"done");
        run.ep.close().await;
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    fs::write(format!("{out}/punch.csv"), csv)?;
    Ok(())
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("host") => run_host().await,
        Some("client") if args.len() >= 6 => {
            run_client(args[2].clone(), args[3].clone(), args[4].clone(), args[5].clone()).await
        }
        _ => {
            eprintln!("usage: s5b host | s5b client <endpoint-id> <relay-url> <out-dir> <full|soak:SECS|punch:N>");
            std::process::exit(2);
        }
    }
}
