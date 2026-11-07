# Spike S5: iroh path visibility

**Question (design doc, S5):** can we see direct vs relayed path and per-path RTT/loss from iroh?
**Pass:** path changes and stats arrive within 100 ms.

**Verdict: pass, with one required config change.** iroh 1.4.1 exposes everything we need
through public API, and events arrive within about 1 ms of the change on the wire. The
one gap is *detecting* a dead direct path: with iroh's defaults that takes 15 s, during
which datagrams are silently lost and no stat moves. Lowering the per-path idle timeout
fixes it (300 ms tested clean), and the shim must set it.

## What iroh gives us (no patching needed)

All public in `iroh` 1.4.1 (`noq` 1.4.0 underneath):

| Need | API |
| --- | --- |
| Path change events | `Connection::path_events()` → `PathEvent::{Opened, Selected, Closed, Lagged}`, each with `PathId` and `remote_addr` |
| Direct vs relayed | `TransportAddr::is_relay()` / `is_ip()` on the event, `Path::is_relay()` on the snapshot |
| Per-path stats | `Connection::paths()` → `Path::stats()` → `PathStats { rtt, cwnd, sent_packets, lost_packets, lost_bytes, congestion_events, bandwidth_estimate, udp_tx/rx, ... }` |
| Final stats of a closed path | `PathEvent::Closed { last_stats }` |
| Failure detection knobs | `QuicTransportConfig::builder().default_path_max_idle_timeout(..)` (max 15 s) and `.default_path_keep_alive_interval(..)` (max 5 s) |
| Custom selection policy | `Builder::path_selector(..)`, behind the `unstable-custom-transports` feature |

So the doc's fallback ("patch shim to expose noq path stats") is not needed.

## Method

`src/main.rs` runs one process on Linux (root, for iptables and tcpdump):

- local iroh relay (`iroh::test_utils::run_relay_server`), host and client endpoints bound to
  `127.0.0.1:47001` and `:47002`; the client dials the host by key with only the relay address;
- client sends 1150-byte datagrams at 2000 pkt/s (~18 Mbit/s) the whole time;
- both sides log `path_events()`; a thread polls `paths()`/`stats()` every 1 ms (as a shim would);
- `tcpdump -i lo` gives the wire-level ground truth for when traffic really moved.

Phases, driven by iptables on the two UDP ports:

- **A relay forced:** direct UDP dropped, connection comes up over the relay (4 s).
- **B direct allowed:** rule removed; hole punch upgrades to direct.
- **C loss on direct:** every 20th direct packet dropped (5%) for 4 s.
- **D direct broken:** direct UDP dropped again; watch fallback to relay.

Run: `cargo build --release && sudo ./target/release/s5-path-stats results/<name>`;
`S5_PATH_IDLE_MS` and `S5_PATH_KEEPALIVE_MS` set the per-path idle timeout and keepalive.

## Results

Four runs (default config, then idle/keepalive of 1000/200, 300/100 and 150/50 ms).
Summaries and event logs are in `results/*/` (`summary.md`, `events.csv`, `marks.csv`).

| Measurement | default | idle 1000 | idle 300 | idle 150 |
| --- | --- | --- | --- | --- |
| A: only relay path open, 0 direct packets on wire | yes | yes | yes | yes |
| B: unblock → first direct packet on wire | 114 ms | 110 ms | 112 ms | 110 ms |
| B: **Opened/Selected(direct) event after first direct packet** | **0.5 ms** | **0.6 ms** | **0.6 ms** | **0.5 ms** |
| B: Selected event vs first media datagram on direct | +0.3 ms | +0.4 ms | +0.6 ms | +0.4 ms |
| B: longest receiver gap during switch | n/a¹ | 2.3 ms | 2.5 ms | 2.4 ms |
| C: loss on → first `lost_packets` increment | 0.4 ms | 0.2 ms | 0.9 ms | 12.7 ms |
| C: measured loss (injected 5% on shared counter) | 3.6% | 4.4% | 4.4% | 4.4% |
| C: relay path `lost_packets` (TCP underneath) | 0 | 0 | 0 | 0 |
| D: **block → Closed(direct) + Selected(relay)** | **15 000 ms** | **999 ms** | **300 ms** | **148 ms** |
| D: Selected(relay) event vs first media on relay | −0.3 ms | −0.2 ms | −0.3 ms | −0.2 ms |
| D: longest receiver gap (media outage) | ~15 s¹ | 999 ms | 300 ms | 149 ms |
| `paths()` + `stats()` poll cost p50 / p99 | 5.8 / 76 µs | 5.5 / 99 µs | | |

¹ Gap tracking was added after the default run; the event and wire timings show the same 15 s outage.

### Against the pass criteria

- **Direct vs relayed is visible:** pass. Both paths are open at once with separate `PathId`s and
  separate stats; `is_relay()` is exact.
- **Per-path RTT:** pass. Live per path from `stats().rtt`; the relay path keeps its own RTT while
  direct is selected.
- **Per-path loss:** pass for a lossy path (counter moves within ~1 ms of the first drop at this
  rate). Relay paths report 0 loss, as expected over TCP, so relay degradation shows up as RTT, not loss.
- **Path change events within 100 ms:** pass. Every event landed within 1 ms of the change on the
  wire, on both ends, and `Selected` is emitted before or with the first packet on the new path.
- **Path failure within 100 ms:** fails on defaults (15 s), 148 ms at the 150 ms floor we tried.
  Detection time equals the per-path idle timeout, so "within 100 ms" is only reachable by setting it
  below 100 ms, which is too tight for internet RTTs. See below.

## Findings that matter for the design

1. **A blackholed direct path is invisible in stats until the idle timeout.** During D,
   `lost_packets` and `rtt` froze and `send_datagram` kept returning `Ok`; only `sent_packets` stalled
   (PTO probes only). Datagrams in that window are dropped silently, which also bears on S2's
   "every drop visible in stats". The shim must set `default_path_max_idle_timeout` (proposal: 300 ms,
   keepalive 100 ms) instead of iroh's 15 s / 5 s, and expose a "no ack progress" signal (for
   example `sent_packets` frozen while we are sending) so the core can drop to keyframe-only or show
   the stall before iroh switches.
2. **A low idle timeout did not cause flapping** in these runs: no spurious `Closed` during 5%
   loss at 150 ms idle. On loopback RTT is ~0.1 ms, so this needs a re-check at internet RTTs
   (idle timeout should stay several RTTs; 300 ms is a reasonable start for RTT under 100 ms).
3. **Events are push, stats are pull.** The shim should forward `path_events()` to Zig as events
   and sample `stats()` for the selected path on the network thread (5–6 µs per poll, p99 under
   0.1 ms with two paths). `PathEvent::Lagged` exists if the shim falls behind (broadcast capacity 8);
   on `Lagged` it should re-read `paths()`.
4. **Upgrade timing is iroh's punch schedule, not event delay.** The ~110 ms between unblocking and
   the first direct packet is when iroh next tried the path; the event follows the packet by <1 ms.
5. **Policy hook exists.** `Builder::path_selector` lets us own path choice (e.g. prefer a stable
   path over lowest RTT), but it is behind `unstable-custom-transports`.

## Limits of this spike

- Loopback only; "allow hole punch" is emulated by iptables, not a real NAT. Real NAT timing and
  hole-punch success rates are not measured here.
- This container's kernel has no `netem`, so RTT tracking under changing delay was not tested.
  Running the same binary on a VM with `tc netem` on the direct ports would cover that.
