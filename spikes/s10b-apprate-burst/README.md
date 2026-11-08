# Spike S10b: burst credit for iroh + `AppRate`

**Question.** S10 found iroh + S3's `AppRate` on the pinned current-thread runtime adds 2.2 ms p99 over raw UDP to 60 fps frame bursts below the cap, failing S2's 2 ms bar, while noq-proto with one frame of pacer credit added 0.6 ms. Does the same burst credit, added to `AppRate` inside iroh, get iroh under the bar?

## Verdict

**Yes. With 10–20 ms of burst credit, iroh adds 0.41–0.48 ms p99 over raw UDP to frames (median of 8 cases, worst 0.59 ms), down from 2.37 ms.** That is at or a little better than S10's noq-proto with the same credit (0.57 ms), so the 2 ms bar is met inside iroh and S10's last argument for leaving it is gone. The sustained rate still holds the target exactly (90.0 Mbit/s with an encoder at 95 or 110), smooth traffic is unchanged or slightly better (0.35 vs 0.41 ms median), and nothing new is lost.

| frames, below the cap (8 cases, 2 runs each) | added p99 over UDP, median (range) | frame-done p99 over UDP, median |
| --- | --- | --- |
| `AppRate` as in S10 (noq's ~2 ms pacer bucket) | 2.37 ms (1.03–2.64) | 2.50 ms |
| `AppRate` + 10 ms credit | **0.41 ms** (0.20–0.59) | 0.69 ms |
| `AppRate` + 20 ms credit | **0.48 ms** (0.12–0.58) | 0.80 ms |
| no credit, pacing at 1.2× the capacity estimate | 0.59 ms (0.51–0.65) | 0.84 ms |
| S10: noq-proto, Zig pacer, 20 ms credit | 0.57 ms | — |

Recommendation for the shim: `AppRate` takes a burst credit of one frame interval at the target rate (16.7 ms at 60 fps), set by the core with the target. 10 and 20 ms are within noise of each other, so the exact value isn't sensitive. Pacing 20% above the estimate gets most of the gain too, but it raises the sustained rate above the estimate, which the credit doesn't.

Two things this does not change:

- **The send buffer still has to hold a frame.** With 20 ms credit and the design's 64 KiB send buffer, iroh still evicted 38–60% of frame datagrams (uncounted, no loss on the wire). The generator hands over a whole frame faster than iroh's runtime thread drains it, so credit doesn't help there. S10's rule stands: size the buffer to the largest frame.
- **An encoder above the target still queues in the send buffer** (86–100 ms p99 with the 1 MiB default, same with and without credit). That queue belongs in the core, bounded by age, as the design already says.

## How the credit works, and why it lives in the controller

The levers S10 suggested don't all exist in noq-proto 1.4.0 (the version iroh 1.4.1 pins):

- **`send_quantum` doesn't add credit.** It only caps how many datagrams go into one GSO batch (`connection/mod.rs`). `AppRate` reports 2 MTU.
- **noq's pacer bucket is fixed by its constants.** With an explicit `pacing_rate`, the bucket holds 2 ms at the rate, clamped to 10–256 packets and at most 10 ms (`pacing.rs`, `rate_capacity`). At 90 Mbit/s that is ~22 KB against a ~177 KB frame at 85 Mbit/s, so a frame is spread over ~15 ms.

So `AppRate` keeps its own token bucket (`RateKnob::burst_us`, in [`../s2-datagram-queueing/src/apprate.rs`](../s2-datagram-queueing/src/apprate.rs) and mirrored into [`../s3-congestion/src/lib.rs`](../s3-congestion/src/lib.rs)):

- The bucket holds `burst_us` of traffic at the target rate and refills at the target rate. `on_sent` debits it.
- While it holds at least one packet, `metrics()` reports a 10 Gbit/s pacing rate, so noq's pacer lets the burst out at line rate. Once it's spent, `metrics()` reports the target, and noq paces as before. noq re-reads `metrics()` on every poll and pacing timer, so the switch takes effect per packet.
- The window gets the whole bucket on top of 2× BDP, so the burst isn't window-limited at 1 ms RTT.
- The bucket must be allowed to go negative. The first version floored it at zero. noq sends a 2-packet batch once one packet's credit is there, and forgiving that overdraft lifted the sustained rate to 93.8 Mbit/s payload on a 90 target (TBF drops, 63 ms p99). The over-target check below caught it. With debt carried, delivered rate is 90.0 Mbit/s. All credit runs in the tables were redone after the fix (the frame numbers moved by under 0.1 ms).
- `metrics()` only gets `&self`, so it computes the bucket level lazily with `Instant::now()` from the last `on_sent`. This depends on noq calling `metrics()` right before each pacing decision, which is an internal behaviour to pin and test with the shim (the design already lists per-path controller internals as an upgrade risk).

## Results

Same as S10: S2's three netns with a userspace delay line and a TBF (`burst 32kb latency 50ms`), 1100-byte payloads, 2 s warm-up, 10 s measured, steady state after 4 s, iroh on one pinned current-thread runtime at SCHED_FIFO 50 (CPU 2), generator on CPU 1, receiver CPU 0, delay line CPU 3. Pacer target 90 on the 100 Mbit/s cap and 145 on 160. Two runs per case. Cells are p99 one-way delay in ms (range over the runs); the full tables, including frame-done, are in [`results/table.md`](results/table.md) and per-run summaries in `results/raw/rep{1,2}/*/summary.json`.

### Frames (60 fps, one frame handed over at once)

| case | UDP | AppRate (S10 config) | + 10 ms credit | + 20 ms credit | no credit, pace 1.2x |
|---|---|---|---|---|---|
| 100 cap, 50 Mbit, 20 ms RTT | 15.87–15.89 | 18.30–18.39 | 16.37–16.37 | 16.39–16.40 | 16.38–16.41 |
| 100 cap, 80 Mbit, 20 ms RTT | 20.93–20.95 | 23.23–23.27 | 21.26–21.34 | 21.07–21.17 | 21.47–21.52 |
| 100 cap, 85 Mbit, 20 ms RTT | 21.70–21.75 | 24.09–24.20 | 21.89–21.95 | 21.74–21.95 | 22.35–22.36 |
| 160 cap, 100 Mbit, 20 ms RTT | 18.78–18.81 | 19.79–19.86 | 19.06–19.23 | 18.89–19.08 | 19.26–19.34 |
| 100 cap, 50 Mbit, 1 ms RTT | 6.39–6.40 | 8.71–8.74 | 6.87–6.89 | 6.89–6.89 | 6.90–6.99 |
| 100 cap, 80 Mbit, 1 ms RTT | 11.43–11.46 | 14.08–14.08 | 11.77–11.88 | 11.94–11.96 | 12.05–12.07 |
| 100 cap, 85 Mbit, 1 ms RTT | 12.22–12.26 | 14.85–14.92 | 12.56–12.79 | 12.70–12.71 | 12.86–12.90 |
| 160 cap, 100 Mbit, 1 ms RTT | 9.26–9.28 | 10.30–10.46 | 9.80–9.92 | 9.82–9.89 | 9.90–9.93 |

Added p99 over UDP, per kind: median (min–max) over the cases above

- AppRate (S10 config): **2.37 ms** (1.03 to 2.64, 8 cases)
- + 10 ms credit: **0.41 ms** (0.20 to 0.59, 8 cases)
- + 20 ms credit: **0.48 ms** (0.12 to 0.58, 8 cases)
- no credit, pace 1.2x: **0.59 ms** (0.51 to 0.65, 8 cases)

The baseline column reproduces S10's iroh numbers within 0.3 ms (median added p99 2.37 ms here, 2.18 ms in S10).

### Smooth traffic

| case | UDP | AppRate (S10 config) | + 20 ms credit |
|---|---|---|---|
| 100 cap, 50 Mbit, 20 ms RTT | 10.07–10.74 | 10.78–11.22 | 10.59–10.82 |
| 100 cap, 80 Mbit, 20 ms RTT | 10.06–10.08 | 10.21–10.39 | 10.30–10.80 |
| 100 cap, 85 Mbit, 20 ms RTT | 10.15–11.60 | 10.75–19.48 | 11.17–11.36 |
| 160 cap, 100 Mbit, 20 ms RTT | 10.07–11.39 | 10.24–10.64 | 10.19–11.57 |
| 100 cap, 50 Mbit, 1 ms RTT | 0.54–0.55 | 1.09–2.39 | 0.70–0.97 |
| 100 cap, 80 Mbit, 1 ms RTT | 0.70–1.04 | 1.65–1.78 | 1.24–1.52 |
| 100 cap, 85 Mbit, 1 ms RTT | 0.91–0.96 | 0.78–0.94 | 0.81–1.36 |
| 160 cap, 100 Mbit, 1 ms RTT | 0.55–0.87 | 0.74–1.11 | 0.93–2.95 |

Added p99 over UDP, per kind: median (min–max) over the cases above

- AppRate (S10 config): **0.41 ms** (-0.28 to 4.24, 8 cases)
- + 20 ms credit: **0.35 ms** (0.15 to 1.23, 8 cases)

The single outliers (19.5 ms baseline, 2.9 ms with credit) are the host-scheduling stalls S10 traced. With credit, a backlog left by a stall can drain at line rate instead of at the target, which may be why its worst case is lower, but two runs are too few to claim that.

### Encoder above the 90 Mbit/s target (100 cap, smooth, 20 ms RTT, 1 MiB send buffer)

| run | delivered Mbit/s (payload) | evicted | TBF dropped | p99 ms |
| --- | --- | --- | --- | --- |


### 64 KiB send buffer with 20 ms credit (frames, 20 ms RTT)



## Reproduce

Linux, root, `iproute2` with TBF, Rust. Uses S10's trial script and S2's binary and topology.

```sh
(cd ../s2-datagram-queueing && cargo build --release && scripts/netns.sh up)
for r in 1 2; do ROOT=out/rep$r scripts/sweep.sh; done     # ~40 min
python3 scripts/report.py out/rep1 out/rep2 > results/table.md
```

Caveats: the same single 4-vCPU cloud VM class as S2 and S10, where scheduling noise reaches several ms, so treat differences under ~0.3 ms as noise. Loopback and veth only, no GSO in the path, Linux only.
