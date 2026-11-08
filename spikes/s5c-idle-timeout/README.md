# Spike S5c: the path idle timeout, 300 ms vs ~1 s, at long RTTs

**Question.** S5b found that a 300 ms per-path idle timeout closes the direct path on
200–300 ms outages, and that iroh 1.4.1 then takes 9–60 s to punch a new one. The choice is
between keeping 300 ms and patching iroh to re-punch right after a close, or moving to about
1 s. This spike gathers data for that choice. It does not make it. It measures both settings
at 75, 150 and 250 ms RTT through two NATs, with stock iroh and with a prototype re-punch
patch.

## Results in short

1. **The setting is a floor, not the timeout.** noq arms the path idle timer at
   `max(idle, 3 × PTO)`. A "300 ms" timeout really closes a dead path after 342 ms at 75 ms RTT,
   606 ms at 150 ms and 955 ms at 250 ms. "1000 ms" closes after 1038, 1076 and 1125 ms. So the
   two settings only differ much on short and medium RTTs. At 250 ms RTT they are within
   about 170 ms of each other.
2. **The re-punch patch fixes the slow recovery, with either setting.** Stock iroh went direct
   again 21–57 s after an outage that closed the path (median ~55 s, which is its 60 s upgrade
   check). With the patch it went direct 0.13–1.07 s after the outage ended (median 0.21–0.71 s
   by RTT). That held for all 92 closes on the patched build, at 300 ms and at 1000 ms.
3. **1 s does not avoid closes. It moves them to outages of 0.8–1 s and longer.** At 1000 ms,
   every outage of 1 s or more closed the path, and on stock iroh that cost 21–56 s on the
   relay, as it does at 300 ms. Wi-Fi roams and AP handoffs are often that long. So the
   re-punch problem stays without a patch. It just happens less often.
4. **At 300 ms the media gap is shorter during an outage, because the relay takes over.** Once
   the path closes, media flows over the relay. So at 300 ms the longest gap is about the
   effective timeout (310 / 530 / 830 ms by RTT) however long the outage lasts. At 1000 ms the
   gap is the outage plus recovery, up to ~1.0–1.2 s. The cost at 300 ms is two path
   switches per outage of 200–400 ms or more, and 0.15–2 s on the relay each time (median
   about 0.5–0.8 s) when patched.
5. **Even a short outage can leave a gap longer than the outage.** After the path comes back,
   the sender's next packet waits for its backed-off PTO probe. A 300 ms outage at 150 ms RTT
   gave a 690 ms gap at the 300 ms setting (the path closed 300 ms after the outage had ended)
   and 340 ms at 1000 ms. This also makes closes non-monotonic in outage length: at 250 ms RTT
   and 300 ms, every 400 ms outage closed the path and every 600 ms outage did not, because a
   probe happened to land just after a 600 ms outage ended.

## The tradeoff, with numbers

Shortest outage that closed the direct path (stock and patched pooled, 6 trials each; "x/6" =
closes):

| RTT | effective timeout at "300" | closes at "300" from | effective timeout at "1000" | closes at "1000" from |
| --- | --- | --- | --- | --- |
| 75 ms | 342 ms | 200 ms (6/6; 100 ms: 0/6) | 1038 ms | 800 ms (6/6; 600 ms: 0/6) |
| 150 ms | 606 ms | 300 ms (5/6; 200 ms: 0/6) | 1076 ms | 800 ms (4/6), 1000 ms (6/6) |
| 250 ms | 955 ms | 400 ms (6/6), 600 ms 0/6, 800 ms+ 6/6 | 1125 ms | 1000 ms (6/6; 800 ms: 1/6) |

What a close costs:

| | stock iroh 1.4.1 | with the re-punch patch |
| --- | --- | --- |
| Outage end → direct again | 21–57 s (median 55 s), every RTT and setting | 0.13–0.32 s at 75 ms RTT, 0.26–0.66 s at 150 ms, 0.39–1.07 s at 250 ms |
| Time on the relay per close | 21–57 s | 0.15–2.06 s (median 0.41–0.79 s) |
| Hard block lifted → direct | 49–51 s | 0.26–0.56 s |

Longest media gap (median of 3, ms), stock, by outage length:

| RTT / setting | 200 | 300 | 400 | 600 | 800 | 1000 | 1500 | 2000 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 75 / 300 | 389 | 310 | 312 | 334 | 311 | 306 | 316 | 304 |
| 75 / 1000 | 422 | 400 | 485 | 623 | 1001 | 1002 | 1003 | 1013 |
| 150 / 300 | 426 | 686 | 684 | 532 | 538 | 536 | 532 | 550 |
| 150 / 1000 | 271 | 334 | 882 | 961 | 890 | 1002 | 1011 | 1005 |
| 250 / 300 | 211 | 607 | 1092 | 982 | 1085 | 841 | 838 | 833 |
| 250 / 1000 | 226 | 613 | 1161 | 641 | 1197 | 1001 | 1012 | 1006 |

Patched gaps are the same within noise, since the patch acts only after the close. All tables
are in [`results/summary.md`](results/summary.md), and every blackout is a row in
[`results/blackouts_all.csv`](results/blackouts_all.csv).

Put together:

- **300 ms + patch.** The direct path closes on most outages of 200–400 ms or more. Media keeps
  flowing over the relay after roughly the effective timeout, and goes direct again within
  about a second of the outage ending. Costs: carrying an iroh patch (below) until something
  like it lands upstream, and two path switches per outage. Each switch moves the pacing
  target to another path. On public relays (~8 Mbit/s, S5b) the bitrate has to drop for that
  half second or so. At long RTTs this setting already behaves like ~1 s.
- **~1 s, stock iroh.** Outages up to 600–800 ms no longer close the path, and the gap is the
  outage itself. Detection of a truly dead path takes 1.04–1.13 s instead of 0.34–0.96 s (the
  core's "no ack progress" signal would cover that second). But every outage of 1 s or more
  still costs ~20–56 s on the relay.
- **~1 s + patch** is also possible: the measured recovery after a close is as fast as at 300 ms.

## Setup

Everything runs in network namespaces on one 4-vCPU VM (kernel 6.18, no `sch_netem`).

```
x3h host 172.16.5.2 -- x3hn NAT [172.16.5.1 | 10.80.1.3] ------------------------ x3i router
x3c client 192.168.9.2 -- x3cn NAT [192.168.9.1 | 10.80.0.2] -- x3d delay line -- x3i (relay 10.80.9.1)
```

- **NATs** (`scripts/lab.sh`): S10's topology, both Linux MASQUERADE (port-preserving), but
  neither forwards a port. The host is reachable only through the relay, as in S5b. Both NATs
  drop unsolicited inbound UDP in INPUT, so a probe that arrives before the local side has sent
  never creates a conntrack entry that would make MASQUERADE choose a different port (the
  failure S10 hit).
- **Relay**: a local iroh-relay 1.4.1 (HTTPS on 3443 and QUIC address discovery on 7842,
  self-signed cert, clients skip verification). QAD is what tells each side its NAT address.
- **Delay**: the kernel has no netem, so `s5c delayline` is a transparent L2 delay line between
  the client NAT and the router (two AF_PACKET sockets, `ppoll` timers, offloads off). It
  delays every frame by RTT/2 in each direction, so the direct and relay paths both see the
  RTT. It never dropped or failed a send.
- **Harness** (`src/main.rs`): S5b's host and client, with the lab relay. The host runs one
  endpoint per config (idle 300 / keep-alive 100 ms, idle 1000 / keep-alive 200 ms), streams
  200 datagrams/s of 1150 bytes (1.8 Mbit/s, as S5b's `full` runs) and drops its direct UDP
  port in both directions with iptables to make an outage. The relay is TCP and is not touched.
  The client dials by key and relay URL only. The `sweep` plan does one 3 s hard block, then
  outages of 100–2000 ms, three times each, each one starting after 3 s on a settled direct path.
- **Matrix** (`scripts/sweep.sh`): RTT 75 / 150 / 250 ms × idle 300 / 1000 × stock / patched,
  with the four clients of one RTT running in parallel. 324 outages, none skipped.

Sanity check against S5b: with the same 75 ms RTT the lab reproduces S5b's numbers. Block →
relay took 342 ms (S5b: 295–377), a 200 ms blackout closed the path at 300 ms and not at 1000
ms, and re-punch took 50–57 s (S5b: 9–60 s). Hole punching worked every time, 313 ms after
dialing at 75 ms RTT.

## The re-punch patch

[`iroh-repunch.patch`](iroh-repunch.patch) (about 80 added lines, all in
`src/socket/remote_map/remote_state.rs`, internal API only):

- When a path is abandoned and no IP path is left on any connection to that remote, start a
  NAT traversal round at once, ignoring the 5 s `HOLEPUNCH_ATTEMPTS_INTERVAL` rate limit.
- Retry with backoff (250 ms, 500 ms, 1 s, then every 2 s) until an IP path is established
  again or 15 s have passed, then fall back to stock behaviour (the 60 s upgrade check).
- Only the client side initiates rounds in iroh, so only the dialing side needs the patch.
  The lab ran it on both sides anyway.

Why stock is slow: after the close nothing changes. The candidates are the same, the network
didn't change, and the remaining path is a relay, so the next round is the 60 s
`UPGRADE_INTERVAL` check. (S5b's 9–18 s cases were probably address updates from net reports
on the real internet.) S5b's `Endpoint::network_change()` kick did nothing for the same reason.

The patch is a prototype. Nothing was sent upstream. It has not been tested with several
connections to one remote, with a remote that really moved (new candidates arrive and trigger a
round anyway), or for how the retries interact with portmapper or relay changes. A real
version would probably make the retry schedule configurable.

## Limits

- One machine, emulated links: no jitter, no reordering, no random loss (S5b's 20% loss close
  was not retested), and a relay with no bandwidth limit. On the n0 relays (~8 Mbit/s) the
  half second on the relay at 300 ms would also mean a bitrate drop.
- The harness uses iroh's default congestion controller (Cubic), not `AppRate`. The longer
  gaps after short outages depend on how much is in flight when the path comes back, so they
  may differ under `AppRate`'s 2 × BDP window.
- Outages are total for the direct path only. The relay stays up. An outage that also takes
  down the relay (the whole uplink, as a Wi-Fi stall often does) would leave nothing to fall
  back to, and then a close only costs the re-punch.
- Three trials per cell. Close/no-close near the threshold depends on PTO timing, so cells
  like 1/6 or 4/6 are real but noisy.
- The patched build closed 2/3 vs 3/3 (150 ms RTT, 300–400 ms outages) and 1/3 vs 0/3
  (250 ms, 800 ms at 1000). The patch acts only after a close, so these differences are
  trial-to-trial PTO timing, not the patch.

## Reproduce

Linux, root, iproute2, iptables, ethtool, Rust.

```sh
cargo build --release
scripts/vendor.sh && (cd patched && cargo build --release)   # patched iroh 1.4.1
scripts/lab.sh up 37.5
S5C_BLACKOUTS=100,200,300,400,600,800,1000,1500,2000 S5C_REPS=3 scripts/sweep.sh $PWD/out/full 75 150 250   # ~75 min
python3 analyze.py out/full        # writes out/full/summary.md and blackouts_all.csv
scripts/lab.sh down
```

`results/runs/*` holds each run's path events, command marks and per-blackout times.
The per-datagram receive logs and probes (~12 MB compressed) are in the project files as
`spikes/s5c-idle-timeout/s5c-raw.tar.xz`, not in git.
