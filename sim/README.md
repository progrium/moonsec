# sim: simulated network harness

Deterministic, discrete-event network simulation behind the same `PacketPipe`
interface (`transport/pipe.zig`) the core uses for iroh. The network model is
`transport/sim.zig`; this directory holds the scenario catalog and runner.

```
zig build test-sim                         # unit tests (pipe, network model, scenarios)
zig build sim -Doptimize=ReleaseSafe       # run every scenario, seeds 1..3, print a table
zig build sim -- --list                    # scenario names
zig build sim -- --scenario loss-5pct --seeds 5
zig build sim-check -Doptimize=ReleaseSafe # compare digests with sim/golden.txt (CI does this)
zig build sim -Doptimize=ReleaseSafe -- --update sim/golden.txt   # after an intended model change
```

## Model (per direction)

send buffer (evicts oldest, counted) → pacer (rate set through `setPacingRate`,
2 ms burst credit) → droptail bottleneck shared with cross traffic → loss and
blackouts → propagation delay, jitter, reordering → receive buffer (drops
counted) → `recv`.

| Knob (`LinkConfig`) | What it does |
| --- | --- |
| `steps`, `fade` | Bottleneck capacity schedule, or random capacity every 2–5 s |
| `queue_limit_bytes` | Droptail buffer (500 KB in S11) |
| `delay_us`, `jitter_us`, `reorder` | Propagation, uniform jitter, whether jitter may reorder |
| `reorder_p`, `reorder_extra_us` | netem-style: hold back a share of packets |
| `loss`, `loss_burst` | Random loss rate; mean burst length (Gilbert-Elliott) |
| `blackouts` | Windows where everything is lost |
| `wifi` | S11's model: A-MPDU-like batches every 0.5–4 ms, 5–60 ms stalls every 2 s on average |
| `cross` | On/off CBR UDP, one Reno flow, or line-rate bursts |
| `overhead_bytes` | Per-datagram wire overhead |

Endpoints have a clock offset (B runs 987 s ahead in the catalog, so only
one-way delay differences carry meaning), send/receive buffer limits and a
max datagram size. `Net.setPacedHook` reports each datagram as it leaves the
pacer, for code that needs S11-style send timestamps.

Determinism: every random source (loss, jitter, Wi-Fi, cross traffic, fades)
has its own stream per direction derived from the seed, so turning one knob
doesn't reshuffle the others. `Net.digest()` hashes every delivery and drop;
CI checks the digests on Linux x64/arm64, macOS and Windows.

## Scenarios

`zig build sim -- --list`. Transport cases: `clean`, `loss-5pct`,
`loss-bursty`, `jitter`, `reorder`, `halving`, `blackout`,
`droptail-overload`. S11's eight bottlenecks: `s11-wired-steps`,
`s11-wired-60ms`, `s11-wifi-steps`, `s11-wifi-lan`, `s11-wifi-fade`,
`s11-wifi-udp-cross`, `s11-wifi-tcp`, `s11-wifi-bursts`.

The runner's load is a fixed-bitrate 60 fps stream (S11's frame sizes: lognormal
σ 0.25, a 4× scene change every 3 s). There is no rate controller here yet: the
core's controller drives `Net` directly, the same way `sim/run.zig` does.
