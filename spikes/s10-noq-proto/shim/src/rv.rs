//! iroh as the rendezvous for a noq-proto media connection on a separate, Zig-owned socket.
//!
//! iroh dials by key (direct or relayed), authenticates both ends, and carries one control
//! stream. Over it each side sends: its media socket's local candidates, its media port, and
//! (host only) the media server certificate to pin. Each side adds one more candidate for the
//! peer: the IP iroh sees the peer at, with the peer's media port (a port-preservation guess,
//! which is what endpoint-independent home NATs and Linux MASQUERADE do). The Zig side then
//! punches from its media socket and noq-proto connects over whichever candidate answers.
//!
//! This runs once, at session setup, on a throwaway current-thread runtime. Media never
//! touches tokio.

use std::{ffi::CStr, net::SocketAddr, os::raw::c_char};

use iroh::{Endpoint, EndpointAddr, RelayMode, SecretKey, TransportAddr, endpoint::presets};

use crate::NqAddr;

const ALPN: &[u8] = b"moonsec/s10-rv/0";

struct Msg {
    cert: Vec<u8>,
    port: u16,
    cands: Vec<SocketAddr>,
}

fn encode(m: &Msg) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(&(m.cert.len() as u32).to_le_bytes());
    v.extend_from_slice(&m.cert);
    v.extend_from_slice(&m.port.to_le_bytes());
    v.extend_from_slice(&(m.cands.len() as u32).to_le_bytes());
    for c in &m.cands {
        let s = c.to_string();
        v.push(s.len() as u8);
        v.extend_from_slice(s.as_bytes());
    }
    v
}

fn decode(b: &[u8]) -> Option<Msg> {
    let mut i = 0;
    let rd32 = |b: &[u8], i: &mut usize| -> Option<u32> {
        let v = u32::from_le_bytes(b.get(*i..*i + 4)?.try_into().ok()?);
        *i += 4;
        Some(v)
    };
    let cl = rd32(b, &mut i)? as usize;
    let cert = b.get(i..i + cl)?.to_vec();
    i += cl;
    let port = u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?);
    i += 2;
    let n = rd32(b, &mut i)?;
    let mut cands = Vec::new();
    for _ in 0..n {
        let l = *b.get(i)? as usize;
        i += 1;
        cands.push(std::str::from_utf8(b.get(i..i + l)?).ok()?.parse().ok()?);
        i += l;
    }
    Some(Msg { cert, port, cands })
}

fn cstr(p: *const c_char) -> String {
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

async fn endpoint(seed: u8, bind: SocketAddr) -> anyhow::Result<Endpoint> {
    Ok(Endpoint::builder(presets::Minimal)
        .secret_key(SecretKey::from_bytes(&[seed; 32]))
        .relay_mode(RelayMode::Disabled)
        .clear_ip_transports()
        .bind_addr(bind)?
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await?)
}

fn peer_ip(conn: &iroh::endpoint::Connection) -> Option<std::net::IpAddr> {
    conn.paths().iter().find_map(|p| match p.remote_addr() {
        TransportAddr::Ip(a) => Some(a.ip()),
        _ => None,
    })
}

struct RvOut {
    cands: Vec<SocketAddr>,
    cert: Vec<u8>,
    held: (Endpoint, iroh::endpoint::Connection),
}

async fn run(host: bool, bind: SocketAddr, peer: Option<SocketAddr>, mine: Msg) -> anyhow::Result<RvOut> {
    let ep = endpoint(if host { 41 } else { 42 }, bind).await?;
    let conn = if host {
        ep.accept().await.ok_or_else(|| anyhow::anyhow!("no incoming"))?.await?
    } else {
        let addr = EndpointAddr::from_parts(SecretKey::from_bytes(&[41; 32]).public(), [TransportAddr::Ip(peer.unwrap())]);
        ep.connect(addr, ALPN).await?
    };
    let (mut tx, mut rx) = if host { conn.accept_bi().await? } else { conn.open_bi().await? };
    let out = encode(&mine);
    tx.write_all(&(out.len() as u32).to_le_bytes()).await?;
    tx.write_all(&out).await?;
    let mut lb = [0u8; 4];
    rx.read_exact(&mut lb).await?;
    let mut b = vec![0u8; u32::from_le_bytes(lb) as usize];
    rx.read_exact(&mut b).await?;
    let theirs = decode(&b).ok_or_else(|| anyhow::anyhow!("bad rendezvous message"))?;
    let mut cands = theirs.cands.clone();
    if let Some(ip) = peer_ip(&conn) {
        let guess = SocketAddr::new(ip, theirs.port);
        if !cands.contains(&guess) {
            cands.insert(0, guess);
        }
    }
    Ok(RvOut { cands, cert: theirs.cert, held: (ep, conn) })
}

/// Blocking rendezvous. Host: `peer` is NULL; it accepts. Client: `peer` is the host's iroh
/// address. Fills `out` with the peer's media candidates and (client) `cert_out` with the
/// pinned media certificate. Returns the number of candidates, or <0 on error.
/// The iroh endpoint and connection are kept alive (leaked) as the session's control channel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nq_rv(
    host: i32,
    iroh_bind: *const c_char,
    peer: *const c_char,
    media_port: u16,
    my_cands: *const NqAddr,
    n_my: usize,
    cert: *const u8,
    cert_len: usize,
    out: *mut NqAddr,
    cap: usize,
    cert_out: *mut u8,
    cert_cap: usize,
    cert_out_len: *mut usize,
) -> i32 {
    let bind: SocketAddr = match cstr(iroh_bind).parse() {
        Ok(a) => a,
        Err(_) => return -1,
    };
    let peer = if peer.is_null() { None } else { cstr(peer).parse().ok() };
    let mine = Msg {
        cert: if cert.is_null() { vec![] } else { unsafe { std::slice::from_raw_parts(cert, cert_len) }.to_vec() },
        port: media_port,
        cands: (0..n_my).map(|i| unsafe { *my_cands.add(i) }.to_std()).collect(),
    };
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let r = rt.block_on(run(host != 0, bind, peer, mine));
    match r {
        Ok(o) => {
            let n = o.cands.len().min(cap);
            for (i, c) in o.cands.iter().take(n).enumerate() {
                unsafe { *out.add(i) = NqAddr::from_std(*c) };
            }
            if !cert_out.is_null() && o.cert.len() <= cert_cap {
                unsafe {
                    std::ptr::copy_nonoverlapping(o.cert.as_ptr(), cert_out, o.cert.len());
                    *cert_out_len = o.cert.len();
                }
            }
            // keep the control channel (and its runtime) alive for the session
            let th = std::thread::spawn(move || {
                let held = o.held;
                rt.block_on(async move {
                    let _ = held.1.closed().await;
                    drop(held);
                });
            });
            std::mem::forget(th);
            n as i32
        }
        Err(e) => {
            eprintln!("rendezvous failed: {e:#}");
            -2
        }
    }
}
