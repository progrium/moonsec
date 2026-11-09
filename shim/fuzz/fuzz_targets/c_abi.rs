//! The shim's C ABI driven the way the Zig side drives it (transport/iroh.zig), with
//! lengths, buffer sizes and arguments from the fuzzer:
//!
//! - datagrams of any length (0, over the maximum) sent, and received into buffers of any
//!   size (0, smaller than the datagram, null);
//! - `connect` with any ticket text and ALPN;
//! - bidirectional streams written and read through small buffers, finished, reset;
//! - every call again after the peer closed the connection;
//! - `bind` with any options (buffer sizes, timeouts, relay mode and URLs, bind address,
//!   relay CA PEM);
//! - the stats, event, ID and ticket calls with any buffer capacity.
//!
//! Each call must return one of the documented status codes, write only within the buffer
//! it was given, and never crash. Run under AddressSanitizer: see shim/fuzz/README.md.
#![no_main]

use std::ffi::{CStr, CString, c_char};
use std::ptr::{null, null_mut};
use std::sync::Mutex;

use arbitrary::Arbitrary;
use iroh_shim::*;
use libfuzzer_sys::fuzz_target;

const ALPN: &[u8] = b"moonsec/fuzz/0";
/// Every status code a call may return.
const CODES: [i32; 7] = [IROH_OK, IROH_ERR_AGAIN, IROH_ERR_CLOSED, IROH_ERR_INVALID, IROH_ERR_TIMEOUT, IROH_ERR_TOO_SMALL, IROH_ERR_INTERNAL];

#[derive(Arbitrary, Debug)]
enum Side {
    Dialer,
    Acceptor,
}

#[derive(Arbitrary, Debug)]
enum Op {
    Send { side: Side, len: u16, fill: u8 },
    SendNull { side: Side, len: u8 },
    Recv { side: Side, cap: u16, null_buf: bool, wait: bool },
    Connect { ticket: Vec<u8>, alpn: Vec<u8>, mutate_own: Option<(u16, u8)> },
    OpenWrite { side: Side, data: Vec<u8>, finish: bool },
    AcceptRead { side: Side, cap: u8, reads: u8 },
    ReadOpen { cap: u8 },
    FreeStream { code: u32 },
    PeerClose { side: Side, code: u32 },
    Rate { side: Side, bps: u64, burst_us: u32 },
    Stats { side: Side, path_cap: u8, null_out: bool },
    Events { side: Side, n: u8 },
    Ids { side: Side, cap: u8, null_buf: bool },
    NetworkChange,
    Bind(BindOpts),
}

#[derive(Arbitrary, Debug)]
struct BindOpts {
    secret_key: Option<[u8; 32]>,
    alpn: Option<Vec<u8>>,
    relay_mode: u8,
    relay_urls: Option<Vec<u8>>,
    bind_addr: Option<Vec<u8>>,
    datagram_send_buffer: u32,
    datagram_recv_buffer: u32,
    recv_queue_len: u16,
    path_idle_timeout_ms: u16,
    path_keepalive_ms: u16,
    conn_idle_timeout_ms: u16,
    initial_target_bps: u64,
    burst_us: u32,
    no_ack_progress_ms: u32,
    relay_ca_pem: Option<Vec<u8>>,
}

struct Pair {
    dialer_ep: *mut IrohEndpoint,
    acceptor_ep: *mut IrohEndpoint,
    dialer: *mut IrohConn,
    acceptor: *mut IrohConn,
    /// A stream the dialer opened, kept across ops so later reads and writes hit it.
    stream: *mut IrohStream,
    ticket: CString,
}

// The handles are only touched while holding the mutex below.
unsafe impl Send for Pair {}

static PAIR: Mutex<Option<Pair>> = Mutex::new(None);

fn check(code: i32, what: &str) -> i32 {
    assert!(CODES.contains(&code), "{what}: undocumented status {code}");
    if code != IROH_OK && code != IROH_ERR_AGAIN {
        // The error message must be a valid C string.
        let msg = unsafe { CStr::from_ptr(iroh_last_error()) };
        assert!(msg.to_bytes().len() < 64 << 10, "{what}: runaway error message");
    }
    code
}

fn loopback_opts() -> IrohBindOpts {
    let mut o: IrohBindOpts = unsafe { std::mem::zeroed() };
    o.alpn = ALPN.as_ptr();
    o.alpn_len = ALPN.len();
    o.relay_mode = IROH_RELAY_DISABLED;
    o.bind_addr = c"127.0.0.1:0".as_ptr();
    o
}

/// Two endpoints on loopback and a connection between them, made once and remade after a
/// test closes it.
fn connect_pair() -> Pair {
    unsafe {
        let mut a = null_mut();
        let mut b = null_mut();
        assert_eq!(iroh_endpoint_bind(&loopback_opts(), &mut a), IROH_OK);
        assert_eq!(iroh_endpoint_bind(&loopback_opts(), &mut b), IROH_OK);
        let mut buf = vec![0 as c_char; 4096];
        let mut n = 0usize;
        assert_eq!(iroh_endpoint_ticket(b, buf.as_mut_ptr(), buf.len(), &mut n), IROH_OK);
        let ticket = CStr::from_ptr(buf.as_ptr()).to_owned();
        let b_addr = b as usize;
        let accept = std::thread::spawn(move || {
            let mut c = null_mut();
            let r = iroh_endpoint_accept(b_addr as *const IrohEndpoint, 10_000, &mut c);
            (r, c as usize)
        });
        let mut d = null_mut();
        assert_eq!(iroh_endpoint_connect(a, ticket.as_ptr(), ALPN.as_ptr(), ALPN.len(), 10_000, &mut d), IROH_OK);
        let (r, c) = accept.join().unwrap();
        assert_eq!(r, IROH_OK);
        Pair { dialer_ep: a, acceptor_ep: b, dialer: d, acceptor: c as *mut IrohConn, stream: null_mut(), ticket }
    }
}

fn free_pair(p: Pair) {
    unsafe {
        if !p.stream.is_null() {
            iroh_stream_free(p.stream, 1);
        }
        iroh_conn_free(p.dialer, 0);
        iroh_conn_free(p.acceptor, 0);
        iroh_endpoint_free(p.dialer_ep);
        iroh_endpoint_free(p.acceptor_ep);
    }
}

fn conn(p: &Pair, side: &Side) -> *const IrohConn {
    match side {
        Side::Dialer => p.dialer,
        Side::Acceptor => p.acceptor,
    }
}

fn cstring(bytes: &[u8]) -> CString {
    CString::new(bytes.iter().copied().filter(|&b| b != 0).collect::<Vec<u8>>()).unwrap()
}

fn bind(o: &BindOpts) {
    let mut opts: IrohBindOpts = unsafe { std::mem::zeroed() };
    let urls = o.relay_urls.as_deref().map(cstring);
    let addr = o.bind_addr.as_deref().map(cstring);
    let pem = o.relay_ca_pem.as_deref().map(cstring);
    if let Some(k) = &o.secret_key {
        opts.secret_key = k.as_ptr();
    }
    if let Some(a) = &o.alpn {
        opts.alpn = a.as_ptr();
        opts.alpn_len = a.len();
    }
    // Never the default mode: it would reach the public relays and discovery.
    opts.relay_mode = match o.relay_mode % 4 {
        0 => IROH_RELAY_DISABLED,
        1 => IROH_RELAY_CUSTOM_ONLY,
        2 => 4 + o.relay_mode as u32, // invalid
        _ => IROH_RELAY_DISABLED,
    };
    opts.relay_urls = urls.as_ref().map_or(null(), |s| s.as_ptr());
    // Keep binds on loopback unless the address is garbage.
    opts.bind_addr = addr.as_ref().map_or(c"127.0.0.1:0".as_ptr(), |s| s.as_ptr());
    opts.datagram_send_buffer = o.datagram_send_buffer as usize;
    opts.datagram_recv_buffer = o.datagram_recv_buffer as usize;
    opts.recv_queue_len = o.recv_queue_len as u32;
    opts.path_idle_timeout_ms = o.path_idle_timeout_ms as u32;
    opts.path_keepalive_ms = o.path_keepalive_ms as u32;
    opts.conn_idle_timeout_ms = o.conn_idle_timeout_ms as u32;
    opts.initial_target_bps = o.initial_target_bps;
    opts.burst_us = o.burst_us;
    opts.no_ack_progress_ms = o.no_ack_progress_ms;
    opts.relay_ca_pem = pem.as_ref().map_or(null(), |s| s.as_ptr());
    let mut ep = null_mut();
    if check(unsafe { iroh_endpoint_bind(&opts, &mut ep) }, "bind") == IROH_OK {
        assert!(!ep.is_null());
        unsafe { iroh_endpoint_free(ep) };
    }
}

fn run(p: &mut Pair, op: &Op) -> bool {
    unsafe {
        match op {
            Op::Send { side, len, fill } => {
                let buf = vec![*fill; *len as usize];
                let max = iroh_conn_max_datagram_size(conn(p, side));
                let r = check(iroh_conn_send_datagram(conn(p, side), buf.as_ptr(), buf.len()), "send");
                if *len == 0 {
                    assert_eq!(r, IROH_ERR_INVALID);
                }
                if r == IROH_OK {
                    assert!(buf.len() <= max || max == 0);
                }
            }
            Op::SendNull { side, len } => {
                check(iroh_conn_send_datagram(conn(p, side), null(), *len as usize), "send null");
            }
            Op::Recv { side, cap, null_buf, wait } => {
                // One spare byte past the end, which must stay untouched.
                let mut buf = vec![0xa5u8; *cap as usize + 1];
                let mut n = usize::MAX;
                let ptr = if *null_buf { null_mut() } else { buf.as_mut_ptr() };
                let r = check(iroh_conn_recv_datagram(conn(p, side), ptr, *cap as usize, if *wait { 5 } else { 0 }, &mut n), "recv");
                if r == IROH_OK {
                    assert!(n <= *cap as usize);
                }
                assert_eq!(buf[*cap as usize], 0xa5, "recv wrote past the buffer");
            }
            Op::Connect { ticket, alpn, mutate_own } => {
                let t = match mutate_own {
                    // A near-miss of a real ticket: one byte changed.
                    Some((pos, byte)) => {
                        let mut b = p.ticket.as_bytes().to_vec();
                        if !b.is_empty() {
                            let i = *pos as usize % b.len();
                            b[i] = *byte;
                        }
                        cstring(&b)
                    }
                    None => cstring(ticket),
                };
                let mut c = null_mut();
                let r = check(iroh_endpoint_connect(p.dialer_ep, t.as_ptr(), alpn.as_ptr(), alpn.len(), 20, &mut c), "connect");
                if r == IROH_OK {
                    iroh_conn_free(c, 0);
                }
            }
            Op::OpenWrite { side, data, finish } => {
                let mut s = null_mut();
                if check(iroh_conn_open_bi(conn(p, side), 20, &mut s), "open_bi") != IROH_OK {
                    return true;
                }
                check(iroh_stream_write(s, data.as_ptr(), data.len(), 20), "write");
                if *finish {
                    check(iroh_stream_finish(s), "finish");
                    check(iroh_stream_finish(s), "finish twice");
                }
                if p.stream.is_null() {
                    p.stream = s;
                } else {
                    iroh_stream_free(s, 0);
                }
            }
            Op::AcceptRead { side, cap, reads } => {
                let mut s = null_mut();
                if check(iroh_conn_accept_bi(conn(p, side), 0, &mut s), "accept_bi") != IROH_OK {
                    return true;
                }
                for _ in 0..(*reads % 8) {
                    let mut buf = vec![0xa5u8; *cap as usize + 1];
                    let mut n = usize::MAX;
                    let r = check(iroh_stream_read(s, buf.as_mut_ptr(), *cap as usize, 0, &mut n), "read");
                    if r == IROH_OK {
                        assert!(n <= *cap as usize);
                    }
                    assert_eq!(buf[*cap as usize], 0xa5, "read wrote past the buffer");
                    if r != IROH_OK || n == 0 {
                        break;
                    }
                }
                iroh_stream_free(s, 0);
            }
            Op::ReadOpen { cap } => {
                if p.stream.is_null() {
                    return true;
                }
                let mut buf = vec![0xa5u8; *cap as usize + 1];
                let mut n = usize::MAX;
                let r = check(iroh_stream_read(p.stream, buf.as_mut_ptr(), *cap as usize, 0, &mut n), "read own");
                if *cap == 0 {
                    assert_eq!(r, IROH_ERR_INVALID);
                }
                assert_eq!(buf[*cap as usize], 0xa5, "read wrote past the buffer");
                check(iroh_stream_write(p.stream, buf.as_ptr(), *cap as usize, 0), "write own");
            }
            Op::FreeStream { code } => {
                if !p.stream.is_null() {
                    iroh_stream_free(p.stream, *code);
                    p.stream = null_mut();
                }
            }
            Op::PeerClose { side, code } => {
                // Close one end; the other must report CLOSED (or keep returning documented
                // codes) from here on. The pair is rebuilt for the next input.
                let (gone, other) = match side {
                    Side::Dialer => (p.dialer, p.acceptor),
                    Side::Acceptor => (p.acceptor, p.dialer),
                };
                if !p.stream.is_null() {
                    iroh_stream_free(p.stream, 0);
                    p.stream = null_mut();
                }
                iroh_conn_free(gone, *code);
                match side {
                    Side::Dialer => p.dialer = null_mut(),
                    Side::Acceptor => p.acceptor = null_mut(),
                }
                let mut buf = [0u8; 64];
                let mut n = 0usize;
                check(iroh_conn_send_datagram(other, buf.as_ptr(), 8), "send after close");
                check(iroh_conn_recv_datagram(other, buf.as_mut_ptr(), buf.len(), 50, &mut n), "recv after close");
                let mut s = null_mut();
                if check(iroh_conn_open_bi(other, 20, &mut s), "open after close") == IROH_OK {
                    check(iroh_stream_write(s, buf.as_ptr(), 8, 20), "write after close");
                    check(iroh_stream_finish(s), "finish after close");
                    check(iroh_stream_read(s, buf.as_mut_ptr(), buf.len(), 0, &mut n), "read after close");
                    iroh_stream_free(s, 3);
                }
                check(iroh_conn_set_target_bitrate(other, 1_000_000), "rate after close");
                let mut st: IrohConnStats = std::mem::zeroed();
                check(iroh_conn_stats(other, &mut st), "stats after close");
                let mut ev: IrohEvent = std::mem::zeroed();
                while check(iroh_conn_poll_event(other, &mut ev), "event after close") == IROH_OK {}
                return false;
            }
            Op::Rate { side, bps, burst_us } => {
                check(iroh_conn_set_target_bitrate(conn(p, side), *bps), "set_target_bitrate");
                check(iroh_conn_set_burst(conn(p, side), *burst_us), "set_burst");
            }
            Op::Stats { side, path_cap, null_out } => {
                let mut st: IrohConnStats = std::mem::zeroed();
                check(iroh_conn_stats(conn(p, side), if *null_out { null_mut() } else { &mut st }), "stats");
                let mut rows: Vec<IrohPathStats> = Vec::with_capacity(*path_cap as usize);
                let mut n = 0usize;
                let out = if *null_out { null_mut() } else { rows.as_mut_ptr() };
                check(iroh_conn_path_stats(conn(p, side), out, *path_cap as usize, &mut n), "path_stats");
                let _ = iroh_conn_local_drops(conn(p, side));
                iroh_conn_wakeup_clear(conn(p, side));
            }
            Op::Events { side, n } => {
                for _ in 0..*n {
                    let mut ev: IrohEvent = std::mem::zeroed();
                    if check(iroh_conn_poll_event(conn(p, side), &mut ev), "poll_event") != IROH_OK {
                        break;
                    }
                    assert!(ev.remote_addr.contains(&0), "event address not NUL-terminated");
                }
            }
            Op::Ids { side, cap, null_buf } => {
                let mut buf = vec![0x5a as c_char; *cap as usize + 1];
                let ptr = if *null_buf { null_mut() } else { buf.as_mut_ptr() };
                let mut n = 0usize;
                check(iroh_conn_remote_id(conn(p, side), ptr, *cap as usize), "remote_id");
                check(iroh_endpoint_id(p.dialer_ep, ptr, *cap as usize), "endpoint_id");
                let r = check(iroh_endpoint_ticket(p.acceptor_ep, ptr, *cap as usize, &mut n), "ticket");
                if r == IROH_OK {
                    assert!(n < *cap as usize);
                }
                assert_eq!(buf[*cap as usize], 0x5a, "wrote past the buffer");
            }
            Op::NetworkChange => {
                check(iroh_endpoint_network_change(p.dialer_ep), "network_change");
            }
            Op::Bind(o) => bind(o),
        }
    }
    true
}

fuzz_target!(|ops: Vec<Op>| {
    let mut guard = PAIR.lock().unwrap();
    for op in ops.iter().take(32) {
        if guard.is_none() {
            *guard = Some(connect_pair());
        }
        let p = guard.as_mut().unwrap();
        if !run(p, op) {
            let p = guard.take().unwrap();
            free_pair(p);
        }
    }
    // Leave no stray datagrams or streams for the next input.
    if let Some(p) = guard.as_mut() {
        let mut buf = vec![0u8; 2048];
        let mut n = 0usize;
        unsafe {
            for c in [p.dialer, p.acceptor] {
                while iroh_conn_recv_datagram(c, buf.as_mut_ptr(), buf.len(), 0, &mut n) == IROH_OK {}
            }
            if !p.stream.is_null() {
                iroh_stream_free(p.stream, 1);
                p.stream = null_mut();
            }
        }
    }
});
