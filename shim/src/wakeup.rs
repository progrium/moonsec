//! A pollable wakeup handle per connection.
//!
//! The shim makes the handle readable when something arrives for the caller (a datagram, a
//! path event, the connection closing), so a Zig network thread can sleep in poll/epoll/kqueue
//! (or WSAPoll on Windows) instead of spinning on non-blocking receives.
//!
//! - Unix: the read end of a non-blocking `socketpair(AF_UNIX, SOCK_STREAM)`, as an fd.
//! - Windows: a non-blocking UDP socket on 127.0.0.1 that receives from its twin, as a SOCKET.
//!
//! Edge-triggered with coalescing: the shim writes one byte only when the handle is not
//! already signaled. The caller calls `clear` (drains the bytes and re-arms), then drains the
//! queues with non-blocking calls. A signal that races with `clear` just causes one extra wake.

#[cfg(unix)]
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(unix)]
type Rx = std::os::unix::net::UnixStream;
#[cfg(unix)]
type Tx = std::os::unix::net::UnixStream;
#[cfg(windows)]
type Rx = std::net::UdpSocket;
#[cfg(windows)]
type Tx = std::net::UdpSocket;

pub struct Wakeup {
    rx: Rx,
    tx: Tx,
    signaled: AtomicBool,
}

impl Wakeup {
    #[cfg(unix)]
    pub fn new() -> std::io::Result<Self> {
        let (rx, tx) = std::os::unix::net::UnixStream::pair()?;
        rx.set_nonblocking(true)?;
        tx.set_nonblocking(true)?;
        Ok(Self { rx, tx, signaled: AtomicBool::new(false) })
    }

    #[cfg(windows)]
    pub fn new() -> std::io::Result<Self> {
        let rx = std::net::UdpSocket::bind("127.0.0.1:0")?;
        let tx = std::net::UdpSocket::bind("127.0.0.1:0")?;
        tx.connect(rx.local_addr()?)?;
        rx.connect(tx.local_addr()?)?;
        rx.set_nonblocking(true)?;
        tx.set_nonblocking(true)?;
        Ok(Self { rx, tx, signaled: AtomicBool::new(false) })
    }

    /// The pollable handle: an fd on Unix, a SOCKET on Windows.
    pub fn handle(&self) -> i64 {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            self.rx.as_raw_fd() as i64
        }
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawSocket;
            self.rx.as_raw_socket() as i64
        }
    }

    pub fn signal(&self) {
        if !self.signaled.swap(true, Ordering::AcqRel) {
            #[cfg(unix)]
            let _ = (&self.tx).write(&[1]);
            #[cfg(windows)]
            let _ = self.tx.send(&[1]);
        }
    }

    /// Drains pending wake bytes and re-arms. Call before draining the shim's queues.
    pub fn clear(&self) {
        self.signaled.store(false, Ordering::Release);
        let mut buf = [0u8; 64];
        loop {
            #[cfg(unix)]
            let r = (&self.rx).read(&mut buf);
            #[cfg(windows)]
            let r = self.rx.recv(&mut buf);
            match r {
                Ok(n) if n > 0 => continue,
                _ => break,
            }
        }
    }
}
