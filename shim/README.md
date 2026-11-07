# iroh shim

A thin Rust crate over iroh 1.x (`=1.4.1`) exposing the C ABI in
[`include/iroh_shim.h`](include/iroh_shim.h). Zig sees it through
`transport/iroh.zig` (header translated by `zig build`).

## ABI (v0.1)

| Call | Notes |
| --- | --- |
| `iroh_endpoint_bind(opts, &ep)` | secret key (or fresh), ALPN, relay mode (n0 default / disabled / custom URLs), optional bind address |
| `iroh_endpoint_online(ep, ms)` | wait for home relay |
| `iroh_endpoint_id`, `iroh_endpoint_ticket` | write into caller buffers; ticket is an iroh `EndpointTicket` string |
| `iroh_endpoint_connect(ep, ticket, alpn, ms, &conn)` | blocking with timeout |
| `iroh_endpoint_accept(ep, ms, &conn)` | blocking with timeout |
| `iroh_conn_send_datagram(conn, buf, len)` | never blocks; shim copies |
| `iroh_conn_recv_datagram(conn, buf, cap, ms, &len)` | `ms = 0` is non-blocking (`IROH_ERR_AGAIN`) |
| `iroh_conn_max_datagram_size`, `iroh_conn_local_drops`, `iroh_conn_remote_id` | |
| `iroh_*_free` | close and free handles |

Rules: status codes are `int32_t` (0 ok, negative error) with a thread-local
`iroh_last_error()`; Zig owns every buffer; the shim owns one tokio runtime
(2 worker threads); `panic = "abort"`.

`iroh_conn_local_drops` counts datagrams the shim dropped because its inbound
queue (4096) was full. It does **not** yet see drops inside iroh/noq's own
datagram buffers; S2 extends stats for that.

Not in v0.1 (later spikes): wakeup fd/handle for recv (S4), reliable streams,
path stats/events (S5), transport config and custom congestion controller (S3),
`path_max_idle_timeout`.

## Build modes

| Flag | Meaning |
| --- | --- |
| `-Dshim=source` (default for now) | runs `cargo build --release` in `shim/` for the Zig target |
| `-Dshim=dir -Dshim-dir=<dir>` | use an unpacked release archive (`lib/`, `include/`) |
| `-Dshim=prebuilt` | hash-pinned release archive from `build.zig.zon` (wired after the first `shim-v*` release) |
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

Push a tag `shim-vX.Y.Z`; `.github/workflows/shim.yml` builds all five targets,
runs the echo, and publishes `iroh-shim-<target>.tar.gz` plus `SHA256SUMS` and
`SIZES.md`.
