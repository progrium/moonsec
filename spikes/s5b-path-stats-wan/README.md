# Spike S5b: S5 path visibility across a real network

**Question:** S5 passed on loopback with a 300 ms per-path idle timeout. Across a real
NAT and a real internet RTT: does hole punching work and how fast do we go direct, are the
path stats accurate, and does 300 ms cause false path switches?

**Verdict: hole punching and path stats pass; 300 ms detection works, but a false close is
expensive.** Every connection went direct about 0.5 s after dialing, and path RTT and loss
track what the application measures. The idle timeout detects a dead direct path in
~300 ms as on loopback, and a 10-minute soak at 18 Mbit/s had no false switch. But a 300 ms
idle timeout closes the direct path on outages of roughly 200–300 ms, and **once a direct path
closes, iroh takes 9–60 s to punch a new one** (it does not re-punch when a path is
abandoned). So every false close puts the stream on the relay for up to a minute.

## Setup

- **Client:** Jeff's MacBook Pro (M3 Max, macOS) on his home connection, behind a consumer NAT.
- **Host:** macaron-commode, a Linux VM in AWS us-west-2 behind a security group that drops
  unsolicited inbound UDP. So neither side accepts unsolicited UDP and the direct path must
  be hole-punched. The VM's kernel has no `sch_netem`, so added delay and jitter were not
  tested; all results are at the natural RTT of 71–77 ms.
- **Relay:** n0 production relays (`usw1-1.relay.n0.iroh.link`), iroh 1.4.1.
- One binary, two roles (`src/main.rs`):
  - `host` (Linux, root) binds one endpoint per transport config on fixed UDP ports
    (47001 idle 300 / keep-alive 100 ms, 47002 1000/200, 47003 iroh defaults 15 s/5 s),
    streams 1150-byte datagrams to the client, echoes RTT probes, logs path events, polls
    `paths()`/`stats()` every 1 ms and runs tcpdump on its ports. On request it blocks its
    direct UDP port (iptables, both ways), injects random loss on its outgoing direct
    packets, or blacks the port out for N ms. Relay traffic (TLS over TCP) is never touched.
  - `client` dials the host by key + relay URL only (no IP addresses), so every connection
    starts on the relay. It drives the test plan over a control stream, logs path events,
    polls stats every 1 ms, sends a probe every 10 ms and records every media datagram. At
    the end the host ships its logs back, so all data lands on the client.
- `analyze.py <run-dir>` writes `summary.md`. Host and client clocks are aligned from the
  minimum-RTT probes.
- `vm-host.sh` builds and runs the host side under `/tmp/moonsec-spikes`.

Plans: `punch:N` (N fresh connections, time to direct); `full` (block → relay, unblock →
direct, 15 s baseline, 2/5/20% loss for 10 s each, blackouts of 100–600 ms, block, unblock);
`soak:SECS`. Media ran at 200 pkt/s (1.8 Mbit/s) for the `full` runs so the relay was not
saturated, and at 2000 pkt/s (18 Mbit/s) for the first run and the soak.

## Results

| Measurement | idle 300 | idle 1000 | default (15 s) |
| --- | --- | --- | --- |
| Hole punch success | 10/10 trials + 4/4 runs | 1/1 | 1/1 |
| Dial → connected (on relay) | 301–310 ms | | |
| **Dial → Selected(direct)** | **528–549 ms** | 528 ms | 533 ms |
| **Direct blocked → Closed(direct) + Selected(relay)** | **295–377 ms** (4 blocks) | 995–1035 ms | 15.0 s |
| Longest media gap on block | 301–323 ms | 1012 ms | 15.0 s |
| Blackouts that closed the direct path | 200, 400 (run 1)¹; 300, 400, 600 (run 2) | none up to 600 ms | none up to 600 ms |
| 20% random loss closed the direct path | once in 2 runs (1.7 s in) | no | no |
| **Unblock → Selected(direct) again** | **9.4, 15.0, 17.0, 18.4 s; 8.6, ~60, ~60 s after blackouts** | 48.2, >12 s | 17.6, >1.3 s² |
| Selected(direct) after the first direct packet on the wire | ~150 ms (host), 2 RTTs | same | same |
| False switches in 10 min soak, 18 Mbit/s, 76 ms RTT | 0 | | |
| Path RTT (stats) vs probe RTT, p50, unqueued | 72.0 vs 72.1 ms; soak 76.2 vs 76.7 ms | 71.7 vs 71.7 ms | 72.2 vs 72.4 ms |
| `lost_packets` vs injected 2 / 5 / 20% | 1.3–1.7 / 3.9–6.7 / 15–23% | 1.7 / 3.9 / 18.7% | 2.1 / 5.0 / 22.1% |
| `paths()` + `stats()` poll p50 / p99 | 3.7–5.7 / 194–580 µs | 3.9 / 202 µs | 4.7 / 228 µs |

¹ In run 1 the other blackouts landed while the stream was still on the relay after an
earlier false close, so they tested nothing; run 2 waited for direct before each blackout.
² The run ended before the path came back.

Raw logs: `results/*/` (summary, events, command marks with host apply times, gzipped
probes). The very first run (`wan-full-idle300`, 18 Mbit/s) had a reply-parsing bug that
shifts its blackout windows; its block, unblock and relay numbers are fine.

## Findings that matter for the design

1. **Hole punching through two NATs works, and fast.** Dialed by key and relay URL only,
   every connection went direct 0.53–0.55 s after dialing, about 230 ms after the relay
   connection came up. This is with an AWS security group that drops unsolicited inbound
   UDP, so it is a real two-sided punch, not a reachable server.
2. **Events are still prompt; the "within 1 ms" from S5 becomes "within 2 RTTs".** Selected
   lands ~150 ms after the first direct packet (path validation round trips at 75 ms RTT).
   Closed lands at the idle timeout, as on loopback.
3. **Re-punching after a close is the real problem.** After a direct path is abandoned,
   iroh 1.4.1 does not try again until something triggers it: its 60 s
   `UPGRADE_INTERVAL` check (only when the best IP path is above 10 ms RTT), a change in
   address candidates, or a major network change; attempts are also rate-limited to one per
   5 s (`remote_state.rs`). We measured 9–60 s. Calling the public `Endpoint::network_change()`
   right after the close (`S5B_KICK=1`) did not help, since nothing actually changed. On
   loopback S5 saw 110 ms because the path had never been abandoned.
4. **300 ms is right for detection but too tight to survive common outages.** At 72–77 ms RTT
   the 300 ms idle timeout closed the direct path on blackouts of 200–300 ms and above, and
   once under 20% loss. With finding 3, a 300 ms Wi-Fi stall can cost up to a minute on the
   relay. 1000 ms survived every blackout up to 600 ms and all loss levels. Steady traffic
   on a healthy path never closed it: 0 false switches in the 10-minute soak.
5. **Path stats are accurate for what they measure.** Path RTT matched probe RTT to within
   about 0.5 ms, and `lost_packets` tracked injected loss within sampling error. But path RTT
   is network RTT only: when random loss collapsed the congestion window, probe RTT rose to
   1–4.4 s (datagrams waiting in iroh's send buffer, the default size here) while the path
   RTT still read 72 ms. The core's latency signal must include its own queue and the shim's
   buffer, not just `stats().rtt`. The relay path's RTT does include relay queueing (next
   point).
6. **The n0 relay carried about 8 Mbit/s.** At 18 Mbit/s offered over the relay, the relay
   path delivered ~8 Mbit/s and its RTT rose to 2–3 s, which also slowed hole-punch signalling.
   At 1.8 Mbit/s it stayed at 75 ms. Relay mode must cap the bitrate well below that (the
   design already caps it; this gives a number for the public relays).
7. **A stalled sender also closes the path.** At the end of the soak, the host stalled for
   a few hundred ms building a 180 MB log blob, and the client closed the direct path. That
   was a harness artifact, but it shows any network-thread stall longer than the idle timeout
   switches paths, which is another argument for the pinned network thread from S4 and S10.

## Limits

- One NAT pair and one RTT (~75 ms). No added delay or jitter: the VM kernel has no netem, and
  the Mac needs sudo for dummynet. Long-RTT paths (150–300 ms) are untested, and there
  300 ms would be tighter still.
- One run per config for idle 1000 and default, two for idle 300 at 1.8 Mbit/s.
- The relay throughput is one relay at one time of day.
