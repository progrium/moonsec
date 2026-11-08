# core/rate

The host's rate controller: S11's `gcc-hybrid`
([spikes/s11-capacity-estimation](../../spikes/s11-capacity-estimation/README.md),
design doc "Rate control"). It is libwebrtc's delay-based GCC on our own
one-way delays, with burst grouping, plus two additions:

- **Frame-train capacity estimate** (`TrainCap`). The 300 ms median of each
  frame's receive dispersion measures the bottleneck rate. It sets the pacing
  rate and lets the target jump to 0.85× the estimate when there has been no
  recent decrease (at most 3× per jump, once per 500 ms, not within 2 s of a
  decrease).
- **Standing-queue drain.** When min OWD over 20 ms sits more than 30 ms
  above the 10 s minimum for 150 ms, the rate is cut to drain the queue in
  about 200 ms. If the queue doesn't fall within 1.5 s, a loss-based flow is
  filling it, and the drain switches off for 10 s.

`app_share` is the share of the target the encoder sends. The acked-rate
rules divide by it, so an app-limited stream isn't read as a smaller link.

## API

```zig
const c = try gpa.create(core.rate.Controller); // ~2.5 MB of history: heap it
c.reset(.{ .app_share = 0.6 });                  // defaults are S11's tuning
c.onSent(seq, send_us, size, frame_id, last_of_frame);  // as each packet leaves the pacer
c.onFeedbackMsg(now_us, feedback_view);          // a decoded proto.Feedback
pipe.setPacingRate(@intFromFloat(c.pacingBps()));
encoder.setBitrate(c.encoderBps());              // = app_share × targetBps()
```

`onArrivals` takes (seq, arrival) pairs directly, and `onFeedback` takes
results already joined with send records. `telemetry()` returns estimator
state for logs and the overlay. Everything is sans-I/O and builds for wasm32.

| File | What |
| --- | --- |
| `controller.zig` | `Controller`: joins feedback, runs GCC and the train estimate, outputs the three rates |
| `gcc.zig` | GCC (grouping, trendline, adaptive threshold, AIMD, loss cap), train jump, standing-queue drain |
| `train.zig` | Frame-train capacity estimate |
| `owd.zig` | Standing queue from one-way delays |
| `acked.zig` | Received bitrate over 500 ms |
| `history.zig` | Send records, joined with feedback; gaps count as lost |
| `loop_test.zig` | Closed-loop tests over a small wired bottleneck |

## Checked against S11

1. **On S11's own simulator, bit-exact.** With `core/rate` swapped in for the
   spike's `est.zig`, all 440 runs in S11's matrix (8 scenarios, 11 variants,
   5 seeds) give byte-identical `summary.csv` rows. Driving the full
   `Controller` API (send history, feedback join) is also identical, with one
   deliberate change: the train estimate's 300 ms window ends at the newest
   arrival the host has seen. The spike used the simulator's true client-clock
   "now", which a real host doesn't know. That moves Wi-Fi medians by up to
   0.08 of capacity, in both directions (wifi-steps 0.74 to 0.79, wifi-fade
   0.76 to 0.72); the wired rows don't move.
2. **On the shared sim harness** (`transport/sim.zig`, `sim/rate.zig`). The
   controller drives `PacketPipe`, and feedback travels as encoded
   `proto.Feedback` datagrams. `zig build sim-rate -- --check` runs S11's
   eight scenarios, 5 seeds each, and fails if a median leaves S11's bands.
   CI runs this check. Medians (ours, then S11's):

| scenario | variant | est | util | train | q p50 | q p99 | frame p50 | frame p99 | lost | start ms | down ms | peak ms | drain ms | up ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| wired-steps | gcc-hybrid | 0.86 | 0.89 | 1.00 | 2.2 | 11.8 | 15.9 | 100.1 | 1 | 1100 | 300 | 176 | 700 | 2100 |
| wired-steps | S11 gcc-hybrid | 0.86 | 0.88 | | 2.1 | 10.8 | 15.9 | 95.5 | | 1600 | 300 | | 800 | 1700 |
| wired-60ms | gcc-hybrid | 0.86 | 0.88 | 1.00 | 2.1 | 13.5 | 15.6 | 94.0 | 6 | 1400 | 300 | 200 | 900 | 2600 |
| wired-60ms | S11 gcc-hybrid | 0.86 | 0.88 | | 2.1 | 13.3 | 15.7 | 98.8 | | 1700 | 300 | | 900 | 1800 |
| wifi-steps | gcc-hybrid | 0.78 | 0.80 | 1.02 | 3.6 | 53.9 | 14.4 | 95.4 | 5 | 2900 | 300 | 87 | 4300 | 1800 |
| wifi-steps | S11 gcc-hybrid | 0.74 | 0.73 | | 3.6 | 53.0 | 13.7 | 82.7 | | 1300 | 300 | | 1700 | 1800 |
| wifi-lan | gcc-hybrid | 0.75 | 0.76 | 1.02 | 3.5 | 42.5 | 13.8 | 73.4 | 20 | 1800 | 300 | 102 | 3100 | 1300 |
| wifi-lan | S11 gcc-hybrid | 0.75 | 0.76 | | 3.6 | 47.8 | 14.2 | 78.9 | | 1600 | 300 | | 4300 | 1600 |
| wifi-fade | gcc-hybrid | 0.69 | 0.69 | 1.02 | 3.6 | 71.2 | 13.3 | 96.9 | 32 | 2200 | – | – | – | – |
| wifi-fade | S11 gcc-hybrid | 0.76 | 0.75 | | 3.5 | 91.1 | 13.8 | 98.2 | | 1700 | – | | – | – |
| wifi-udp-cross | gcc-hybrid | 0.71 | 0.73 | 0.74 | 3.7 | 50.9 | 12.4 | 77.7 | 46 | 1600 | – | – | – | – |
| wifi-udp-cross | S11 gcc-hybrid | 0.68 | 0.70 | | 3.6 | 51.6 | 11.4 | 63.1 | | 1600 | – | | – | – |
| wifi-tcp | gcc-hybrid | 0.69 | 0.68 | 1.00 | 3.8 | 73.2 | 20.7 | 107.3 | 5 | 2900 | – | – | – | – |
| wifi-tcp | S11 gcc-hybrid | 0.55 | 0.55 | | 3.8 | 65.0 | 17.9 | 87.3 | | 1300 | – | | – | – |
| wifi-bursts | gcc-hybrid | 0.56 | 0.58 | 1.02 | 3.6 | 53.8 | 11.3 | 72.8 | 1 | 3100 | – | – | – | – |
| wifi-bursts | S11 gcc-hybrid | 0.57 | 0.57 | | 3.6 | 62.6 | 11.2 | 78.5 | | 3400 | – | | – | – |

`gcc-hybrid-enc60` (`app_share` 0.6) is in the same output and within bands too.

Wired rows match within a few percent. On Wi-Fi, accuracy and queueing match
within seed noise, with two differences:

- **Startup on Wi-Fi is slower in 3 of 5 seeds** (2.9 s against S11's 1.3 s
  median). A radio stall during the first jumps reads as overuse, and the
  2 s jump gate after a decrease holds the target there. S11 shows the same
  thing in some of its seeds (up to 3.2 s); here the stall timing lands on
  the ramp more often.
- **Against Reno we get 0.69 of fair share rather than 0.55.** The harness's
  Reno flow is a separate implementation from S11's, so this says more about
  the cross-traffic model than about the controller.

The `drain ms` column on Wi-Fi is dominated by stalls pushing the 100 ms p95
over 20 ms, so it is noisy in S11 too (1.7 to 4.4 s between variants).

```sh
zig build test                                       # unit and closed-loop tests
zig build sim-rate -Doptimize=ReleaseFast             # the table above
zig build sim-rate -Doptimize=ReleaseFast -- --check  # what CI runs
zig build sim-rate -Doptimize=ReleaseFast -- --scenario s11-wifi-tcp --seeds 1 --trace out.csv
```

## Not ported

- S11's queue-delay-target controller (`qdelay`). S11 suggested keeping it
  behind the same interface until the real Wi-Fi run picks one. It is about
  80 lines and can be added when that data is in.
- Resolution and frame-rate steps. This module outputs bitrates only.
