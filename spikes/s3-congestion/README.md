# Spike S3: custom QUIC congestion control through iroh

**Question.** Can we set the QUIC congestion controller and datagram config through iroh's builder?

**Pass criterion.** A custom controller is active on a live connection.

**Result: pass.** iroh 1.4.1 exposes both through its public API. A custom controller (`AppRate`, in `src/lib.rs`) was installed with the builder. It ran on a live iroh connection over real UDP sockets, was confirmed by downcasting `Connection::congestion_state(path)`, and followed a target rate changed mid-connection from outside the controller. We don't need the noq-proto fallback for this.

Versions: `iroh = 1.4.1`, `noq = 1.4.0`, `noq-proto = 1.4.0`, Rust 1.97, Linux x86_64.

## API surface (all public, no forks or patches)

| Need | Where |
| --- | --- |
| Install a controller | `QuicTransportConfig::builder().congestion_controller_factory(Arc<dyn ControllerFactory>)`, then `Endpoint::builder(..).transport_config(cfg)` |
| Implement a controller | `iroh::endpoint::{Controller, ControllerFactory, ControllerMetrics, RttEstimator}` (re-exported from noq-proto; no direct noq dependency needed) |
| Per-connection controller (client) | `Endpoint::connect_with_opts` with `ConnectOptions::with_transport_config` |
| Per-connection controller (host / accept side) | `Incoming::accept_with(ServerConfig)`, built with `Endpoint::create_server_config_builder(..).set_transport_config(cfg)` (tested here) |
| Pacing | `Controller::metrics()` returns `pacing_rate` (bytes/s) and `send_quantum`; noq's pacer uses them directly |
| Read controller state live | `Connection::congestion_state(PathId) -> Box<dyn Controller>` (a clone; `into_any().downcast::<T>()`), `Connection::paths()` with `PathStats { cwnd, bandwidth_estimate, congestion_events, rtt, .. }` |
| Datagram config | `datagram_send_buffer_size`, `datagram_receive_buffer_size` on the same builder; `Connection::max_datagram_size()` and `datagram_send_buffer_space()` at runtime |
| Other knobs on the builder | `initial_rtt`, `initial_mtu`/`min_mtu`, MTU discovery, ACK frequency, `packet_threshold`/`time_threshold`, keep-alive, GSO |

## The controller

`AppRate` is built for our design, where the Zig delay-gradient rate controller decides the send rate and QUIC must not fight it:

- It paces at a target rate held in a shared `RateKnob` (an atomic). The core sets that rate; in the shim this becomes one C ABI call.
- The window is 2× BDP at the target rate (with a 5 ms RTT floor), so it never limits below the target and pacing does the shaping.
- On loss or ECN it counts the event and **does not cut the window**. The core reacts through its own feedback loop.
- It exposes per-path counters (bytes sent and acked, congestion events, lost bytes, srtt, min RTT, MTU) for the shim's path stats.
- Target 0 means no limit: a 64 MiB window and no pacing rate.

## Live results

`cargo run --release -- [--app-paced] [--loss PCT --delay-ms MS] [--builtin]`. There are two endpoints in one process, relays are off, and they dial by key with a direct address. 1150-byte datagrams flow client to host. The target steps through unlimited, 40, 10, 2 and 25 Mbit/s on one live connection. Full output is in `results/`.

**Clean loopback, sender paced by the app at 95% of target** (`results/2-clean-app-paced.txt`):

| Target | Received | p50 / p99 one-way delay |
| --- | --- | --- |
| 40 Mbit/s | 35.5 Mbit/s | 61 / 180 µs |
| 10 Mbit/s | 9.5 Mbit/s | 32 / 144 µs |
| 2 Mbit/s | 1.9 Mbit/s | 65 / 138 µs |

(The 40 Mbit/s row falls short of 38 because the toy sender's 1 ms tokio timer is imprecise, not because of the controller.)

**Clean loopback, sender saturating** (`results/1-clean-saturating.txt`): throughput follows the controller's pacing rate exactly (38.98, 9.74, 1.95 and 24.37 Mbit/s for targets of 40, 10, 2 and 25). The controller is the only thing limiting the rate.

**2% random loss each way, 20 ms RTT, through a lossy proxy, sender paced by the app:**

| Target | Custom `AppRate` (`results/3-…`) | iroh default Cubic (`results/4-…`) |
| --- | --- | --- |
| 40 Mbit/s | 34.5 Mbit/s, p99 12.2 ms | 4.2 Mbit/s, p99 542 ms |
| 10 Mbit/s | 9.3 Mbit/s, p99 12.2 ms | 4.0 Mbit/s, p99 636 ms |
| 25 Mbit/s | 21.5 Mbit/s, p99 12.1 ms | 3.3 Mbit/s, p99 724 ms |

With Cubic, random loss holds the connection near 4 Mbit/s and media piles up in the datagram send buffer, adding half a second of delay. This is the "QUIC CC fights our rate controller" risk from the design doc, reproduced. With `AppRate`, delay stays at the path RTT. The 723 congestion events are counted, not acted on, and are ready for the core to read.

How the loss test isolates the path: iroh's NAT traversal finds the host's real address and opens a second, direct path around a plain proxy. The first attempt did exactly that, and a second `AppRate` was built for the new path. The minimums on `max_concurrent_multipath_paths` and `max_remote_nat_traversal_addresses` can't be lowered enough to stop it. So the client side runs in its own network namespace, with only `lo` up (`unshare(CLONE_NEWNET)` on the runtime thread), and the proxy is its only way out. Proxy mode needs root or CAP_SYS_ADMIN.

## Findings for the shim and other spikes

1. **One controller per QUIC path, not per connection.** noq builds a controller from the factory in `PathData::new` for every path, including paths opened by NAT traversal and relay paths, since they share the transport config. The shim should apply the core's target to the *selected* path and report per-path counters. (Relay paths weren't exercised live here; this is from reading the code.)
2. **The factory doesn't know which connection it serves.** For several sessions on one host, use a factory per connection via `accept_with` / `connect_with_opts`, and keep one knob per session.
3. **The datagram send buffer is a hidden queue.** With a saturating sender, the 256 KiB buffer adds about 1 s of delay at 2 Mbit/s (`results/1-…`). The core's pacer has to stay under the target and keep that buffer near empty, or the shim should set a small `datagram_send_buffer_size`. This feeds S2.
4. **Datagram drops are silent (S2's "every drop visible in stats").** When the send buffer is full, noq drops the oldest datagrams and logs only a `trace!` line. When the receive buffer is full, it drops with only a `debug!` line. Neither has a counter in `ConnectionStats`. The shim should check `datagram_send_buffer_space()` before each send (or use `send_datagram_wait`) and count drops itself. Sequence numbers in our media header already show receive-side gaps.
5. `ControllerMetrics` is `#[non_exhaustive]`: build it with `Default` and set its fields.
6. `Controller` methods run inside noq's connection state machine, under its lock, so they must stay non-blocking. Atomics are enough for the knob and the counters.

## Recommendation

Keep Rust iroh for S3. Put `AppRate` (or its successor) into the shim behind the draft ABI's config entry (`congestion controller choice`). Add `set_target_bitrate(conn, bps)` and per-path controller counters to the path-stats call. noq-proto isn't needed for congestion control.
