#!/usr/bin/env python3
"""S11 far-end receiver, Python fallback for src/recv.zig (same wire format).

Timestamps each media packet (CLOCK_MONOTONIC, microseconds) and every 5 ms
sends the sender feedback: u8 2, u16 n, n x (u64 seq, i64 recv_us).
Usage: python3 recv.py [port] [punch_ip:port]   (default 9711). Ctrl-C to stop.
With punch_ip:port (both ends behind NAT), it sends a 1-byte hello there every
100 ms until media arrives, so its own NAT opens a mapping for the sender.
"""
import select, socket, struct, sys, time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9711
punch = None
if len(sys.argv) > 2:
    h, p = sys.argv[2].rsplit(":", 1)
    punch = (h, int(p))
last_hello = 0
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.bind(("0.0.0.0", port))
s.setblocking(False)
now = lambda: time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1000
pending, peer, last_fb, last_media, count = [], None, now(), 0, 0
print(f"recv: listening on udp {port}", flush=True)
while True:
    select.select([s], [], [], 0.001)
    while True:
        try:
            d, a = s.recvfrom(2048)
        except BlockingIOError:
            break
        t = now()
        if len(d) < 22 or d[0] != 1:
            continue
        if peer is None:
            print("recv: stream started", flush=True)
        peer, last_media = a, t
        count += 1
        pending.append((struct.unpack_from("<Q", d, 1)[0], t))
    t = now()
    if punch and peer is None and t - last_hello > 100_000:
        s.sendto(b"\x03", punch)
        last_hello = t
    if peer and t - last_media > 3_000_000:
        print(f"recv: stream ended after {count} packets", flush=True)
        peer, count = None, 0
        pending.clear()
    if pending and peer and t - last_fb >= 5000:
        pending.sort()
        for k in range(0, len(pending), 80):
            chunk = pending[k:k + 80]
            s.sendto(struct.pack("<BH", 2, len(chunk)) + b"".join(struct.pack("<Qq", q, r) for q, r in chunk), peer)
        pending.clear()
        last_fb = t
