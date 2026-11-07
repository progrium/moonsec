# S11: capacity estimation and rate control

**Question.** The design paces every path at "the core's capacity estimate" (S2) and runs a GCC-style delay-gradient controller on our own one-way delay timestamps. Nothing had tested that estimate. How accurately and how fast does it track link capacity, and how much queueing delay builds up, with Wi-Fi-like jitter and cross traffic?

**Status (Nov 7, 2026): simulation done; the real Wi-Fi run is pending.** The real-network harness (`s11net`) is written and passes loopback tests, but it needs a far-end receiver. Running one on macaron-commode needs inbound UDP opened there, which is waiting for Jeff's OK.

## Answer in short

- **Stock GCC can't drive pacing on its own.** The libwebrtc delay-based estimator, with no probe controller, holds only 24–35% of available capacity in every scenario. Its 8%/s multiplicative ramp takes over 20 s to fill a 50 Mbit/s link, and it never reaches 80% of capacity in most runs. After a 50→20 Mbit/s drop, it leaves 40–70 ms p95 queueing for about 4 s. A delay *gradient* can't see a queue that has stopped growing.
- **Frame trains are a free, accurate capacity probe.** Each frame is a packet train. When it is paced faster than the bottleneck, the receive dispersion gives the bottleneck rate. The median over 300 ms reads 1.00× link capacity on wired links and 1.01–1.02× on simulated Wi-Fi, if the frame has at least 4 packets. With cross traffic it reads 0.53–0.76× the link rate, which is between the link rate and our fair share.
- **What works is GCC plus two additions (`gcc-hybrid`).**
  - The frame-train estimate sets the pacing rate, and it lets the target jump up, the job WebRTC's padding probes do.
  - An absolute standing-queue check catches what the gradient misses. It compares the minimum OWD over the last 20 ms with the 10 s minimum. Above 30 ms for 150 ms, it cuts the rate to drain the queue in about 200 ms. If the queue doesn't fall within 1.5 s, the check stops for 10 s, because a loss-based flow is filling it.
- **Results (median of 5 seeds):**

  | | wired 20 ms RTT | simulated Wi-Fi |
  | --- | --- | --- |
  | Target / available, steady state | 0.86 | 0.74–0.76 |
  | Time to 80% of capacity at startup | 1.6 s | 1.3–1.6 s |
  | Time to 80% after a 20→80 Mbit/s step up | 1.7 s | 1.6–1.8 s |
  | Target below new capacity after a drop | 300 ms | 300 ms |
  | Queue drained after a drop (p95 < 20 ms) | 0.7–0.9 s | 1.7 s (then stalls set the p95) |
  | Queueing delay p50 / p99 | 2.1 / 10.8 ms | 3.6 / 45–53 ms |

  For comparison, stock GCC drains in 4.2 s.
- **Remaining costs:**
  - The 300 ms before the cut, while pacing still follows the old capacity, fills the 500 KB AP buffer, so a big capacity drop still peaks at 170–200 ms queueing.
  - A Reno flow on the same link holds us to 55% of our fair share.
  - Simulated Wi-Fi stalls set the p99.
- **Frame delay comes from utilization, not from the estimator.** At 88% of capacity, a 60 fps frame needs ~15 ms on the wire whatever the pacing. Frame p50 is 16 ms with `gcc-hybrid` versus 6.6 ms with stock GCC, which only runs at a third of capacity. Running the encoder at 60% of the target (`gcc-hybrid-enc60`) cuts frame p50 to about 10 ms and p99 by 25–45%. The controller must then know the share, or it reads the app-limited acked rate as a smaller link and spirals down. A first try did exactly that and got 2% utilization under TCP.
- **Rejected options:**
  - Pacing at the encoder target (`gcc-x1`) gives 0.5–1.4 s frame delays, because the scene-change frames back up in the pacer. This confirms S2.
  - Turning off GCC's burst grouping halves Wi-Fi throughput, because aggregation bursts look like overuse.
  - The queue-delay-target controller (`qdelay-probe`) gets 4–8 points more utilization. In exchange it has 2–3× the p99 queueing on wired links and more lost frames.

## Setup

Everything is Zig 0.16 and deterministic per seed. `src/est.zig` is sans-I/O and shared by the simulator and the real-network harness.

- **Sender.** 60 fps video; frame size = target/60 × lognormal(σ 0.25) and a 4× scene-change frame every 3 s; 1200-byte packets; a pacer with 2 ms of burst credit.
- **Bottleneck.** A FIFO with a 500 KB droptail buffer and a per-packet serialization time at the current capacity.
  - **Wi-Fi model.** Packets leave the radio in A-MPDU-like batches at random 0.5–4 ms boundaries. The radio also stalls for 5–60 ms (uniform) at exponential intervals with a 2 s mean, which costs about 1.6% of airtime. The model is synthetic and not calibrated; the real run is meant to check it.
- **Receiver.** Transport-wide feedback every 5 ms with per-packet arrival times. The receive clock has a fixed 987 s offset, to prove only OWD differences are used. Feedback gets 0–2 ms of reverse jitter on Wi-Fi.
- **Cross traffic.** On/off CBR UDP, one Reno flow, or 300 KB line-rate bursts.
- **Scenarios** (60 s each, 5 seeds):

  | Scenario | Capacity | RTT | Notes |
  | --- | --- | --- | --- |
  | `wired-steps` | 50 → 20 (t=20 s) → 80 (t=40 s) Mbit/s | 20 ms | |
  | `wired-60ms` | same steps | 60 ms | |
  | `wifi-steps` | same steps | 20 ms | Wi-Fi model |
  | `wifi-lan` | 100 → 40 → 150 Mbit/s | 2 ms | LAN streaming |
  | `wifi-fade` | random 25–120 Mbit/s every 2–5 s | 20 ms | MCS changes |
  | `wifi-udp-cross` | 80 Mbit/s | 20 ms | 40 Mbit/s on/off UDP, 4 s mean periods |
  | `wifi-tcp` | 50 Mbit/s | 20 ms | Reno from 20 s to 40 s |
  | `wifi-bursts` | 50 Mbit/s | 20 ms | 300 KB bursts every 2 s on average |

- **Variants:**

  | Variant | Controller | Pacing | Extras |
  | --- | --- | --- | --- |
  | `gcc` | libwebrtc delay-based GCC: InterArrivalDelta (5 ms groups, burst grouping), TrendlineEstimator (window 20, smoothing 0.9, gain 4), adaptive threshold (k_up 0.0087, k_down 0.039), AIMD (β 0.85, 8%/s, additive near link capacity), loss cap above 10% loss | 2.5× target, as WebRTC does | |
  | `gcc-x1` | GCC | at the target (the encoder rate) | |
  | `gcc-train` | GCC | frame-train estimate | |
  | `gcc-nogroup` | GCC without burst grouping | 2.5× target | |
  | `gcc-ramp` | GCC with a blind startup that doubles every 100 ms until the first overuse | 2.5× target | |
  | `gcc-probe` | GCC | frame-train estimate | Target jumps to 0.85 × train estimate, at most 3× and once per 500 ms, only in increase state and not within 2 s of a decrease |
  | `gcc-hybrid` | GCC | frame-train estimate | `gcc-probe` plus the standing-queue drain (30 ms threshold, 150 ms hold, 1.5 s give-up) |
  | `gcc-hybrid-nohold` | GCC | frame-train estimate | Drain without the hold and the give-up |
  | `gcc-hybrid-enc60` | GCC | frame-train estimate | `gcc-hybrid` with the encoder at 60% of the target |
  | `qdelay` | Queue-delay target, LEDBAT/SCReAM-style: standing queue → 5 ms target, +50%/s max, drain cut when the queue is over 4× target | 2.5× target | |
  | `qdelay-probe` | `qdelay` with the frame-train jump | frame-train estimate | |

- **Metrics.**
  - Accuracy: target / available over steady 100 ms samples, meaning 5 s after a change (1 s for `wifi-fade`, 2 s for UDP cross traffic). Available = capacity × (1 − stall duty) − cross UDP, or half of that while TCP runs (fair share).
  - Queueing: per-packet network delay above propagation, after the first 5 s.
  - Frame delay: capture to the last packet of the frame, minus propagation.
  - Step reaction: time until the target is at or below the new available capacity.
  - Drain: time until 100 ms-window p95 delay stays under 20 ms.

## Results

Median across 5 seeds. Abbreviations:

- **est**: target / available.
- **util**: media goodput / available.
- **train**: frame-train estimate / link capacity.
- **q**: per-packet queueing delay.
- **frame**: per-frame transport delay.
- **lost**: lost frames out of ~3300.
- **start**: time to 80% of available capacity.
- **down**: target below the new capacity after the drop.
- **peak**: peak p95 delay after the drop.
- **drain**: time until the queue drains after the drop.
- **up**: time to 80% after the step up.

Full table for all variants: [`results/matrix/table.md`](results/matrix/table.md). Raw per-run numbers: `results/matrix/summary.csv`. Per-100 ms timeseries for seed 1: `results/matrix/<scenario>-<variant>.csv`.

| scenario | variant | est | util | train | q p50 | q p99 | frame p50 | frame p99 | lost | start ms | down ms | peak ms | drain ms | up ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| wired-steps | gcc | 0.35 | 0.36 | 1.00 | 1.5 | 35.1 | 6.6 | 42.2 | 0 | 20000 | 200 | 72 | 4200 | – |
| wired-steps | gcc-probe | 0.86 | 0.88 | 1.00 | 2.1 | 143.6 | 16.4 | 195.9 | 12 | 1600 | 500 | 200 | 2500 | 1700 |
| wired-steps | **gcc-hybrid** | 0.86 | 0.88 | 1.00 | 2.1 | 10.8 | 15.9 | 95.5 | 2 | 1600 | 300 | 200 | 800 | 1700 |
| wired-steps | gcc-hybrid-enc60 | 1.14 | 0.68 | 1.00 | 3.3 | 41.7 | 10.5 | 79.5 | 3 | 600 | 500 | 181 | 700 | 1200 |
| wired-steps | qdelay-probe | 0.92 | 0.96 | 1.00 | 3.6 | 26.6 | 19.5 | 108.7 | 5 | 1600 | 300 | 200 | 800 | 1800 |
| wired-60ms | gcc | 0.33 | 0.33 | 1.00 | 1.3 | 38.9 | 6.5 | 50.3 | 0 | 20000 | 300 | 72 | 4300 | – |
| wired-60ms | **gcc-hybrid** | 0.86 | 0.88 | 1.00 | 2.1 | 13.3 | 15.7 | 98.8 | 6 | 1700 | 300 | 200 | 900 | 1800 |
| wifi-steps | gcc | 0.32 | 0.32 | 0.97 | 2.9 | 35.6 | 7.7 | 44.9 | 0 | 20000 | 200 | 42 | 4100 | – |
| wifi-steps | gcc-nogroup | 0.16 | 0.16 | 0.58 | 2.2 | 24.8 | 6.2 | 33.9 | 0 | – | 100 | 50 | 2000 | – |
| wifi-steps | gcc-probe | 0.78 | 0.79 | 1.01 | 3.6 | 96.3 | 14.5 | 151.6 | 5 | 1300 | 500 | 194 | 4400 | 2200 |
| wifi-steps | **gcc-hybrid** | 0.74 | 0.73 | 1.02 | 3.6 | 53.0 | 13.7 | 82.7 | 1 | 1300 | 300 | 112 | 1700 | 1800 |
| wifi-steps | gcc-hybrid-enc60 | 0.96 | 0.56 | 1.02 | 3.7 | 41.3 | 10.4 | 56.7 | 0 | 1200 | 400 | 101 | 3900 | 1600 |
| wifi-steps | qdelay-probe | 0.85 | 0.86 | 1.02 | 4.4 | 54.3 | 16.8 | 104.2 | 5 | 1200 | 300 | 193 | 4300 | 2100 |
| wifi-lan | gcc | 0.24 | 0.24 | 0.90 | 2.6 | 36.5 | 7.3 | 42.3 | 0 | – | 100 | 46 | 4200 | – |
| wifi-lan | **gcc-hybrid** | 0.75 | 0.76 | 1.02 | 3.6 | 47.8 | 14.2 | 78.9 | 23 | 1600 | 300 | 103 | 4300 | 1600 |
| wifi-lan | qdelay-probe | 0.89 | 0.91 | 1.02 | 4.5 | 45.9 | 17.6 | 80.8 | 25 | 2100 | 300 | 103 | 4300 | 1700 |
| wifi-fade | gcc | 0.34 | 0.34 | 0.99 | 2.9 | 38.4 | 7.3 | 44.2 | 0 | 24800 | – | – | – | – |
| wifi-fade | **gcc-hybrid** | 0.76 | 0.75 | 1.01 | 3.5 | 91.1 | 13.8 | 98.2 | 31 | 1700 | – | – | – | – |
| wifi-fade | gcc-hybrid-enc60 | 0.98 | 0.59 | 1.01 | 4.0 | 63.7 | 10.9 | 74.7 | 12 | 1200 | – | – | – | – |
| wifi-udp-cross | gcc | 0.29 | 0.27 | 0.53 | 2.4 | 36.7 | 6.4 | 39.5 | 0 | 35900 | – | – | – | – |
| wifi-udp-cross | **gcc-hybrid** | 0.68 | 0.70 | 0.68 | 3.6 | 51.6 | 11.4 | 63.1 | 62 | 1600 | – | – | – | – |
| wifi-udp-cross | gcc-hybrid-enc60 | 0.95 | 0.59 | 0.67 | 3.5 | 49.8 | 9.8 | 55.9 | 7 | 1200 | – | – | – | – |
| wifi-tcp | gcc | 0.28 | 0.28 | 0.65 | 3.1 | 75.4 | 7.9 | 82.9 | 5 | 20000 | – | – | – | – |
| wifi-tcp | gcc-hybrid-nohold | 0.07 | 0.06 | 1.01 | 3.7 | 64.0 | 15.5 | 77.4 | 2 | 1300 | – | – | – | – |
| wifi-tcp | **gcc-hybrid** | 0.55 | 0.55 | 0.99 | 3.8 | 65.0 | 17.9 | 87.3 | 4 | 1300 | – | – | – | – |
| wifi-tcp | gcc-hybrid-enc60 | 0.85 | 0.50 | 0.99 | 4.2 | 67.2 | 13.8 | 85.3 | 4 | 1200 | – | – | – | – |
| wifi-bursts | gcc | 0.32 | 0.33 | 0.99 | 2.8 | 43.1 | 6.9 | 48.9 | 0 | – | – | – | – | – |
| wifi-bursts | gcc-hybrid-nohold | 0.34 | 0.35 | 1.00 | 3.4 | 53.7 | 7.7 | 63.7 | 0 | 3400 | – | – | – | – |
| wifi-bursts | **gcc-hybrid** | 0.57 | 0.57 | 1.02 | 3.6 | 62.6 | 11.2 | 78.5 | 2 | 3400 | – | – | – | – |

For `gcc-hybrid-enc60`, est is the target, which now acts as a capacity estimate. util is what the encoder actually sends.

Timeseries plots (SVG): [wired steps](results/wired-steps.svg), [Wi-Fi steps](results/wifi-steps.svg), [Wi-Fi with a Reno flow](results/wifi-tcp.svg).

## Findings

1. **Stock GCC under-runs badly.** It reaches 24–35% of available capacity in every scenario.
   - Without WebRTC's probe controller, it climbs at 8%/s and backs off at every scene-change frame.
   - Even WebRTC's 2.5× pacing pushes a 4× frame into the bottleneck faster than it drains, the trendline sees a rising gradient, and GCC cuts to 0.85 × acked.
   - It never reaches the link within 20 s.
2. **Frame dispersion measures capacity.**
   - Paced faster than the bottleneck, each frame's packets leave the bottleneck back to back. A 300 ms median of (bytes after the first packet) / (last arrival − first arrival) reads 1.00× capacity on wired links and 1.01–1.02× on simulated Wi-Fi. Aggregation batching biases it slightly high.
   - It needs at least 4 packets per frame, about 2.9 Mbit/s at 60 fps.
   - It measures the link, not our share. Under cross traffic it reads 0.53–0.76× the link rate, so it's right for pacing but can't be the target.
3. **Paced at the train estimate, the queue shrinks.** With `gcc-train` versus `gcc`, wired q p99 falls from 35 to 10 ms. Pacing at the encoder rate (`gcc-x1`) is unusable: frames back up in the pacer for 0.5–1.4 s.
4. **A gradient detector can't see a standing queue.**
   - After 50→20 Mbit/s, GCC cuts once to 0.85 × acked. The acked window still holds pre-drop rates, so the cut leaves 40–60 ms of queue.
   - Once the queue stops growing, the gradient is zero and GCC goes back to increase.
   - With the train jump alone (`gcc-probe`), the buffer stays full for 2.5 s (q p99 144 ms wired).
   - The absolute standing-queue drain fixes this: queue drained in 0.7–0.9 s, wired q p99 10.8–13.3 ms.
5. **The drain needs a hold and a give-up.**
   - Without them (`-nohold`), a Reno flow keeps the queue full and the drain starves us: 0.07 of fair share instead of 0.55. Line-rate bursts also halve throughput: 0.34 instead of 0.57.
   - With them, simulated Wi-Fi stalls (≤ 60 ms) and bursts pass without a cut, and a persistent foreign queue switches the drain off for 10 s.
6. **Burst grouping is mandatory on Wi-Fi.** Without libwebrtc's burst grouping, aggregation looks like delay growth and halves the rate (0.16 vs 0.32).
7. **The reaction floor is ~300 ms.** In that time, pacing at the old capacity fills a 500 KB buffer, which peaks at 170–200 ms for a 2.5× capacity drop.
   - Faster detection would need the train estimate to drop pacing as soon as dispersion widens. It reads the new capacity within 300 ms (see the plots), but its median window lags.
   - A shallower AP buffer lowers the peak.
8. **Frame delay trades against utilization.** Because pacing follows the link capacity, a frame's transport time ≈ (encoder rate / capacity) × 16.7 ms.
   - At 88% utilization: frame p50 15.9 ms. At about 60%: about 10 ms.
   - For games, the encoder should run below the target. The controller must know that share (`app_share`), or the acked-rate rules read the stream as app-limited and spiral down.
9. **qdelay versus gcc-hybrid.**
   - The queue-delay controller fills the link better (0.85–0.92) and coexists with Reno a little better (0.68 vs 0.55).
   - It keeps its 5 ms target standing, so wired q p99 is 2.5× higher (26.6 vs 10.8 ms) and frame p99 is higher.
   - Both are worth keeping in the core behind one interface until real Wi-Fi data picks one.

## Caveats

- **Simulation only so far.** The Wi-Fi model is a guess, and its stalls set the Wi-Fi p99 numbers. The real run will check whether real Wi-Fi has stalls like that.
- **The bottleneck is one droptail queue.** There are no AQM/fq_codel cases. Under fq_codel, cross traffic wouldn't share our queue, and the competition results would look better.
- **The TCP flow is a minimal Reno.** Cubic and BBR would differ. Coexistence is a real gap: about 55% of fair share.
- **The capacity estimate has a minimum frame size.** Below about 3 Mbit/s at 60 fps (fewer than 4 packets per frame), there is no train estimate, and pacing falls back to 2.5× target.
- Parameters (30 ms drain threshold, 150 ms hold, 1.5 s give-up, 0.85 jump factor, 2 s jump gate) were tuned by hand on these scenarios. They are a starting point, not a result.

## Real Wi-Fi run (pending)

The plan: this MacBook Pro (M3 Max, 802.11ax, 5 GHz ch 132 at 80 MHz, −34 dBm, 1200 Mbit/s PHY) streams over Wi-Fi to a receiver on macaron-commode.

- Run `fixed` floods to bracket capacity, then each controller for 60 s.
- Midway through, add cross traffic from the same Wi-Fi client.
- Record target versus flood-measured capacity, queueing p50/p99 (OWD minus the ±5 s minimum, to absorb clock drift), frame delay and losses. macOS `ENOBUFS` from the Wi-Fi interface queue is counted separately.

This needs Jeff's OK to run a receiver on macaron-commode with inbound UDP open for about an hour.

## Running it

```sh
zig build --release=fast                     # zig-out/bin/s11sim, zig-out/bin/s11net
zig build test
./zig-out/bin/s11sim --seeds 5 --out results/matrix          # ~3 s for the whole matrix
./zig-out/bin/s11sim --scen wifi-steps --variant gcc-hybrid --seeds 1 --out /tmp
python3 scripts/table.py results/matrix/summary.csv gcc gcc-hybrid   # medians across seeds
python3 scripts/plot.py out.svg "title" results/matrix/wifi-steps-gcc-hybrid.csv

# real network
./zig-out/bin/s11net recv --port 9711                        # far end (or src/recv.zig, standalone)
./zig-out/bin/s11net send --to IP:9711 --ctl gcc-hybrid --seconds 60 --csv run.csv --tag wifi
./zig-out/bin/s11net send --to IP:9711 --ctl fixed --mbps 300 --seconds 5      # capacity flood
```

Files:

- `src/est.zig`: the estimators and controllers (sans-I/O): `Gcc`, `QDelay`, `TrainCap`, `OwdTracker` and `AckedRate`.
- `src/sim.zig`: the discrete-event simulator, scenarios and variants.
- `src/net.zig`: the UDP harness.
- `src/recv.zig`: the standalone receiver.
- `scripts/`: the median table and the SVG plots.
