# S11b: rate control on real kernel bottlenecks

**Question.** S11 tested the rate controllers in a simulator with one droptail queue and a minimal Reno flow. How do they behave on real Linux bottlenecks (fq_codel and droptail), and next to real Cubic and BBR flows? Measure utilization, queueing delay and fair share.

**Status (Nov 8, 2026): done, in an emulated kernel.** The controllers are S11's unchanged `s11net` (same `est.zig`), running over real UDP through real Linux qdiscs and real TCP stacks. The sandbox kernel has no fq_codel, netem or fq, so every run is inside QEMU (TCG, no KVM) on a stock Ubuntu 6.8 kernel. A native-kernel cross-check at 25 Mbit/s agrees within about 10% (see Caveats).

## Answer in short

- **fq_codel solves coexistence.** With fq_codel at the bottleneck, `gcc-hybrid` gets 0.86× its fair share against Cubic and 0.88× against BBR. Its own queueing stays at 1.7–2.0 ms p50 and 4.7–5.7 ms p95 while the TCP flow runs. A Cubic flow in our place gets 0.91–0.94×, so we are close to a well-behaved TCP.
- **A deep droptail buffer is the bad case, worse than S11's simulation said.** With a 500 KB buffer (80 ms at 50 Mbit/s), `gcc-hybrid` gets 0.31× its fair share against Cubic (simulated Reno: 0.55×) and 0.29× against BBR. Cubic keeps the shared queue at 62 ms p50 and 80 ms p95, which we sit behind whatever we send. The drain gives up as designed, but the gradient detector keeps cutting on each Cubic sawtooth, so the target slides down to 3–5 Mbit/s.
- **A shallow droptail buffer is in between.** With 125 KB (20 ms), `gcc-hybrid` gets 0.61× against Cubic and 0.25× against BBR, at 12–13 ms queueing p50.
- **The queue-delay controller starves next to TCP on droptail.** `qdelay-probe` gets 0.02–0.13× its fair share on both droptail sizes and takes 4–7 s to recover after the flow leaves. Its 5 ms standing queue also matches CoDel's 5 ms target, so on fq_codel CoDel drops its packets: 211 lost frames per minute versus 37 for `gcc-hybrid` in the steps runs. This plus S11's queueing p99 rules it out.
- **Stock GCC stops responding in a shallow buffer.** In a 125 KB droptail queue the queue is always full, so the delay gradient reads flat. Loss stays near 9%, under the port's 10% loss cap, so GCC keeps ramping to 70 Mbit/s on a 50 Mbit/s link and takes 1.57× its fair share from Cubic at 9% loss. `gcc-hybrid` didn't do this in any run, but its loss response is the same, so the core needs a real loss rule.
- **Capacity steps behave as in the simulation, on every qdisc.** Steps 25→10→40 Mbit/s, alone, medians of 3 runs per qdisc:

  | | fq_codel | droptail 250 KB | droptail 62.5 KB | S11 sim (wired) |
  | --- | --- | --- | --- | --- |
  | Utilization at 25 / 10 / 40 Mbit/s | 0.81 / 0.68 / 0.86 | 0.84 / 0.72 / 0.88 | 0.85 / 0.72 / 0.87 | 0.88 |
  | Time to 80% at startup | 0.7 s | 0.7 s | 0.8 s | 1.6 s |
  | Target below new capacity after the drop | 300 ms | 300 ms | 500 ms | 300 ms |
  | Peak p95 queueing after the drop | 190 ms | 157 ms | 50 ms (buffer limit) | 200 ms |
  | Drained (1 s median of p95 < 20 ms) | 0.5 s | 0.4 s | 0.4 s | 0.7–0.9 s |
  | Time to 80% after the step up | 1.8 s | 1.8 s | 1.8 s | 1.7 s |
  | Queueing p50 / p99 | 1.9 / 16.8 ms | 1.9 / 16.3 ms | 2.0 / 15.1 ms | 2.1 / 10.8 ms |

  fq_codel does not help a lone flow after a capacity drop. CoDel waits a 100 ms interval before it drops, so it peaks like a 250 KB droptail buffer, and our standing-queue drain still does the work.
- **The train estimate locks onto our share under fair queueing.** Under fq_codel the frame-train estimate reads our round-robin share, not the link rate. Pacing then follows that estimate. When the competitor leaves, frames are paced at the old share, so the dispersion still reads the old share and the jump can't fire. Recovery falls back to GCC's ramp: 1.8 s after Cubic leaves, 6.2 s after BBR. On droptail it takes 1.7–2.1 s. The fix is cheap: now and then pace a frame well above the estimate (say 2×) so the train can see spare capacity.

## Rerun with the follow-ups

**Nov 8, 2026.** The three changes this spike called for are now in `core/rate` (competing-flow mode, a loss rule below 10%, and the train floor plus probe frames; see [core/rate/README.md](../../core/rate/README.md)). [`tools/ratenet`](../../tools/ratenet/main.zig) is `s11net` with `est.zig` replaced by `core/rate`: same wire format, CLI, CSV and RESULT line, so these scripts drive it unchanged. Every cell ran again in the same emulated 6.8 kernel, 3 runs each, with two controllers back to back:

- `core`: `core/rate` with its defaults.
- `core-s11b`: the same code with the follow-ups off, which is this spike's `gcc-hybrid`. Running it in the same VM session gives a like-for-like baseline, since the emulator's noise varies between sessions (the baseline's frame p50 here is 2–4× the original run's in some cells).

Full tables: [`results/core-rerun/table.md`](results/core-rerun/table.md); per-run numbers and raw files under `results/core-rerun/`.

### With a competing TCP flow (our share of a fair half, medians of 3)

| competitor | bottleneck | `core-s11b` | `core` | original `gcc-hybrid` | Cubic in our seat | `core` q p50 / p95 with TCP | `core` recover |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Cubic | droptail 500 KB | 0.34 | **0.49** | 0.31 | 1.14 | 65 / 80 ms | 2.1 s |
| Cubic | droptail 125 KB | 0.66 | **0.72** | 0.61 | 0.98 | 11 / 21 ms | 2.0 s |
| BBR | droptail 500 KB | 0.28 | **0.32** | 0.29 | 0.77 | 13 / 38 ms | 1.9 s |
| BBR | droptail 125 KB | 0.28 | **0.29** | 0.25 | 0.65 | 13 / 23 ms | 2.1 s |
| Cubic | fq_codel | 0.84 | 0.80 | 0.86 | 0.94 | 1.8 / 9.7 ms | 6.7 s |
| BBR | fq_codel | 0.80 | 0.75 | 0.88 | 0.91 | 1.6 / 8.5 ms | 6.2 s |

- **Against Cubic in a deep FIFO, about half a fair share, up from a third.** Per run: 0.43–0.74 in tuning runs, 0.38–0.61 here. The drain now gives up after 600 ms when its cuts don't move the queue (it used to cut for 1.5 s, which handed Cubic most of the link before competing mode started), and in competing mode loss cuts are regained within a second. Cubic in our seat still gets 1.14, so this is a gain, not parity. Frame delay with Cubic is the queue Cubic keeps (65 ms p50), which nothing on our side can remove.
- **BBR is unchanged at about 0.3.** Its queue (13 ms p50) stays under the drain's 30 ms threshold, so the drain never gives up and competing mode never starts; the trendline keeps cutting on BBR's probe cycles. An entry on "repeated overuse cuts that don't empty the queue" fixed the trigger but also fired on S11's simulated Wi-Fi stalls and filled the buffer there, so it is in the code but off (`competing_overuses = 0`). This needs a better signal, or the real Wi-Fi data to tell the two apart.
- **fq_codel: not hurt beyond noise.** Shares are 0.04–0.05 lower than the baseline, within the run-to-run spread (0.63–0.81 for BBR), and competing mode started once in 6 runs. Our queueing p95 rose from 5 to 9–10 ms, from the probe frames.
- **Recovery after the flow leaves an fq_codel bottleneck: 6.2–6.7 s, against 8.3–14.1 s for the baseline in the same session** (the original S11b run had 1.8 and 6.2 s). The probe frames do let the train see the link free up, but the jump still waits out the 2 s quiet after a decrease, and the drain's cuts as the queues settle reset that clock. Per run it is 3.3–7.6 s. This doesn't meet "regain the link in about a second" yet.
- **The 16.6 s outlier is gone**: with the train floor, the target never fell under the 4-packet line, and droptail recovery is 1.9–2.1 s in every cell.

### Capacity steps, alone

Unchanged within noise on every bottleneck: utilization 0.78–0.83 / 0.68–0.71 / 0.86–0.88 at 25 / 10 / 40 Mbit/s, below the new rate in 300–400 ms, drained in 0.4–0.5 s, back to 80% in 1.8–1.9 s. Queueing p99 is 14–22 ms against 15–17 ms for the baseline; the probe frames add a few ms at the top. No competing-mode entries.

```sh
zig build ratenet -Doptimize=ReleaseFast -Dcpu=x86_64_v2 -p zig-out-v2     # from the repo root
S11=$PWD/zig-out-v2/bin/ratenet OUT=/tmp/rerun CTLS="core core-s11b" \
  CELLS="cubic,bfifo:500000 bbr,bfifo:500000" REPS=3 spikes/s11b-kernel-bottlenecks/scripts/run-all.sh
```

## Setup

- **Topology.** Three network namespaces: `snd` → `rtr` → `rcv`, connected by veth pairs with TSO, GSO and GRO off.
  - Propagation: netem adds 10 ms each way (20 ms RTT). Forward delay is on `snd`'s egress, reverse delay on `rcv`'s egress.
  - Bottleneck: `rtr`'s egress toward `rcv`. An HTB class sets the rate (burst 3000 B), with one of these leaves:
    - `fq_codel` with kernel defaults (5 ms target, 100 ms interval).
    - `bfifo` (droptail) with a byte limit.
- **Controllers.** S11's `s11net` with `gcc` (stock), `gcc-hybrid` (S11's pick) and `qdelay-probe`. They run the same `est.zig` as the simulator: 60 fps, lognormal frame sizes, a 4× frame every 3 s, 1200-byte packets and 5 ms feedback.
- **Reference.** `tcp-cubic` puts a 60 s iperf3 Cubic flow in our place, to show what a well-behaved TCP gets.
- **Competing flows.** iperf3 with `-C cubic` or `-C bbr` (BBRv1, the 6.8 kernel's `tcp_bbr`) from 20 s to 40 s, between the same hosts, so the RTT matches ours. Senders pace internally; there is no `fq` qdisc on them.
- **Scenarios** (60 s, 3 runs each):

  | Scenario | Rate | Bottleneck leaf | Notes |
  | --- | --- | --- | --- |
  | `steps` | 25 → 10 (t=20 s) → 40 (t=40 s) Mbit/s | fq_codel, bfifo 250 KB, bfifo 62.5 KB | Alone. Half S11's 50/20/80, because the emulated sender tops out near 65 Mbit/s. The buffers are S11's 500 KB and 1 BDP, also halved, so they hold the same time. |
  | `cubic` | 50 Mbit/s | fq_codel, bfifo 500 KB, bfifo 125 KB | Cubic from 20 to 40 s |
  | `bbr` | 50 Mbit/s | same | BBR from 20 to 40 s |

- **Metrics.**
  - util: media goodput / (rate × 1200/1242), because HTB counts Ethernet, IP and UDP headers. Steady windows are 5–20 s, 25–40 s and 45–60 s.
  - share: our goodput from 25 to 40 s divided by half the goodput capacity. TCP share is the same for iperf3's throughput, with 1448/1514 payload per wire byte.
  - Queueing: our OWD minus the minimum OWD. All namespaces share one clock, so no offset correction is needed. Per-packet p50/p99 come from `s11net` and exclude the first 3 s. "With TCP" columns use the 100 ms-window p50/p95 from the CSV.
  - start, down, peak, drain, up: as in S11. Drain is the time until the 1 s median of the 100 ms p95s is under 20 ms, so the 4× scene-change frames, which exceed 20 ms at 10 Mbit/s, don't count as a standing queue.
  - recover: time after the TCP flow ends until we're back at 80% of capacity.

## Results

Medians of 3 runs. Full table: [`results/table.md`](results/table.md); per-run numbers: [`results/summary.csv`](results/summary.csv); per-100 ms timeseries, iperf3 JSON (gzipped) and qdisc stats: `results/raw/`.

### With a competing TCP flow (50 Mbit/s, flow from 20 to 40 s)

Shares are fractions of a fair half. "q" is our queueing during the TCP flow.

| competitor | bottleneck | ctl | util alone | our share | TCP share | q p50 | q p95 | util after | recover |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Cubic | fq_codel | gcc | 0.29 | 0.74 | 1.13 | 5.2 | 24.4 | 0.78 | 10.2 s |
| Cubic | fq_codel | **gcc-hybrid** | 0.87 | **0.86** | 1.07 | 1.7 | 5.7 | 0.87 | 1.8 s |
| Cubic | fq_codel | qdelay-probe | 0.91 | 0.92 | 1.01 | 3.9 | 20.3 | 0.89 | 1.5 s |
| Cubic | fq_codel | *tcp-cubic* | 0.95 | 0.94 | 0.95 | | | 0.94 | |
| Cubic | droptail 500 KB | gcc | 0.29 | 0.36 | 1.53 | 63.6 | 77.3 | 0.31 | 19.4 s |
| Cubic | droptail 500 KB | **gcc-hybrid** | 0.87 | **0.31** | 1.61 | 62.4 | 81.7 | 0.87 | 2.1 s |
| Cubic | droptail 500 KB | qdelay-probe | 0.88 | 0.02 | 1.79 | 67.2 | 80.7 | 0.81 | 7.4 s |
| Cubic | droptail 500 KB | *tcp-cubic* | 0.95 | 1.14 | 0.79 | | | 0.94 | |
| Cubic | droptail 125 KB | gcc | 0.29 | 1.57 | 0.32 | 12.4 | 22.9 | 0.96 | 0 |
| Cubic | droptail 125 KB | **gcc-hybrid** | 0.88 | **0.61** | 1.36 | 13.4 | 20.8 | 0.88 | 1.7 s |
| Cubic | droptail 125 KB | qdelay-probe | 0.94 | 0.06 | 1.86 | 13.4 | 20.3 | 0.91 | 5.2 s |
| Cubic | droptail 125 KB | *tcp-cubic* | 0.96 | 0.98 | 0.95 | | | 0.96 | |
| BBR | fq_codel | gcc | 0.29 | 0.79 | 1.14 | 5.8 | 26.8 | 0.78 | 5.1 s |
| BBR | fq_codel | **gcc-hybrid** | 0.88 | **0.88** | 1.06 | 2.0 | 4.7 | 0.87 | 6.2 s |
| BBR | fq_codel | qdelay-probe | 0.88 | 0.92 | 1.01 | 4.2 | 20.4 | 0.90 | 1.4 s |
| BBR | fq_codel | *tcp-cubic* | 0.93 | 0.91 | 0.94 | | | 0.95 | |
| BBR | droptail 500 KB | gcc | 0.29 | 0.26 | 1.62 | 19.5 | 35.8 | 0.13 | – |
| BBR | droptail 500 KB | **gcc-hybrid** | 0.85 | **0.29** | 1.62 | 23.8 | 43.0 | 0.88 | 2.1 s |
| BBR | droptail 500 KB | qdelay-probe | 0.90 | 0.04 | 1.83 | 6.4 | 21.7 | 0.85 | 6.3 s |
| BBR | droptail 500 KB | *tcp-cubic* | 0.94 | 0.77 | 1.09 | | | 0.93 | |
| BBR | droptail 125 KB | gcc | 0.29 | 0.41 | 1.43 | 17.6 | 24.4 | 0.32 | 13.8 s |
| BBR | droptail 125 KB | **gcc-hybrid** | 0.88 | **0.25** | 1.60 | 11.5 | 23.5 | 0.87 | 2.1 s |
| BBR | droptail 125 KB | qdelay-probe | 0.92 | 0.13 | 1.70 | 6.0 | 20.8 | 0.92 | 4.0 s |
| BBR | droptail 125 KB | *tcp-cubic* | 0.93 | 0.65 | 1.16 | | | 0.94 | |

Stock `gcc` reads 0.29 alone because it never finishes ramping in 20 s, as in S11. Its 0.74–0.79 "share" on fq_codel is mostly that ramp continuing. "util after" for `gcc` at 0.13 means it collapsed and didn't recover within 20 s.

### Capacity steps 25 → 10 → 40 Mbit/s, alone

| bottleneck | ctl | util 25 | util 10 | util 40 | q p50 | q p99 | start | down | peak | drain | up | lost pkts in 5 s after drop | frame p50 / p99 | frames lost |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| fq_codel | gcc | 0.54 | 0.69 | 0.31 | 1.8 | 139.2 | 12.1 s | 500 | 175 | 1.5 s | – | 87 | 7.2 / 55 | 86 |
| fq_codel | **gcc-hybrid** | 0.81 | 0.68 | 0.86 | 1.9 | 16.8 | 0.7 s | 300 | 190 | 0.5 s | 1.8 s | 15 | 13.3 / 124 | 37 |
| fq_codel | qdelay-probe | 0.92 | 0.91 | 0.91 | 3.5 | 30.9 | 0.7 s | 300 | 206 | 0.5 s | 2.1 s | 33 | 19.8 / 107 | 211 |
| droptail 250 KB | gcc | 0.54 | 0.78 | 0.31 | 1.9 | 149.7 | 15.1 s | 500 | 195 | 1.6 s | – | 0 | 7.6 / 152 | 0 |
| droptail 250 KB | **gcc-hybrid** | 0.84 | 0.72 | 0.88 | 1.9 | 16.3 | 0.7 s | 300 | 157 | 0.4 s | 1.8 s | 0 | 13.8 / 87 | 5 |
| droptail 250 KB | qdelay-probe | 0.92 | 0.89 | 0.90 | 3.5 | 31.7 | 0.7 s | 300 | 200 | 0.5 s | 1.8 s | 16 | 20.1 / 154 | 7 |
| droptail 62.5 KB | gcc | 0.55 | 0.74 | 0.30 | 1.9 | 48.1 | 15.1 s | 3100 | 50 | 2.9 s | – | 631 | 7.5 / 50 | 109 |
| droptail 62.5 KB | **gcc-hybrid** | 0.85 | 0.72 | 0.87 | 2.0 | 15.1 | 0.8 s | 500 | 50 | 0.4 s | 1.8 s | 211 | 13.7 / 69 | 24 |
| droptail 62.5 KB | qdelay-probe | 0.93 | 0.92 | 0.94 | 4.2 | 22.7 | 0.8 s | 500 | 50 | 0.5 s | 2.1 s | 269 | 20.0 / 91 | 173 |

Delays in ms unless marked. Frames lost are out of 3600.

Plots (target, received rate, competing TCP and p95 queueing, run 1):

- [Capacity steps on each bottleneck](results/steps.svg)
- [Cubic: fq_codel, droptail 500 KB (`gcc-hybrid`, `qdelay-probe`), and stock GCC in 125 KB](results/cubic.svg)
- [BBR on each bottleneck](results/bbr.svg)

## Findings

1. **Under fq_codel, delay-based control coexists fine.**
   - Each flow gets its own queue, so Cubic's or BBR's queue never reaches our packets.
   - `gcc-hybrid` keeps 0.86–0.88× its fair share at 2 ms queueing p50 and 5–6 ms p95. That's within 0.05–0.08 of what a Cubic flow gets in the same seat.
   - This covers routers with SQM and Linux/OpenWrt Wi-Fi, whose mac80211 queues use fq_codel by default.
2. **Deep droptail with a loss-based or BBR flow is the real gap.**
   - Cubic fills a 500 KB FIFO to 62 ms p50, and every packet we send waits behind it.
   - The drain's give-up works: we aren't driven to zero.
   - But the trendline detector still sees each Cubic sawtooth as overuse and cuts 15% each time. The target slides to 3–5 Mbit/s by the end of the 20 s, for 0.31× fair share.
   - BBRv1 keeps less queue (24 ms p50), but its 1.25× probing gain also reads as overuse: 0.29×.
   - S11's simulated 0.55× against Reno was optimistic.
   - What would fix it: once the drain has given up, a foreign standing queue is known to be there. Hold the gradient detector's decreases to loss and to queue growth beyond that standing level, like libwebrtc's "competing flow" handling. Measured lower bound: a Cubic flow in our seat gets 0.77–1.14×.
3. **Recovery after the competitor leaves can stall below the train estimate's minimum.**
   - In the 500 KB Cubic runs the target fell to about 3 Mbit/s. That's under the 4-packets-per-frame floor (2.9 Mbit/s at 60 fps), so no train estimate exists and nothing jumps the target.
   - Median recovery is 2.1 s, but one run took 16.6 s on GCC's 8%/s ramp (see the Cubic plot).
   - Fix: keep a floor on the target that leaves frames at least 4 packets, or send probe trains of padding when below it.
4. **Under fair queueing, the train estimate measures our share and then locks pacing to it.** See "Answer in short". The cost is 1.8–6.2 s to regain the link after a flow leaves an fq_codel bottleneck. Pacing a frame at about 2× the estimate every 0.5–1 s would let the train see spare capacity.
5. **Stock GCC's loss rule is too weak for shallow buffers.**
   - In a 125 KB FIFO full of Cubic traffic, delay can't grow, so the gradient is flat. Loss sits at about 9%, below the 10% cap, and GCC ramps past the link rate.
   - It took 1.57× its fair share, holding Cubic to 0.32×, at 9% loss and 716 lost frames a minute.
   - libwebrtc pairs the delay estimator with a loss-based estimator (v2) that reacts well below 10%. Our port doesn't have one, and `gcc-hybrid` inherits the gap even though it didn't trigger here.
6. **`qdelay-probe` is out.**
   - Next to TCP on droptail it gets 0.02–0.13× its fair share and recovers in 4–7 s.
   - On fq_codel its 5 ms target sits at CoDel's target, so CoDel drops it: 6× `gcc-hybrid`'s lost frames in the steps runs.
   - It still fills a lone link better (0.91–0.94 vs 0.81–0.88), as in S11.
7. **Capacity-step behaviour matches the simulation.**
   - `gcc-hybrid` cuts below the new capacity in 300–500 ms and drains in 0.4–0.5 s. It reaches 80% in 0.7–0.8 s at startup and 1.8 s after a step up. Queueing is 2 ms p50 and 15–17 ms p99.
   - The p99 is 4–6 ms above the simulation, partly from the emulator's noise floor (1–3 ms p99).
   - The drop transient is set by the buffer:
     - 62.5 KB: 50 ms peak, plus 211 packets dropped.
     - 250 KB: 157 ms.
     - fq_codel: 190 ms, because CoDel waits out its 100 ms interval before it drops.
   - Utilization in the 10 Mbit/s phase is lower (0.68–0.72). At that rate a 4× scene-change frame is 167 KB, over 100 ms on the wire, and each one triggers a cut.

## Caveats

- **Emulated kernel.** The container's kernel has HTB, TBF and FIFO but no fq_codel, netem or fq (checked in `/proc/config.gz`), and there is no KVM. So every run uses QEMU TCG with 4 vCPUs on a stock Ubuntu `6.8.0-149-generic` kernel. The guest mounts the host's root over 9p and uses the same binaries.
  - Noise floor: a fixed 10 Mbit/s stream with no bottleneck shows 0.34 / 0.91 ms queueing p50/p99 in the guest, against 0.04 / 0.15 ms natively.
  - The emulated sender tops out near 65 Mbit/s, so the step scenario was halved. A first pass at 50/20/80 showed the 80 Mbit/s phase sender-bound (sent about 65, target 106) and was discarded.
  - At 50 Mbit/s the sender loses time now and then. The steps' frame-delay numbers at 25 Mbit/s are trustworthy, but in the TCP tables frame p50/p99 (in `table.md`) are inflated: a solo 50 Mbit/s check showed frame p50 22 ms in the guest versus 13 ms natively. Utilization, shares and queueing are what this spike measures.
  - Cross-check: `steps` on 250 KB droptail, with no added delay, run natively on the host kernel (HTB and bfifo exist there) and in the guest. The two agree closely:

    | | util 25/10/40 | q p50 / p99 | peak | drain | frame p50 / p99 |
    | --- | --- | --- | --- | --- | --- |
    | `gcc-hybrid`, native | 0.80 / 0.72 / 0.85 | 1.7 / 13.2 | 168 | 0.4 s | 11.7 / 110 |
    | `gcc-hybrid`, guest | 0.82 / 0.69 / 0.89 | 1.8 / 13.1 | 94 | 0.4 s | 12.6 / 101 |
    | `qdelay-probe`, native | 0.92 / 0.91 / 0.93 | 3.7 / 24.1 | 198 | 0.5 s | 18.8 / 104 |
    | `qdelay-probe`, guest | 0.91 / 0.94 / 0.93 | 3.6 / 26.8 | 200 | 0.5 s | 19.8 / 97 |

    Raw files are in `results/xcheck/`.
- **One competing flow, same RTT, 3 runs.** Real downloads are often several flows, which would take more than one share from us on droptail. Medians of 3 hide some spread; per-run numbers are in `summary.csv`.
- **BBR is v1.** BBRv3 (not in 6.8) is gentler with queues and would likely land between Cubic and our fq_codel numbers.
- **Wired only.** Real Wi-Fi is still S11's pending real run. Linux APs run fq_codel per station in mac80211; many consumer APs don't.
- **`s11net` changes:** the CSV gained per-100 ms `q50_ms` and `q95_ms` columns, and the receiver now switches to a new sender at once instead of after a 3 s idle timeout. A back-to-back run with a new source port otherwise got no feedback.

## Running it

Needs root, Linux, about 2 h of CPU for the full matrix (four cores).

```sh
vm/setup.sh                        # QEMU, Ubuntu 6.8 kernel + modules into /tmp/vm, s11net built for x86_64_v2
scripts/run-all.sh                 # all 9 cells, 3 runs each, into results/raw (one VM boot per cell)
CELLS="cubic,fq_codel" REPS=1 CTLS="gcc-hybrid" scripts/run-all.sh
python3 scripts/analyze.py results/raw results             # summary.csv + table.md
python3 scripts/plot.py out.svg "title" results/raw cubic-fq_codel-gcc-hybrid-r1
# on a kernel that has fq_codel and netem, skip the VM:
SCEN=cubic AQM=fq_codel REPS=1 OUT=/tmp/x bash scripts/matrix.sh
```

Files:

- `scripts/topo.sh`: namespaces, netem and the HTB bottleneck.
- `scripts/matrix.sh`: one (scenario, bottleneck) cell, run inside the guest.
- `scripts/run-all.sh`: the host driver.
- `scripts/noise.sh`: the emulator noise-floor check.
- `vm/`: the kernel, initramfs and QEMU launcher.
