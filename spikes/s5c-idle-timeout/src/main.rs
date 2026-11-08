//! Spike S5c: the per-path idle timeout decision (300 ms vs ~1 s), in a lab.
//!
//! S5b's host/client harness, moved into network namespaces so that RTT can be set
//! (the S5b VM had no netem, and neither does this kernel). One binary, four roles:
//!
//!   relay     a local iroh relay (HTTPS + QUIC address discovery, self-signed cert),
//!             standing in for the n0 relays. Runs in the "internet" namespace.
//!   delayline a userspace L2 delay line between two interfaces (AF_PACKET), standing in
//!             for netem. Transparent, so NATs and hole punching see real traffic.
//!   host      as S5b: one endpoint per transport config on fixed ports, streams media,
//!             echoes probes, blacks out its own direct UDP port with iptables on request.
//!   client    as S5b: dials by key + relay URL only, runs a plan, records everything.
//!
//! Plans: `sweep` (one hard block, then every blackout length in S5C_BLACKOUTS, S5C_REPS
//! times, each started from a settled direct path) and `punch:N`.

use std::{
    fmt::Write as _,
    fs,
    net::SocketAddr,
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
    Endpoint, EndpointAddr, RelayConfig, RelayMap, RelayMode, RelayUrl,
    endpoint::{Connection, PathEvent, QuicTransportConfig, presets},
};
use iroh_relay::{
    RelayQuicConfig,
    server::{CertConfig, QuicConfig, RelayConfig as RelayServerConfig, Server, ServerConfig, TlsConfig},
    tls::CaTlsConfig,
};
use tokio::io::AsyncBufReadExt;
use tokio_stream::StreamExt;

const ALPN: &[u8] = b"moonsec/s5c";
const PKT: usize = 1150;
const QAD_PORT: u16 = 7842;

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
        l.samples.lock().unwrap().push_str("t,id,relay,selected,rtt_us,sent,lost,cwnd\n");
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
                    format!("rtt={:?} sent={} lost={}", last_stats.rtt, last_stats.sent_packets, last_stats.lost_packets),
                ),
                PathEvent::Lagged { missed, .. } => ("lagged", String::new(), false, String::new(), format!("missed={missed}")),
                other => ("other", String::new(), false, String::new(), format!("{other:?}")),
            };
            if verbose {
                println!("[{t:.3}] {side:<6} {kind:<8} {id} relay={relay} {addr} {extra}");
            }
            let _ = writeln!(logs.events.lock().unwrap(), "{t:.6},{side},{kind},{id},{relay},\"{addr}\",\"{extra}\"");
        }
    });
}

fn sample_stats(conn: Connection, logs: Arc<Logs>, stop: Arc<AtomicBool>, every: Duration) {
    std::thread::spawn(move || {
        let mut buf = String::new();
        while !stop.load(Ordering::Relaxed) {
            let t = now();
            for p in conn.paths().iter() {
                let s = p.stats();
                let _ = writeln!(
                    buf,
                    "{t:.6},{:?},{},{},{},{},{},{}",
                    p.id(),
                    p.is_relay(),
                    p.is_selected(),
                    s.rtt.as_micros(),
                    s.sent_packets,
                    s.lost_packets,
                    s.cwnd
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

fn parse_cfg(s: &str) -> Result<(Option<u64>, Option<u64>)> {
    if s == "-" || s == "default" {
        return Ok((None, None));
    }
    let (a, b) = s.split_once(':').context("cfg is idle_ms:keepalive_ms or -")?;
    Ok((Some(a.parse()?), Some(b.parse()?)))
}

/// The lab relay: S5C_RELAY=https://10.80.9.1:3443 (QAD on 7842 of the same host).
fn relay_url() -> Result<RelayUrl> {
    Ok(std::env::var("S5C_RELAY").unwrap_or("https://10.80.9.1:3443".into()).parse()?)
}

fn builder(idle: Option<u64>, ka: Option<u64>) -> Result<iroh::endpoint::Builder> {
    let url = relay_url()?;
    let map: RelayMap = RelayConfig::new(url, Some(RelayQuicConfig::new(QAD_PORT))).into();
    Ok(Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Custom(map))
        .ca_tls_config(CaTlsConfig::insecure_skip_verify())
        .alpns(vec![ALPN.to_vec()])
        .transport_config(transport_config(idle, ka)))
}

// ---------------------------------------------------------------- relay

async fn run_relay(bind: &str) -> Result<()> {
    let ip: std::net::IpAddr = bind.parse()?;
    let (_certs, server_config) = iroh_relay::server::testing::self_signed_tls_certs_and_config();
    let tls = TlsConfig::new(SocketAddr::new(ip, 3443), CertConfig::Manual { server_config });
    let mut relay = RelayServerConfig::new(SocketAddr::new(ip, 3340));
    relay.tls = Some(tls);
    relay.key_cache_capacity = Some(1024);
    let mut config = ServerConfig::default();
    config.relay = Some(relay);
    config.quic = Some(QuicConfig::new(SocketAddr::new(ip, QAD_PORT)));
    let server = Server::spawn(config).await?;
    println!("relay https={:?} quic={:?}", server.https_addr(), server.quic_addr());
    tokio::signal::ctrl_c().await?;
    server.shutdown().await.ok();
    Ok(())
}

// ---------------------------------------------------------------- delay line

/// Transparent L2 delay line: every frame read on one interface is written to the other
/// `oneway_us` later. Both directions. No loss of its own (big buffers, no queue limit).
fn run_delayline(ifa: &str, ifb: &str, oneway_us: u64) -> Result<()> {
    use std::collections::VecDeque;
    unsafe fn open(ifname: &str) -> Result<i32> {
        unsafe {
            let proto = (libc::ETH_P_ALL as u16).to_be() as i32;
            let fd = libc::socket(libc::AF_PACKET, libc::SOCK_RAW | libc::SOCK_NONBLOCK, proto);
            if fd < 0 {
                bail!("socket: {}", std::io::Error::last_os_error());
            }
            let name = std::ffi::CString::new(ifname)?;
            let idx = libc::if_nametoindex(name.as_ptr());
            if idx == 0 {
                bail!("no interface {ifname}");
            }
            let mut sll: libc::sockaddr_ll = std::mem::zeroed();
            sll.sll_family = libc::AF_PACKET as u16;
            sll.sll_protocol = proto as u16;
            sll.sll_ifindex = idx as i32;
            if libc::bind(fd, &sll as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_ll>() as u32) < 0 {
                bail!("bind {ifname}: {}", std::io::Error::last_os_error());
            }
            let one: i32 = 1;
            // PACKET_IGNORE_OUTGOING: don't read back what we write.
            libc::setsockopt(fd, libc::SOL_PACKET, 23, &one as *const _ as *const libc::c_void, 4);
            let big: i32 = 16 << 20;
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_RCVBUFFORCE, &big as *const _ as *const libc::c_void, 4);
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_SNDBUFFORCE, &big as *const _ as *const libc::c_void, 4);
            Ok(fd)
        }
    }
    fn mono_ns() -> u64 {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
        ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
    }
    let fds = unsafe { [open(ifa)?, open(ifb)?] };
    let delay = oneway_us * 1000;
    // queues[i]: frames read on fds[i], to be written to fds[1-i]
    let mut queues: [VecDeque<(u64, Vec<u8>)>; 2] = [VecDeque::new(), VecDeque::new()];
    let mut buf = vec![0u8; 65536];
    let (mut fwd, mut errs) = (0u64, 0u64);
    let mut last_report = mono_ns();
    println!("delayline {ifa} <-> {ifb}, one-way {} ms", oneway_us as f64 / 1000.0);
    loop {
        let t = mono_ns();
        for i in 0..2 {
            while let Some((due, _)) = queues[i].front() {
                if *due > t {
                    break;
                }
                let (_, f) = queues[i].pop_front().unwrap();
                let r = unsafe { libc::send(fds[1 - i], f.as_ptr() as *const libc::c_void, f.len(), 0) };
                if r < 0 { errs += 1 } else { fwd += 1 }
            }
        }
        if t - last_report > 10_000_000_000 {
            println!("delayline fwd={fwd} send_errs={errs} queued={}/{}", queues[0].len(), queues[1].len());
            last_report = t;
        }
        let next = queues.iter().filter_map(|q| q.front().map(|x| x.0)).min();
        let mut pfds = [
            libc::pollfd { fd: fds[0], events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: fds[1], events: libc::POLLIN, revents: 0 },
        ];
        let wait = next.map(|n| n.saturating_sub(mono_ns())).unwrap_or(100_000_000);
        let ts = libc::timespec { tv_sec: (wait / 1_000_000_000) as i64, tv_nsec: (wait % 1_000_000_000) as i64 };
        unsafe { libc::ppoll(pfds.as_mut_ptr(), 2, &ts, std::ptr::null()) };
        for i in 0..2 {
            if pfds[i].revents & libc::POLLIN == 0 {
                continue;
            }
            loop {
                let n = unsafe { libc::recv(fds[i], buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };
                if n <= 0 {
                    break;
                }
                queues[i].push_back((mono_ns() + delay, buf[..n as usize].to_vec()));
            }
        }
    }
}

// ---------------------------------------------------------------- host impairments

fn sh(cmd: &str, args: &[&str]) -> Result<()> {
    let st = Command::new(cmd).args(args).stderr(Stdio::null()).status().with_context(|| format!("run {cmd}"))?;
    if !st.success() {
        bail!("{cmd} {} failed", args.join(" "));
    }
    Ok(())
}

/// Drops the host's direct-path UDP for one port, both ways (as S5b). Relay traffic is TCP
/// and QAD goes to another port on the relay, so only paths through this socket die...
/// except QAD from this socket, which also stops, as it would in a real outage.
struct Firewall {
    port: u16,
}

impl Firewall {
    fn chains(&self) -> (String, String) {
        (format!("S5C_{}_IN", self.port), format!("S5C_{}_OUT", self.port))
    }
    fn setup(port: u16) -> Result<Self> {
        let fw = Firewall { port };
        fw.teardown();
        let (cin, cout) = fw.chains();
        let p = port.to_string();
        sh("iptables", &["-N", &cin])?;
        sh("iptables", &["-N", &cout])?;
        sh("iptables", &["-I", "INPUT", "-p", "udp", "--dport", &p, "-j", &cin])?;
        sh("iptables", &["-I", "OUTPUT", "-p", "udp", "--sport", &p, "-j", &cout])?;
        Ok(fw)
    }
    fn set(&self, blocked: bool) -> Result<()> {
        let (cin, cout) = self.chains();
        sh("iptables", &["-F", &cin])?;
        sh("iptables", &["-F", &cout])?;
        if blocked {
            sh("iptables", &["-A", &cin, "-j", "DROP"])?;
            sh("iptables", &["-A", &cout, "-j", "DROP"])?;
        }
        Ok(())
    }
    fn teardown(&self) {
        let (cin, cout) = self.chains();
        let p = self.port.to_string();
        while sh("iptables", &["-D", "INPUT", "-p", "udp", "--dport", &p, "-j", &cin]).is_ok() {}
        while sh("iptables", &["-D", "OUTPUT", "-p", "udp", "--sport", &p, "-j", &cout]).is_ok() {}
        for c in [&cin, &cout] {
            let _ = sh("iptables", &["-F", c]);
            let _ = sh("iptables", &["-X", c]);
        }
    }
}

// ---------------------------------------------------------------- host

async fn run_host() -> Result<()> {
    let base: u16 = std::env::var("S5C_BASE_PORT").ok().and_then(|s| s.parse().ok()).unwrap_or(47001);
    let cfgs = std::env::var("S5C_CONFIGS").unwrap_or_else(|_| "idle300=300:100,idle1000=1000:200".into());
    let id_file = std::env::var("S5C_ID_FILE").ok();
    let mut ids = String::new();
    let mut fws = vec![];
    for (i, c) in cfgs.split(',').enumerate() {
        let (name, cfg) = c.split_once('=').context("S5C_CONFIGS entries are name=idle:keepalive")?;
        let (idle, ka) = parse_cfg(cfg)?;
        let port = base + i as u16;
        let fw = Arc::new(Firewall::setup(port)?);
        fws.push(fw.clone());
        let ep = builder(idle, ka)?
            .clear_ip_transports()
            .bind_addr(format!("0.0.0.0:{port}").as_str())?
            .bind()
            .await?;
        ep.online().await;
        println!("CONFIG {name} port={port} id={} addrs={:?}", ep.id(), ep.addr().addrs);
        let _ = writeln!(ids, "{name} {} {cfg}", ep.id());
        let name = name.to_string();
        tokio::spawn(async move {
            while let Some(inc) = ep.accept().await {
                let fw = fw.clone();
                let name = name.clone();
                tokio::spawn(async move {
                    match inc.await {
                        Ok(conn) => {
                            println!("[{:.3}] {name}: connection from {}", now(), conn.remote_id());
                            if let Err(e) = host_session(conn, &fw).await {
                                println!("[{:.3}] {name}: session ended: {e:#}", now());
                            }
                            let _ = fw.set(false);
                        }
                        Err(e) => println!("accept failed: {e:#}"),
                    }
                });
            }
        });
    }
    if let Some(f) = id_file {
        fs::write(f, &ids)?;
    }
    tokio::signal::ctrl_c().await?;
    for fw in &fws {
        fw.teardown();
    }
    Ok(())
}

async fn host_session(conn: Connection, fw: &Firewall) -> Result<()> {
    let logs = Logs::new();
    let stop = Arc::new(AtomicBool::new(false));
    watch_events("host", &conn, logs.clone(), false);
    let pps = Arc::new(AtomicU64::new(0));
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
    let mut sampling = false;
    while let Some(line) = lines.next_line().await? {
        let toks: Vec<&str> = line.split_whitespace().collect();
        let arg = |i: usize| toks.get(i).and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
        let mut res = Ok(());
        let mut t_apply = now();
        match toks.first().copied().unwrap_or("") {
            "sample" if !sampling => {
                sampling = true;
                sample_stats(conn.clone(), logs.clone(), stop.clone(), Duration::from_millis(arg(1).max(1.0) as u64));
            }
            "media" => pps.store(arg(1) as u64, Ordering::Relaxed),
            "block" => {
                res = fw.set(true);
                t_apply = now();
            }
            "unblock" => {
                res = fw.set(false);
                t_apply = now();
            }
            "blackout" => {
                let ms = arg(1);
                res = fw.set(true);
                t_apply = now();
                tokio::time::sleep_until(tokio::time::Instant::now() + Duration::from_secs_f64(ms / 1000.0)).await;
                res = res.and(fw.set(false));
            }
            "logs" => {
                stop.store(true, Ordering::Relaxed);
                pps.store(0, Ordering::Relaxed);
                tokio::time::sleep(Duration::from_millis(50)).await;
                let blob = format!(
                    "=== host_events.csv\n{}=== host_stats.csv\n{}",
                    logs.events.lock().unwrap(),
                    logs.samples.lock().unwrap(),
                );
                send.write_all(format!("LOGS {}\n", blob.len()).as_bytes()).await?;
                send.write_all(blob.as_bytes()).await?;
                continue;
            }
            "bye" => break,
            _ => {}
        }
        let t_done = now();
        let c = toks.first().unwrap_or(&"");
        match res {
            Ok(()) => send.write_all(format!("ok {c} {t_apply:.6} {t_done:.6}\n").as_bytes()).await?,
            Err(e) => send.write_all(format!("err {c} {t_apply:.6} {t_done:.6} {e:#}\n").as_bytes()).await?,
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
    /// Sends a command; records client send time and the host's apply and done times
    /// (host clock; all namespaces share one clock here).
    async fn cmd(&mut self, c: &str) -> Result<(f64, f64)> {
        let t_send = now();
        println!("[{t_send:.3}] >> {c}");
        self.send.write_all(format!("{c}\n").as_bytes()).await?;
        let name = c.split_whitespace().next().unwrap_or("");
        let toks = loop {
            let reply = self.lines.next_line().await?.context("control closed")?;
            let toks: Vec<String> = reply.split_whitespace().map(String::from).collect();
            if toks.get(1).map(|s| s.as_str()) == Some(name) {
                if toks[0] != "ok" {
                    println!("   !! {reply}");
                }
                break toks;
            }
        };
        let p = |i: usize| toks.get(i).and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
        let (ta, td) = (p(2), p(3));
        let _ = writeln!(self.marks, "{},{t_send:.6},{ta:.6},{td:.6}", c.replace(' ', "_"));
        Ok((ta, td))
    }
}

struct ClientRun {
    conn: Connection,
    ep: Endpoint,
    logs: Arc<Logs>,
    stop: Arc<AtomicBool>,
    rx: Arc<Mutex<String>>,
    probes: Arc<Mutex<String>>,
    t_connect: f64,
}

async fn client_connect(id: &str, sample_ms: u64, record: bool) -> Result<ClientRun> {
    let (idle, ka) = parse_cfg(&std::env::var("S5C_CFG").unwrap_or("-".into()))?;
    let ep = builder(idle, ka)?.bind().await?;
    ep.online().await;
    let addr = EndpointAddr::new(id.parse()?).with_relay_url(relay_url()?);
    let logs = Logs::new();
    let t_connect = now();
    let conn = ep.connect(addr, ALPN).await?;
    watch_events("client", &conn, logs.clone(), std::env::var("S5C_VERBOSE").is_ok());
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
    Ok(ClientRun { conn, ep, logs, stop, rx, probes, t_connect })
}

fn has_event(logs: &Logs, kind: &str, relay: bool, after: f64) -> Option<f64> {
    let ev = logs.events.lock().unwrap();
    ev.lines().skip(1).find_map(|l| {
        let f: Vec<&str> = l.splitn(6, ',').collect();
        let t: f64 = f[0].parse().ok()?;
        (t >= after && f[1] == "client" && f[2] == kind && f[4] == relay.to_string()).then_some(t)
    })
}

async fn wait_event(logs: &Logs, kind: &str, relay: bool, after: f64, max: Duration) -> Option<f64> {
    let deadline = Instant::now() + max;
    loop {
        if let Some(t) = has_event(logs, kind, relay, after) {
            return Some(t);
        }
        if Instant::now() > deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

fn on_direct(conn: &Connection) -> bool {
    conn.paths().iter().any(|p| p.is_selected() && !p.is_relay())
}

async fn back_to_direct(conn: &Connection, max: Duration) -> bool {
    let deadline = Instant::now() + max;
    while Instant::now() < deadline {
        if on_direct(conn) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    println!("   !! not back on direct after {max:?}");
    false
}

async fn hold(s: f64) {
    tokio::time::sleep(Duration::from_secs_f64(s)).await;
}

fn env_f(k: &str, d: f64) -> f64 {
    std::env::var(k).ok().and_then(|s| s.parse().ok()).unwrap_or(d)
}

async fn run_client(id: String, out: String, plan: String) -> Result<()> {
    fs::create_dir_all(&out)?;
    let (plan_name, plan_arg) = plan.split_once(':').unwrap_or((plan.as_str(), ""));
    if plan_name == "punch" {
        return run_punch(&id, &out, plan_arg.parse().unwrap_or(10)).await;
    }
    let pps = env_f("S5C_PPS", 200.0) as u64;
    let reps = env_f("S5C_REPS", 3.0) as usize;
    let max_wait = Duration::from_secs_f64(env_f("S5C_MAX_WAIT", 75.0));
    let blackouts: Vec<u64> = std::env::var("S5C_BLACKOUTS")
        .unwrap_or("100,200,300,400,600,800,1000,1500".into())
        .split(',')
        .map(|s| s.parse().unwrap())
        .collect();

    let run = client_connect(&id, 2, true).await?;
    let (send, recv) = run.conn.open_bi().await?;
    let mut ctl = Ctl { send, lines: tokio::io::BufReader::new(recv).lines(), marks: String::from("cmd,t_send,host_apply,host_done\n") };
    ctl.cmd("sample 2").await?;
    ctl.cmd(&format!("media {pps}")).await?;
    let first_direct = wait_event(&run.logs, "selected", false, run.t_connect, Duration::from_secs(30)).await;
    println!("time to direct: {:?} ms", first_direct.map(|t| (t - run.t_connect) * 1e3));
    let mut bo = String::from("idx,rep,ms,direct_before,t_on,t_off\n");
    if plan_name == "sweep" {
        hold(5.0).await;
        // One hard block: detection time and time back to direct after it is lifted.
        back_to_direct(&run.conn, max_wait).await;
        let (t, _) = ctl.cmd("block").await?;
        let r = wait_event(&run.logs, "selected", true, t, Duration::from_secs(40)).await;
        println!("block -> relay: {:?} ms", r.map(|x| (x - t) * 1e3));
        hold(3.0).await;
        let (t, _) = ctl.cmd("unblock").await?;
        let d = wait_event(&run.logs, "selected", false, t, max_wait).await;
        println!("unblock -> direct: {:?} ms", d.map(|x| (x - t) * 1e3));
        let mut idx = 0;
        for rep in 0..reps {
            for &ms in &blackouts {
                let ok = back_to_direct(&run.conn, max_wait).await;
                hold(3.0).await;
                let direct = ok && on_direct(&run.conn);
                let (ta, td) = ctl.cmd(&format!("blackout {ms}")).await?;
                let _ = writeln!(bo, "{idx},{rep},{ms},{direct},{ta:.6},{td:.6}");
                idx += 1;
                hold(2.0).await;
            }
        }
        back_to_direct(&run.conn, max_wait).await;
        hold(2.0).await;
    } else {
        bail!("unknown plan {plan_name}");
    }

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
    fs::write(format!("{out}/blackouts.csv"), &bo)?;
    fs::write(
        format!("{out}/meta.txt"),
        format!(
            "plan={plan}\ncfg={}\npps={pps}\nt_connect={:.6}\nfirst_direct={}\n",
            std::env::var("S5C_CFG").unwrap_or("-".into()),
            run.t_connect,
            first_direct.map(|t| format!("{t:.6}")).unwrap_or_default()
        ),
    )?;
    run.conn.close(0u32.into(), b"done");
    run.ep.close().await;
    println!("wrote {out}");
    Ok(())
}

async fn run_punch(id: &str, out: &str, n: usize) -> Result<()> {
    let mut csv = String::from("trial,selected_direct_ms\n");
    for i in 0..n {
        let run = client_connect(id, 0, false).await?;
        let (mut send, _recv) = run.conn.open_bi().await?;
        let sel = wait_event(&run.logs, "selected", false, run.t_connect, Duration::from_secs(20)).await;
        let ms = sel.map(|t| format!("{:.1}", (t - run.t_connect) * 1e3)).unwrap_or("never".into());
        println!("punch {i} {ms}");
        let _ = writeln!(csv, "{i},{ms}");
        let _ = send.write_all(b"bye\n").await;
        run.stop.store(true, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(200)).await;
        run.conn.close(0u32.into(), b"done");
        run.ep.close().await;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    fs::write(format!("{out}/punch.csv"), csv)?;
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) == Some("delayline") && args.len() >= 5 {
        return run_delayline(&args[2], &args[3], (args[4].parse::<f64>()? * 1000.0) as u64);
    }
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?;
    rt.block_on(async {
        match args.get(1).map(|s| s.as_str()) {
            Some("relay") => run_relay(args.get(2).map(|s| s.as_str()).unwrap_or("0.0.0.0")).await,
            Some("host") => run_host().await,
            Some("client") if args.len() >= 5 => run_client(args[2].clone(), args[3].clone(), args[4].clone()).await,
            _ => {
                eprintln!(
                    "usage: s5c relay [ip] | s5c delayline <if_a> <if_b> <oneway_ms> | s5c host | s5c client <endpoint-id> <out-dir> <sweep|punch:N>"
                );
                std::process::exit(2);
            }
        }
    })
}
