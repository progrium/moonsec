# Spike S2: iroh datagram queueing and drops under a bandwidth cap

**Question.** Do iroh datagrams add hidden queueing or silent drops under load?
**Pass criteria (design doc).** Added delay p99 under 2 ms when sending below the cap; every drop visible in stats.

## Verdict

The first table is iroh's default Cubic. The rerun with S3's `AppRate` controller is [further down](#rerun-with-s3s-apprate-controller): it removes the hidden queue and makes every drop at the bottleneck visible, but its pacer adds 1–3 ms to frame bursts and has occasional 5–23 ms stalls on smooth traffic.

| Criterion | Result |
| --- | --- |
| Added p99 < 2 ms below the cap | **Pass with headroom, fail near the cap.** At up to ~91% of wire capacity iroh adds 0.1–0.8 ms p99 over raw UDP in every case. At 96–98% of wire capacity it still passes at 20 ms RTT (0.3–1.4 ms) but fails at 1 ms RTT (2.2–3.0 ms). |
| Every drop visible in stats | **Fail.** Network losses show up in `lost_packets`, but datagrams evicted from iroh's send buffer are not counted anywhere. Receive-buffer drops are also uncounted (by code inspection; none happened in these runs). |
| Hidden queueing | **Yes, at or above the cap and at startup.** The queue sits in iroh's 1 MiB datagram send buffer: 100–140 ms of one-way delay while QUIC's own RTT estimate stays at the path RTT, so it is invisible to anything that watches QUIC RTT. |

So iroh is fine as a pipe *if* the rate controller keeps the offered load ~10% under capacity and the app does its own drop accounting. Recommended follow-ups are at the end.

## Setup

- iroh 1.4.1 / noq 1.4.0, default Cubic, relays and discovery disabled, direct IPv4.
- Three network namespaces on one host: `sender — delay line — receiver`. The bottleneck is a TBF qdisc (`burst 32kb latency 50ms`) on the delay line's egress toward the receiver.
- The sandbox kernel has no `sch_netem`, so RTT comes from a userspace delay line (busy-polling, pinned core, 16 MiB socket buffers so it never drops on its own). RTTs: 20 ms and 1 ms.
- Every datagram carries a sequence number and a `CLOCK_MONOTONIC` send timestamp taken right before `send_datagram`. All namespaces share the clock, so one-way delay is exact. Each iroh run is paired with a raw-UDP run over the same path, rate and pattern; **added delay = iroh p99 − UDP p99**.
- Payload 1100 bytes. Patterns: `smooth` (evenly paced) and `frames` (60 fps, each frame's bytes handed over back to back, like an encoder output). 2 s warm-up traffic, 10 s measured; the table below uses the steady state after 4 s.
- iroh adds 30 bytes per datagram (QUIC header, AEAD tag, DATAGRAM frame), 2.7% at this size. "Wire load" in the table includes that plus UDP/IP/Ethernet headers, which is what the TBF meters. Note that 95 Mbit/s of payload is already 101% of a 100 Mbit/s cap for iroh, while it is 99% for raw UDP.
- Hardware: 4 vCPU sandbox VM. Each case ran once; the raw-UDP baseline itself shows 0.1–2 ms p99 noise from scheduling, so treat sub-millisecond differences as noise.

## Results

One-way delay in ms (includes the configured path delay: 10 ms one-way for `d10000`, 0.5 ms for `d500`). Full table: [`results/table.md`](results/table.md).

### Below the cap, 20 ms RTT

| case | wire load | iroh p50 | iroh p99 | UDP p99 | added p99 |
|---|---|---|---|---|---|
| 100 Mbit cap, 50 smooth | 53% | 10.05 | 10.57 | 10.08 | 0.48 |
| 100 Mbit cap, 80 smooth | 85% | 10.05 | 10.16 | 10.06 | 0.10 |
| 100 Mbit cap, 85 smooth | 91% | 10.05 | 10.75 | 10.16 | 0.59 |
| 100 Mbit cap, 90 smooth | 96% | 10.05 | 11.55 | 10.17 | 1.38 |
| 100 Mbit cap, 92 smooth | 98% | 10.05 | 10.42 | 10.11 | 0.31 |
| 160 Mbit cap, 100 smooth | 67% | 10.05 | 10.34 | 12.14 | (UDP noise) |
| 100 Mbit cap, 50 frames | 53% | 12.10 | 16.45 | 15.95 | 0.49 |
| 100 Mbit cap, 80 frames | 85% | 14.73 | 21.67 | 20.98 | 0.70 |
| 100 Mbit cap, 92 frames | 98% | 15.67 | 23.73 | 22.94 | 0.78 |
| 160 Mbit cap, 100 frames | 67% | 14.10 | 19.48 | 18.85 | 0.64 |

### Below the cap, 1 ms RTT

| case | wire load | iroh p50 | iroh p99 | UDP p99 | added p99 |
|---|---|---|---|---|---|
| 100 Mbit cap, 50 smooth | 53% | 0.55 | 0.79 | 0.54 | 0.25 |
| 100 Mbit cap, 80 smooth | 85% | 0.55 | 0.65 | 0.54 | 0.11 |
| 100 Mbit cap, 85 smooth | 91% | 0.55 | 0.71 | 2.03 | (UDP noise) |
| 100 Mbit cap, 90 smooth | 96% | 0.55 | 2.73 | 0.54 | **2.19** |
| 100 Mbit cap, 92 smooth | 98% | 0.55 | 3.76 | 0.73 | **3.03** |
| 160 Mbit cap, 100 smooth | 67% | 0.55 | 0.98 | 0.55 | 0.43 |
| 160 Mbit cap, 150 smooth | 100% | 3.41 | 5.57 | 0.75 | **4.82** |
| 100 Mbit cap, 92 frames | 98% | 6.27 | 14.22 | 13.43 | 0.79 |
| 160 Mbit cap, 150 frames | 100% | 8.67 | 18.21 | 14.53 | **3.67** |

Median overhead is a steady 30–50 µs. With 60 fps bursts, most of the delay is the bottleneck draining each frame, which raw UDP pays too; iroh adds under 0.8 ms on top whenever load is under the cap.

### At and above the cap (the hidden queue)

| case | wire load | iroh p50 | iroh p99 | UDP p99 | send-buffer evictions (uncounted) | QUIC lost |
|---|---|---|---|---|---|---|
| 100 cap, 95 smooth, 20 ms | 101% | 137.69 | 140.97 | 10.07 | 769 | 274 |
| 160 cap, 150 smooth, 20 ms | 100% | 58.97 | 69.41 | 10.13 | 551 | 60 |
| 100 cap, 110 smooth, 20 ms | 117% | 122.57 | 124.47 | 62.58 | 20,991 | 814 |
| 100 cap, 150 smooth, 20 ms | 160% | 106.65 | 112.53 | 62.70 | 74,848 | 1,154 |
| 100 cap, 95 smooth, 1 ms | 101% | 107.99 | 130.89 | 0.54 | 302 | 10 |

Once Cubic loses at the bottleneck and backs off below the offered rate, the datagram send buffer fills and stays full. 1 MiB is ~85 ms at 100 Mbit/s, so one-way delay jumps to 100–140 ms with the network queue empty. From then on `send_datagram` silently evicts the oldest datagram for each new one. Raw UDP at the same rates just loses packets at the TBF and stays at path delay plus the TBF's 50 ms queue.

### Startup transient

Every run at 80% or more of the cap with 20 ms RTT loses packets in the first ~200 ms: slow start overshoots the bottleneck (TBF drops, counted as `lost_packets`), and frame bursts that exceed the initial window get evicted from the send buffer (not counted). At 92% load the resulting sender-side queue (~74 ms) takes about 3 s to drain because there is only 8% headroom. A stream should expect a ramp-up period or start below target.

### Buffer tuning and backpressure (100 Mbit cap, 20 ms RTT)

| variant | 92 Mbit p99 | 95 Mbit p99 | 110 Mbit p99 | evictions at 110 |
|---|---|---|---|---|
| default 1 MiB send buffer | 10.42 | 140.97 | 124.47 | 20,991 |
| `datagram_send_buffer_size(256 KiB)` | 28.68 (startup tail) | 83.51 | 71.29 | 22,074 |
| `datagram_send_buffer_size(64 KiB)` | 10.90 | 67.44 | 57.31 | 22,379 |
| `send_datagram_wait` (backpressure) | — | 142.03 (frame-done 213) | 140.67 (frame-done 2,069) | 0 |

A smaller send buffer caps iroh's own queue (64 KiB ≈ 5 ms at 100 Mbit) but does not remove the delay, because Cubic is still the one deciding the send rate, and it evicts more. `send_datagram_wait` stops evictions but moves the queue into the application, which is worse for real-time video. Neither replaces a rate controller that stays under capacity; see S3's custom controller for the congestion-control side.

## Drop visibility, in detail

| Where a datagram can be dropped | Counted? |
| --- | --- |
| Network (bottleneck queue) | Yes: `PathStats::lost_packets` / `ConnectionStats::lost_packets`, matched TBF drops exactly in every run. |
| Sender `send_datagram` evicting the oldest queued datagram | **No.** Only a `trace!` log in `noq-proto/src/connection/datagrams.rs`. Derivable after the fact as `app_sent − ConnectionStats::frame_tx.datagram`, but only once the queue has drained. |
| Receiver datagram buffer overflow (`datagram_receive_buffer_size`, default 1.25 MB) | **No.** `debug!("dropping stale datagram")` only. Derivable as `frame_rx.datagram − datagrams read`. None happened here because the reader kept up. |
| Datagrams over a reduced MTU (`drop_oversized`) | No; `trace!` only. |

**noq bug found:** `Connection::datagram_send_buffer_space()` is documented as "a datagram of at most this size is guaranteed not to cause older datagrams to be dropped", but it subtracts the per-datagram bookkeeping overhead (`size_of::<Datagram>()`) once, while the eviction check counts it for every queued datagram. With hundreds of datagrams queued it reports space when there is none. In these runs it never dropped below the payload size, while 769 to 75,000 datagrams were evicted. It cannot be used as a "would drop" check; worth an upstream issue.

## What this means for the design

1. **Keep iroh; the pipe itself is cheap.** Under the cap it adds tens of microseconds at p50 and well under 2 ms at p99.
2. **The rate controller must stay ~10% below capacity** and own the send rate. If the encoder ever outruns Cubic, delay jumps by the full send buffer in one step, and QUIC RTT will not show it. The delay-gradient controller should use our own one-way delay timestamps, not QUIC's RTT.
3. **Shrink the send buffer** (64 KiB or one frame's worth) so an overshoot costs a few milliseconds, not 100.
4. **Count drops in the shim:** `sent − frame_tx.datagram` on the sender, `frame_rx.datagram − read` on the receiver, plus our own sequence numbers for end-to-end loss. Do not rely on `datagram_send_buffer_space()`. Longer term, upstream counters for evictions in noq.
5. **Confirm with S3's custom controller:** rerun this harness with it to check the at-cap and startup cases.

## Rerun with S3's `AppRate` controller

`src/apprate.rs` is S3's controller copied unchanged (`spikes/s3-congestion/src/lib.rs`). It paces at a target set from outside, keeps the window at 2× BDP, and counts loss without cutting the rate. The sender takes `--cc apprate [--target-mbps N]`. It was confirmed active on every run (`cc_paths_built: 1`; one path, since the sender has no route around the delay line). Two ways of setting the target were tried:

- **Encoder rate:** target = 1.05× the offered load (`sweep3.sh`, 36 runs). This is "QUIC never limits; the encoder is the rate controller".
- **Capacity:** target = 90 Mbit/s of payload on the 100 Mbit/s cap (~96% of the wire) and 145 on the 160 cap, with the encoder below it (`sweep4.sh`, 16 runs). This is what the design intends: the core's capacity estimate sets the pacer and the encoder runs under it.

Times in ms, steady state after 4 s. "Added" is over raw UDP on the same case.

### At and above the cap: the hidden queue is gone, and every drop is counted

| case (20 ms RTT unless noted) | Cubic p99 | AppRate p99 | UDP p99 | Cubic evictions (uncounted) | AppRate evictions | AppRate `lost_packets` = TBF drops |
|---|---|---|---|---|---|---|
| 100 cap, 95 smooth | 140.97 | 63.78 | 10.07 | 769 | 0 | 1,055 = 1,055 |
| 100 cap, 95 smooth, 1 ms | 130.89 | 53.93 | 0.54 | 302 | 0 | 1,015 = 1,015 |
| 100 cap, 95 frames | 146.70 | 76.21 | 29.53 | 1,143 | 0 | 1,140 = 1,140 |
| 100 cap, 110 smooth | 124.47 | 65.81 | 62.58 | 20,991 | 0 | 21,502 = 21,502 |
| 100 cap, 110 frames | 134.95 | 76.17 | 62.49 | 20,863 | 0 | 21,300 = 21,300 |
| 160 cap, 150 smooth | 69.41 | 41.15 | 10.13 | 551 | 0 | 0 |
| 160 cap, 150 frames | 60.33 | 37.41 | 24.08 | 993 | 0 | 0 |
| 100 cap, 150 smooth | 112.53 | 116.82 | 62.70 | 74,848 | 5,713 | 69,905 |

With `AppRate` iroh behaves like raw UDP over the same bottleneck: an overload fills the *network* queue (the TBF's 50 ms), where our one-way delay measurement can see it, instead of a 1 MiB queue inside the sender. Every dropped datagram is a QUIC loss that matches the TBF's drop counter exactly, so **"every drop visible in stats" passes with `AppRate`** as long as the send buffer doesn't fill. The exception is 150 Mbit/s offered on a 100 Mbit/s cap with smooth pacing: the sender couldn't drain the buffer fast enough and evicted 5,713 datagrams (7% of the losses) on top of the counted ones. That is a 50% overload, which the real rate controller should never sit in.

If the encoder outruns the target, the send buffer is the queue again, as expected:

| encoder vs `AppRate` target 90 | send buffer | p99 | evictions (uncounted) |
|---|---|---|---|
| 95 | 1 MiB | 97.06 | 6,365 |
| 95 | 64 KiB | 17.01 | 7,348 |
| 110 | 1 MiB | 86.28 | 27,424 |
| 110 | 64 KiB | 14.63 | 28,296 |

So the shim should still use a small send buffer and count evictions itself; 64 KiB keeps the damage to ~5 ms.

### Below the cap: pace at capacity, not at the encoder rate

| case | Cubic p99 | AppRate @ encoder ×1.05 | AppRate @ capacity | UDP p99 |
|---|---|---|---|---|
| 100 cap, 50 frames, 20 ms | 16.45 | 24.19 | 18.39 | 15.95 |
| 100 cap, 80 frames, 20 ms | 21.67 | 24.19 | 23.30 | 20.98 |
| 100 cap, 85 frames, 20 ms | 22.44 | — | 24.13 | 21.79 |
| 100 cap, 50 frames, 1 ms | 6.94 | 14.88 | 8.74 | 6.38 |
| 100 cap, 80 frames, 1 ms | 12.18 | 39.71 | 13.94 | 11.47 |
| 160 cap, 100 frames, 20 ms | 19.48 | — | 20.00 | 18.85 |
| 100 cap, 50 smooth, 20 ms | 10.57 | 11.99 | 10.22 | 10.08 |
| 100 cap, 80 smooth, 20 ms | 10.16 | 10.16 | **24.03** | 10.06 |
| 100 cap, 85 smooth, 20 ms | 10.75 | — | 13.26 | 10.16 |
| 100 cap, 90 smooth, 1 ms | 2.73 | 7.90 | — | 0.54 |
| 100 cap, 92 smooth, 20 ms | 10.42 | 18.21 | — | 10.11 |
| 160 cap, 100 smooth, 1 ms | 0.98 | — | 2.33 | 0.55 |
| 160 cap, 150 smooth, 1 ms | 5.57 | 31.13 | — | 0.75 |

- **Pacing at the encoder rate is wrong for video.** A 60 fps frame is handed over in one burst; pacing it at ~1.05× the average rate spreads it over almost the whole frame interval (~16 ms), so frame-done p99 is up to 3× Cubic's (39.7 vs 12.2 ms at 80 Mbit/s, 1 ms RTT). Pacing at the capacity estimate brings frames back to within 2 ms of Cubic, but not all the way: it adds 0.9–2.6 ms p99 over raw UDP where Cubic adds 0.5–0.8 ms, because the pacer still spreads each burst at ~96% of the link instead of letting it through at line rate.
- **`AppRate` has short sender-side stalls that Cubic doesn't.** In smooth runs with no loss and an empty network queue, the delay jumps by 5–23 ms for half a second to a second, a few times per run (the 24 ms p99 at 80 Mbit/s above is one of these). At 150 Mbit/s on 1 ms RTT the paced sender sat on a ~30 ms backlog for the whole run. The likely cause, from reading `noq-proto/src/connection/pacing.rs` and not yet verified: in rate mode the pacer's token bucket holds only about 2 ms of credit (`rate_capacity`), so whenever the connection driver wakes late on this busy 4-core box the unused credit is lost and the effective rate drops below the target. With 5% headroom that becomes a queue. Cubic's window-derived pacer has more slack. This matches S4's result that the shared tokio runtime adds 1–4 ms p99 under load; S4's pinned current-thread runtime should fix it, which is worth checking.

### Updated verdict with `AppRate`

| Criterion | Cubic (default) | `AppRate` |
| --- | --- | --- |
| Added p99 < 2 ms below the cap | Pass up to ~91% of wire capacity | **Borderline fail.** Frame bursts paced at the capacity estimate add 0.9–2.6 ms p99 over UDP (Cubic: 0.5–0.8). Smooth traffic adds 0.1–1.8 ms in most runs but up to 14 ms when a pacer stall lands in the window |
| Hidden queue at or above the cap | 100–140 ms inside iroh, invisible to QUIC RTT | Gone: overload lands in the network queue, like raw UDP |
| Every drop visible in stats | Fail: evictions uncounted | **Pass** while the encoder stays under the target (all losses = `lost_packets`); evictions return if the encoder outruns the target or the overload is extreme, so the shim still counts `sent − frame_tx.datagram` |

**Recommendation:** ship `AppRate`-style control, set its pacing rate from the core's **capacity estimate** (not the encoder bitrate), keep a 64 KiB send buffer and the shim-side eviction counter, and drive the connection from S4's dedicated pinned runtime. Then rerun the smooth cases here to confirm the stalls are gone. Until then, the stalls are the one open item.

## Reproduce

Needs Linux, root, `iproute2`, and TBF in the kernel (netem is not required).

```sh
cargo build --release
scripts/netns.sh up
ROOT=out/sweep1 scripts/sweep.sh     # main matrix, ~25 min
ROOT=out/sweep2 scripts/sweep2.sh    # near-cap, buffer and backpressure runs, ~10 min
ROOT=out/sweep3 scripts/sweep3.sh    # AppRate paced at the encoder rate, ~10 min
ROOT=out/sweep4 scripts/sweep4.sh    # AppRate paced at a capacity estimate, ~5 min
WARM=4 python3 scripts/report.py out/sweep1 out/sweep2 out/sweep3 out/sweep4
scripts/netns.sh down
```

`scripts/trial.sh` runs one case (see its header for env vars). `results/` holds the summaries from the runs above (`raw/*/send.json`, `recv.json`, `qdisc.txt`); per-packet CSVs were left out for size.
