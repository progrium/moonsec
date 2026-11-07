# Spike S10: media datagrams over noq-proto, driven from Zig

**Question.** Should media leave iroh and run over `noq-proto` (the sans-I/O QUIC state machine under iroh), with the Zig core owning the socket, timers, pacing and drop accounting, while iroh keeps identity, dialing and hole punching? This is the design doc's original "fallback 1".
**Compared against.** The current plan: iroh 1.4.1 with S3's `AppRate` controller, on S4's dedicated current-thread runtime pinned to a SCHED_FIFO thread. That configuration had never been measured under S2's bottleneck, so this spike measured it too.

## Verdict

**Keep iroh for media. Don't switch.** noq-proto driven from Zig is measurably better on every axis this spike tested, but the gains are about a millisecond. They don't pay for owning a second NAT traversal path.

| | iroh + `AppRate`, pinned runtime | noq-proto, Zig owns socket and pacer |
| --- | --- | --- |
| S2: added p99 over raw UDP, 60 fps frames below the cap (median of 8 cases) | 2.2 ms (max 2.5): **fails** the 2 ms bar | 1.3 ms (max 1.8); **0.6 ms** (max 0.6) with one frame of pacer credit |
| S2: added p99, smooth traffic below the cap | 0.25 ms median; single stalls push one run to 12.4 ms | 0.2 ms median; single stalls push one run to 15.4 ms (both: host scheduling, see below) |
| S2: hidden queue at or above the cap | None | None |
| S2: every drop visible | Only bottleneck drops. Send-buffer evictions are still uncounted, and with the design's 64 KiB buffer they drop **60% of a frame stream at 85% load** | **Yes, in every run**: each datagram is either counted by Zig's queue or by QUIC loss, matching the TBF exactly |
| S4: hand-off p99 (media thread → `sendto`) | 102–398 µs (S4) | 62–202 µs with a network thread; **11–30 µs** when the media thread drives QUIC itself |
| Sharing iroh's path | n/a | **Not possible without forking iroh.** A second socket can punch on its own (demo below), but only through port-preserving NATs, so a relay fallback over iroh is still needed |

Three findings matter regardless of the decision:

1. **The design's 64 KiB send buffer is wrong for video.** At 85 Mbit/s a 60 fps frame is about 177 KB. With `--sbuf 65536` iroh silently evicted 71,000 of 116,000 datagrams (62%) at 85% of capacity, uncounted, with no loss on the wire. The send buffer has to hold at least the largest frame. S2's 64 KiB recommendation came from smooth-traffic runs.
2. **Pacer stalls are host scheduling, not tokio.** The 5–23 ms stalls S2 saw with `AppRate` also show up with no tokio at all: a pinned SCHED_FIFO Zig network thread, or the generator thread, sometimes doesn't run for 2–19 ms on this 4-vCPU VM. The send-side timestamps prove it. iroh on the pinned runtime still had them too (12.35 ms p99 in one run). That answers S2's open item: the dedicated runtime does not remove them. With ~6% pacer headroom, a 15 ms gap takes about 250 ms to drain. This needs rechecking on bare metal.
3. **Burst credit is the main lever for frames, and the pacer location is not.** noq's own token-bucket pacer driven by the same Zig loop scored within 0.1 ms of the Zig pacer (1.4 vs 1.3 ms added). Removing tokio was worth ~0.9 ms. Raising the pacer's credit to about one frame (20 ms at capacity) got another ~0.7 ms. In iroh, `AppRate` can get part of that by reporting a larger `send_quantum` or pacing a little above capacity. This is cheap to try in the shim.

## Why not switch

What the switch buys: ~0.9 ms p99 on frame bursts, exact drop accounting by construction, and half the hand-off tail. The 2 ms S2 bar can also likely be met inside iroh, by sizing the send buffer per frame and raising `AppRate`'s burst credit (to verify). And the switch costs this:

- **iroh's socket can't be shared.** iroh binds and owns its UDP sockets. It reads every packet into its own noq endpoint, and there is no demux hook or raw-send API. Custom transports (`unstable-custom-transports`) take non-IP addresses, so iroh won't hole-punch over them. Sharing the 5-tuple means forking iroh's IP transport (`socket/transports/ip.rs`) with a demux, and the media receive path would then pass through iroh's tokio task again.
- **A second socket means a second NAT traversal.** The demo works through two port-preserving NATs, but it needed a TTL trick because the first naive attempt failed (details below). It fails against a port-randomizing NAT, which iroh would also relay. To get to parity with iroh we would need, at minimum: QUIC address discovery (QAD) from the media socket to iroh's relays instead of guessing ports, hop-count-aware opening TTLs, retry rounds, migration on network change, keepalives for a second NAT binding, and path events for S5's watchdog. iroh has all of that today.
- **There are still two media paths.** Symmetric NATs and the browser are relay-only, so media over iroh datagrams has to exist anyway. Switching adds a second path rather than replacing the first.
- **The platform datapath is ours.** GSO/GRO, ECN, DF/PMTUD, `recvmmsg`, Windows and macOS fast paths: `noq-udp` does all of this for iroh. The prototype sends one `sendto` per packet with no GSO.

**Revisit if:** Phase 2's LAN gate misses by about a millisecond and the miss traces to the transport, or if field tests show iroh's eviction behaviour can't be bounded with counters. The best route then is a small iroh fork with a demux on the shared socket, not a second socket. Taking noq-proto now is cheap (the shim in this spike is ~540 lines), so the option stays open.

## What was built

```
Zig (harness/src/main.zig)                         Rust staticlib (shim/src/lib.rs), sans-I/O
 generator ──SPSC ring + eventfd──► network thread    nq_handle(now, from, bytes)
                                     owns UDP socket   nq_poll_transmit(now) -> bytes, dest
                                     ppoll(sock, efd,  nq_timeout() / nq_handle_timeout(now)
                                           next timer) nq_send_datagram / nq_recv_datagram
                                     token-bucket pacer (rate, credit)
                                     media queue with age limit (drops counted)
```

- **Shim (`shim/`)**: `noq-proto` 1.4.0 (the version iroh 1.4.1 pins), rustls/ring, one endpoint and one connection, no threads and no tokio. The server makes a self-signed cert; the client pins exactly that cert, which in production would arrive over the authenticated iroh control stream. Congestion control has two modes. `cc=0` ("Zig paces") sets the window above `u32::MAX`, which makes noq-proto's pacer step aside (`pacing.rs`), and counts loss without reacting. `cc=1` is `AppRate`'s semantics on noq's own pacer, for the A/B.
- **Harness (`harness/`)**: Zig 0.16, libc declared by hand (no `std.posix`/`std.Io`). `send`/`recv` reproduce S2's traffic and output formats, so S2's `analyze.py` works unchanged. `jitter` reproduces S4's probe and output format (S4's `analyze.py` works unchanged). `punch` (built with `-Drv=true`) is the iroh rendezvous demo.
- **S2 baseline change**: `s2bench` got `S2_CT_CPU`/`S2_CT_PRIO`/`S2_GEN_CPU`, which run iroh on one pinned current-thread runtime (the shim's design since S4) and keep the generator off SCHED_FIFO.

Bugs worth knowing for the real core: a thread created by a SCHED_FIFO thread inherits SCHED_FIFO. A media or generator thread that spins at RT priority gets RT-throttled for 50 ms every second (`sched_rt_runtime_us`), which first showed up here as a perfectly periodic 50 ms stall. Reset the policy explicitly on every thread.

## S2 rerun

Same topology as S2: three netns, a userspace delay line, a TBF bottleneck (`burst 32kb latency 50ms`), 1100-byte payloads, 2 s warm-up, 10 s measured, steady state after 4 s. CPUs: receiver 0, generator 1, network thread / iroh runtime 2 (SCHED_FIFO 50), delay line 3. Every case ran twice. Cells are p99 one-way delay in ms (range over the two runs). Full tables are in [`results/table.md`](results/table.md); per-run summaries are in `results/raw/rep{1,2}/*`.

### Below the cap, pacer at the capacity estimate (90 on a 100 Mbit/s cap, 145 on 160)

Frames (60 fps; one frame handed over at once):

| case | UDP | iroh + AppRate pinned | noq, Zig pacer (2 ms credit) | noq, noq's pacer | noq, Zig pacer (20 ms credit), frame-done |
|---|---|---|---|---|---|
| 100 cap, 50 Mbit, 20 ms RTT | 15.86–15.95 | 18.21–18.22 | 17.19 | 17.28–17.30 | 16.98–17.20 |
| 100 cap, 50 Mbit, 1 ms RTT | 6.36–6.39 | 8.46–8.60 | 7.67–7.69 | 7.79–7.81 | 7.35–7.77 |
| 100 cap, 80 Mbit, 1 ms RTT | 11.47–11.48 | 13.88–13.96 | 13.16–13.26 | 13.28–13.58 | 12.39–13.81 |
| 100 cap, 85 Mbit, 20 ms RTT | 21.79 | 23.90–24.08 | 23.54–23.55 | 23.67 | 22.69–23.83 |
| 100 cap, 85 Mbit, 1 ms RTT | 12.24–12.30 | 14.80–14.83 | 14.05 | 14.16–14.17 | 13.19–13.27 |
| 160 cap, 100 Mbit, 1 ms RTT | 9.28–9.33 | 10.09–10.20 | 9.89–9.91 | 9.92–9.93 | 10.21–11.08 |

Added p99 over UDP, median of all 8 frame cases: iroh 2.18 ms, noq/Zig pacer 1.29, noq/noq pacer 1.41, noq/Zig pacer with 20 ms credit 0.57. The split at the QUIC hand-off ([`results/split.jsonl`](results/split.jsonl)) shows where the time goes. With 2 ms credit, frames wait 7–13 ms p99 in the Zig queue while the pacer spreads them. With 20 ms credit they wait 0.4–0.9 ms, and the burst goes to the bottleneck queue instead, where raw UDP puts it too.

Smooth traffic: everything is within 0.1–0.3 ms of UDP at the median. The outliers are single stalls: iroh 12.35 ms (80 Mbit, 20 ms RTT) and 2.28 ms; noq/Zig pacer 15.36 ms and 12.16 ms; noq's pacer none in these runs. In each noq outlier the hand-off timestamps show the sender queue growing while either the generator (18.8 ms late in one run) or the pinned RT network thread (15 ms gap with the generator on time) wasn't running. A bare `clock_nanosleep` loop pinned at SCHED_FIFO on the idle VM saw 31 wakeups over 2 ms late per minute (max 3.4 ms). Under the load of a trial, the gaps get longer.

### At and above the cap

| case | UDP | iroh + AppRate pinned (64 KiB sbuf) | noq, Zig pacer | notes |
|---|---|---|---|---|
| 100 cap, 95 smooth | 14.71–15.84 | 62.73–63.02 | 62.70–62.78 | both: no hidden queue; overload sits in the TBF; losses = TBF drops |
| 100 cap, 110 smooth | 62.58–62.64 | 63.69–64.15 | 62.78–66.09 | same |
| 100 cap, 95 frames | 23.56–33.54 | 15.69 | 76.31–76.41 | iroh looks fast because it **evicted 82,000 of 129,600 datagrams, uncounted**; noq delivered all but 1,200 (each one a counted QUIC loss = TBF drop) |
| 100 cap, 110 frames | 62.48–62.50 | 15.10–15.11 | 76.24–76.38 | iroh evicted ~100,000, uncounted |
| encoder at 95 / 110 over a pacer at 90 | — | 6,900 / 27,350 evicted, uncounted | 6,800 / 27,250 dropped by the Zig queue at 5 ms age, counted | same damage; only one side knows |

Drop accounting, every run: for noq, `sent − received = Zig queue drops + QUIC lost packets`, and QUIC lost packets equal the TBF's drop counter. Zero unexplained datagrams in all 98 noq runs. iroh matched only when its send buffer never overflowed.

## S4 rerun

S4's scenarios unchanged: 1150-byte datagrams, isolated (one per ms) and burst (36 every 16.7 ms, first datagram of each burst), idle and loaded (6 busy threads on 4 vCPUs). The media thread is on CPU 0 at SCHED_FIFO 80. Cells are p50 / p99 / p99.9 hand-off in µs, from `t0` on the media thread to entry of the `sendto` carrying that datagram. iroh rows are S4's.

| path | idle, isolated | idle, burst | loaded, isolated | loaded, burst |
|---|---|---|---|---|
| noq, media thread drives QUIC itself (`inline`) | 3 / **17** / 29 | 11 / **30** / 69 | 5 / **11** / 20 | 7 / **17** / 24 |
| noq, ring + eventfd to a pinned RT network thread | 34 / **110** / 619 | 85 / **202** / 459 | 27 / **62** / 385 | 43 / **103** / 1374 |
| noq, same, network thread not pinned / normal priority | 38 / **112** / 445 | 94 / **237** / 1094 | 23 / **2819** / 6079 | 37 / **4620** / 10039 |
| iroh, dedicated current-thread runtime, pinned + RT (S4) | 86 / **213** / 1588 | 171 / **398** / 1395 | 36 / **102** / 1043 | 90 / **183** / 1069 |

S4's conclusion holds: the cost is the cross-thread wake, and pinning plus RT priority decide the tail. Without tokio, the wake is about half as expensive. Owning the state machine also allows the `inline` shape, where the thread that has the packet sends it, at ~20 µs p99. iroh can't do that, because noq's connection driver always runs on the runtime thread.

## Sharing the path with iroh: the punch demo

`scripts/punch.sh` sets up both peers behind their own Linux NAT, with a router between them. The host NAT forwards only the host's iroh port, standing in for "iroh reached the host" (relay plus its own punch). The media ports are never forwarded.

1. iroh connects and authenticates (dial by key). One bi stream carries each side's media port, local candidates and, from the host, the media cert to pin. Each side adds a guess for the peer: the IP iroh sees the peer at, with the peer's media port.
2. Both sides send TTL-2 "opening" probes from the Zig media socket, wait 100 ms, then probe normally. The client connects noq-proto to the first candidate that answers.
3. Then 1000 datagram ping-pongs run over the media connection.

| client NAT | result |
|---|---|
| port-preserving (`MASQUERADE`) | punched in 100 ms (2 probes), handshake < 1 ms, 1000/1000 pongs, RTT p50 0.1 ms ([`results/punch.txt`](results/punch.txt)) |
| random port per flow (`MASQUERADE --to-ports 20000-60000 --random`) | no path after 290 probes; needs the relay fallback |

The first version, without the opening probes, **failed even with two port-preserving NATs**. Whichever side's probe reached the other NAT first created an inbound conntrack entry on the guessed port. That NAT then mapped its own peer to a different port, so the other side's guess never matched. This is the class of problem iroh's traversal already handles. On the internet the opening TTL would come from the path's hop count, and the guess would be replaced by QAD against iroh's relays.

## Reproduce

Linux, root, `iproute2`, TBF, `iptables` + `conntrack` for the punch demo, Rust, Zig 0.16 (`pip install ziglang==0.16.0` works when ziglang.org doesn't).

```sh
(cd shim && cargo build --release)
(cd harness && zig build -Doptimize=ReleaseFast)
(cd ../s2-datagram-queueing && cargo build --release && scripts/netns.sh up)
for r in 1 2; do ROOT=out/rep$r scripts/sweep.sh; done      # ~50 min
python3 scripts/report.py out/rep1 out/rep2 > table.md
python3 scripts/split.py out/rep1/noq_*                       # queue vs network split
scripts/jitter.sh out/jitter                                   # S4 matrix, ~5 min
(cd shim && cargo build --release --features rv --target-dir target-rv)
(cd harness && zig build -Doptimize=ReleaseFast -Drv=true -Dshim=../shim/target-rv/release/libs10noq.a -p zig-out-rv)
scripts/punch.sh preserve; scripts/punch.sh random
```

Caveats: a single 4-vCPU cloud VM, as in S2 and S4, where scheduling noise reaches several ms. Two repetitions per case, so treat differences under ~0.3 ms as noise. Loopback and veth only. Linux only. The prototype has no GSO, ECN or PMTUD (MTU stays at 1200).
