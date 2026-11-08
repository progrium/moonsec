# iroh shim

A thin Rust crate over iroh 1.x (`=1.4.1`) exposing the C ABI in
[`include/iroh_shim.h`](include/iroh_shim.h). Zig sees it through
`transport/iroh.zig` (header translated by `zig build`).

## ABI (v0.2)

The full draft ABI from the design doc. Every call has a Zig wrapper in `transport/iroh.zig`
and a test in `transport/iroh_test.zig` (loopback, `zig build test-shim`) or
`transport/iroh_netns_test.zig` (Linux netns, root).

| Call | Notes |
| --- | --- |
| `iroh_shim_init(hook, ctx)` | optional, before anything else; hook runs on the shim runtime thread (pin it, raise priority) |
| `iroh_shim_version`, `iroh_shim_now_us`, `iroh_last_error` | `now_us` is the clock event timestamps use |
| `iroh_endpoint_bind(opts, &ep)` | key, ALPN, relay mode (n0 / disabled / custom / custom-only), bind address, and the per-connection transport settings below |
| `iroh_endpoint_online`, `_id`, `_ticket`, `_connect`, `_accept`, `_free` | blocking calls take a timeout; `accept`'s bounds the wait for a connection, not its handshake (10 s) |
| `iroh_endpoint_network_change` | the local network changed: iroh re-runs its net report and tries new paths now |
| `iroh_conn_send_datagram` | never blocks; a full send buffer evicts the oldest datagrams, counted exactly |
| `iroh_conn_recv_datagram` | `ms = 0` is non-blocking (`IROH_ERR_AGAIN`) |
| `iroh_conn_set_target_bitrate(conn, bps)` | AppRate pacing target for the selected path; moves with the path |
| `iroh_conn_set_burst(conn, us)` | AppRate burst credit (default 20 ms) |
| `iroh_conn_wakeup_handle`, `_wakeup_clear` | fd (Unix) / SOCKET (Windows), readable on datagram, event or close |
| `iroh_conn_poll_event` | path opened / selected / closed, lagged, no-ack-progress, ack-resumed, conn closed |
| `iroh_conn_stats` | exact datagram accounting on both sides, QUIC loss, target, selected path, `path_selections` (bumps on every path change) |
| `iroh_conn_path_stats` | per path: RTT, min RTT, cwnd, loss, direct vs relay, controller pacing rate, ack stall |
| `iroh_conn_open_bi`, `_accept_bi`, `iroh_stream_write`, `_read`, `_finish`, `_free` | reliable bidirectional streams |
| `iroh_conn_max_datagram_size`, `_local_drops`, `_remote_id`, `_free` | |

Transport settings (`IrohBindOpts`, 0 = default): datagram send buffer (1 MiB; must hold the
largest frame, S10), datagram receive buffer (2 MiB), shim receive queue (4096), per-path idle
timeout (300 ms, S5; the S5c decision is still open) and keep-alive (100 ms), connection idle
timeout, initial target, burst credit, no-ack-progress threshold (150 ms), and `relay_ca_pem`,
a PEM file of extra roots for relay TLS (a self-hosted relay with its own CA, the netns lab).

**Congestion control (`src/apprate.rs`).** S3's `AppRate`, installed through a per-connection
transport config, so each connection has its own factory and rate knob. It paces at the target,
sizes the window at 2x BDP plus the burst, never cuts on loss, and counts acks, loss and stalls.
iroh builds one controller per path; the shim maps path IDs to controllers via
`Connection::congestion_state`, and on `Selected` moves the target to that controller (other
paths pace at 1 Mbit/s or the target, if lower). If iroh selects a path before the shim can
map it to its controller, the 5 ms monitor retries the move until it lands. Burst credit
follows spike S10b: noq's own pacer bucket holds only ~2 ms of the rate, so the controller keeps
its own token bucket of `burst_us` at the target, refilled at the target. While it holds at least
one packet, the controller reports a 10 Gbit/s pacing rate, so a frame leaves at line rate;
once spent, it reports the target. The bucket carries debt (goes negative), which keeps the
sustained rate at the target (S10b measured 93.8 Mbit/s on a 90 target with a zero floor).

**Drop accounting.** Send side: noq's datagram buffer is a FIFO that transmission and eviction
both pop from the front, so its contents are always the newest suffix of what the shim
accepted. The shim keeps the lengths of unresolved datagrams and, from the buffer's payload size
(`datagram_send_buffer_space`) and `frame_tx.datagram`, works out exactly how many were evicted.
It does this only when an eviction is possible, or every 1024 sends. Receive side: the reader
task drains QUIC's buffer in batches; on the current-thread runtime nothing runs between a
drain and a stats read, so `frame_rx.datagram - drained` is exactly what QUIC dropped. The shim
queue counts its own overflow. Behind a 20 Mbit/s tbf in netns, `tx_wire - rx_wire` equals QUIC
`lost_packets` exactly.

**No ack progress.** Each controller records when ack-eliciting data was first left unacked
(`on_packet_sent`, so pure ACKs don't count) and clears it on any ack. A 5 ms monitor raises
`IROH_EV_NO_ACK_PROGRESS` when the selected path stalls past the threshold, which is never
less than 1.5 × the path's RTT (the larger of smoothed and latest) + 25 ms: an idle path's
keep-alive stays unacked for a whole RTT, so a fixed 150 ms fired constantly at 250 ms RTT. In netns, after a
direct path is blackholed: the signal at 159 ms, path closed at 305 ms, relay selected at
305 ms, with the target on the relay's controller (delivered 9.7 Mbit/s at a 10 Mbit/s target).

Threading: iroh runs on **one shim-owned thread** with a current-thread tokio runtime (S4:
1–4 ms p99 handoff on a shared multi-thread runtime under load versus 100–400 µs on one pinned
high-priority thread). `send_datagram` calls `Connection::send_datagram` directly from the
caller's thread. Blocking calls (connect, accept, streams) hand a future to the runtime thread.

Rules: status codes are `int32_t` (0 ok, negative error) with a thread-local
`iroh_last_error()`; Zig owns every buffer; `panic = "abort"`.

iroh keeps at most one direct (IP) path per connection and closes redundant ones; relay paths
stay open as backups. So a path change in practice is direct <-> relay, which is what the netns
test exercises (with a local `iroh-relay --dev`).

## Tests

```sh
zig build test-shim                         # echo selftest + loopback ABI tests
zig build netns-test && sudo IROH_RELAY=$(which iroh-relay) zig-out/bin/iroh-netns-test
```

The netns tests need root, iproute2 (tc with tbf), iptables, and `iroh-relay` for the path
change test (`cargo install iroh-relay@1.4.1 --features server --locked`); without it that test
skips. CI runs both on linux-x86_64.

## Build modes

| Flag | Meaning |
| --- | --- |
| `-Dshim=source` (default for now) | runs `cargo build --release` in `shim/` for the Zig target |
| `-Dshim=dir -Dshim-dir=<dir>` | use an unpacked release archive (`lib/`, `include/`) |
| `-Dshim=prebuilt` | hash-pinned release archive from `build.zig.zon` (lazy; fetches only the target's archive; no Rust needed). Windows archives are MSVC, so use `*-windows-msvc` targets |
| `-Dshim-link=static` (default) / `dynamic` | static archive, or `.so`/`.dylib`/`.dll` installed next to the exe |

Target mapping: Linux `*-linux-gnu` ↔ `*-unknown-linux-gnu`; macOS ↔ `*-apple-darwin`
(release archive is `lipo` universal, `MACOSX_DEPLOYMENT_TARGET=11.0`);
Windows `*-windows-msvc` ↔ `*-pc-windows-msvc` (Zig's `*-windows-gnu` maps to Rust `*-pc-windows-gnullvm`).

On Linux the Rust std wants `libgcc_s` for `_Unwind_*`; the Zig link uses Zig's
bundled LLVM libunwind (`-lunwind`) instead.

Release profile: `opt-level = "s"`, fat LTO, 1 codegen unit, `panic = "abort"`,
debug info stripped, iroh default features off with `tls-ring`, `portmapper`,
`fast-apple-datapath` added back.

## Releasing

1. Push a tag `shim-vX.Y.Z`. `.github/workflows/shim.yml` builds all five targets,
   runs the echo (static, dynamic, and `-Dshim=prebuilt` from the fresh archive),
   and publishes `iroh-shim-<target>.tar.gz`, `SHA256SUMS` and
   `THIRD_PARTY_NOTICES.md`, with the size table as release notes.
2. Run `shim/pin-release.sh shim-vX.Y.Z` and commit `build.zig.zon`. It runs
   `zig fetch` on each archive and rewrites the block between the
   `shim-release-begin`/`end` markers. The workflow's `prebuilt` job then builds
   from the pinned archives on every target, with no Rust toolchain.

Every archive carries `THIRD_PARTY_NOTICES.md`, generated by
[cargo-about](https://github.com/EmbarkStudios/cargo-about) from `about.toml`
and `about.hbs` over all release targets. To preview it locally:
`cargo about generate --locked -c about.toml -o THIRD_PARTY_NOTICES.md about.hbs`
(run in `shim/`). A crate under a license not in `about.toml`'s `accepted` list
fails the build; review it before adding the license.
