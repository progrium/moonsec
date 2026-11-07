# Low-Latency Streaming in Zig — Design & Plan

Nov 7, 2026 · @Jeff Lindsay

## Summary

We build a low-latency remote desktop and game streaming core library in Zig, with both host and client, that pairs Parsec's internet-first networking with Moonlight/Sunshine's media quality and openness. Networking uses Rust iroh through a small in-repo shim; everything latency-critical (capture, encode, packetization, FEC, rate control, pacing, decode, present) is Zig.

**Goals**

- Glass-to-glass latency on a wired LAN within a few ms of Parsec and Moonlight on the same hardware.
- Zero-config connections over the internet: dial by key, hole punching, relay fallback.
- Degrade quality before latency: bitrate, then resolution, then frame rate.
- One cross-platform core; platform code limited to capture, codecs, presentation and input.
- A browser client that reuses the same protocol and core.

**Targets**

| Role | Initial | Later |
| --- | --- | --- |
| Host | Windows, macOS | Linux |
| Client | Windows, macOS, Linux | Browser (iroh over WebSocket relay) |

**Non-goals for v1**

- Voice chat and microphone passthrough (the protocol keeps stream IDs so they can be added later).
- A Zig port of iroh or noq; revisit only if the transport spike fails.
- WebRTC or WebTransport browser paths.
- Moonlight/GameStream protocol compatibility.
- Mobile clients and a hosted account service.

## What we take from Parsec and Moonlight/Sunshine

Both products run the same basic pipeline; Parsec wins over the internet because its transport and encoder share one feedback loop, and Moonlight/Sunshine wins on quality ceiling and openness.

| Idea | From | How we use it |
| --- | --- | --- |
| Transport feeds the encoder within milliseconds | Parsec ([BUD](https://blog.parsec.app/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007/)) | Delay-based rate controller in the Zig core drives per-frame encoder reconfiguration |
| Priority order: latency, then frame rate, then quality | Parsec | Encoded in the rate controller's response ladder |
| Zero-copy capture into the hardware encoder | Parsec ([overview](https://support.parsec.app/hc/en-us/articles/32361354307348-Overview)) | GPU textures/surfaces go straight to the encoder on every host OS |
| Peer-to-peer with NAT traversal and relay fallback, no setup | Parsec | iroh: dial by Ed25519 key, QUIC hole punching, relays |
| Reed-Solomon FEC per frame | Moonlight ([protocol notes](https://games-on-whales.github.io/wolf/stable/protocols/index.html)) | Adaptive FEC on WAN paths |
| Reference frame invalidation instead of keyframes | Moonlight | Long-term references plus intra-refresh; IDR only as last resort |
| Broad encoder support, AV1, HDR, high bitrates | Sunshine | Per-OS encoder backends behind one interface |
| Per-stage latency overlay | Moonlight | Telemetry API and debug overlay from the first milestone |
| Open, documented protocol | Moonlight/Sunshine | Versioned wire spec lives in the repo |

New in this design: choose loss recovery by path (NACK/retransmit when RTT is well under a frame, FEC otherwise), and use iroh keys for pairing instead of an account server.

## Architecture

The library is a pure, sans-I/O Zig core wrapped by two edges: a transport behind a `PacketPipe` interface, and per-OS platform backends. The core takes packets, frames and timestamps in and returns packets, encoder settings and present decisions out; it never touches sockets, clocks or threads.

*(Diagram: library layers · core, transport, platform.)*

The core talks to the transport in packets and path stats, and to the platform in frames and encoder settings; nothing in the core knows which OS or network it is on.

**Layers**

1. **Public C ABI** (exported from Zig): `host_*`, `client_*`, `session_*`, `telemetry_*`, so apps in any language can embed it.
2. **Core** (pure Zig, no I/O), with these modules:
   - `proto`: framing, versioned messages, stream IDs, timestamps.
   - `media`: packetizer, Reed-Solomon FEC, NACK/retransmit, reassembly.
   - `rate`: delay-gradient controller that outputs bitrate, resolution and frame rate.
   - `recovery`: long-term reference bookkeeping, RFI, intra-refresh, IDR fallback.
   - `pacing`: sender pacing and the client's present policy.
   - `input`: event model, redundancy, gamepad state snapshots.
   - `clock`: host/client clock offset for one-way delay and end-to-end latency.
3. **Transport** (`PacketPipe`: send, receive, path stats). Implementations: iroh shim (production), simulated pipe (tests), and a native UDP pipe reserved as a fallback.
4. **Platform**: host (capture, encode, audio in, input injection, virtual display, cursor) and client (decode, present, audio out, input capture).

**Threading**

Each pipeline stage gets a dedicated OS thread connected by lock-free single-producer/single-consumer rings: capture, encode, network, decode, present, audio. Threads run at elevated priority (MMCSS on Windows, QoS classes on macOS). We do not depend on Zig's `std.Io` evented backends; Zig 0.16 shipped only the threaded implementation for production use ([release notes summary](https://www.youngju.dev/transcribe/2026-07-16-zig-016-io-interface.en)).

**Why sans-I/O**

- Deterministic simulation: seeded loss, jitter and bandwidth-collapse scenarios run in CI against the real core.
- The same core compiles to `wasm32` for the browser client unchanged.
- Transports can be swapped without touching media logic.

## Transport

We use Rust iroh 1.x through a thin Rust shim that lives in the repo and exposes exactly the C ABI we need. iroh gives us key-based identity, discovery, QUIC NAT traversal, multipath and relays with a stable wire protocol ([iroh 1.0](https://pinggy.io/amp/blog/iroh_1_0_dial_keys_not_ips/)).

**What iroh carries**

- Identity and pairing: endpoint ID = Ed25519 key; pairing adds a client key to the host allowlist via PIN or QR ticket.
- Discovery: DNS/pkarr and self-hosted relays; mDNS for LAN.
- Control: reliable QUIC streams for session setup, clipboard, display config and file transfer.
- Media: unreliable QUIC datagrams, tagged with stream IDs.

**Shim C ABI (draft)**

- Endpoint: `bind(secret_key, alpns, relay_urls)`, `connect(ticket)`, `accept()`, `close()`.
- Datagrams: `send_datagram(conn, buf, len)`, `recv_datagram(conn, buf, cap)` (non-blocking, with a wakeup fd/handle).
- Streams: open/accept bidirectional, read, write, finish.
- Path stats: RTT, loss, congestion window, direct vs relayed, path changes as events.
- Config: datagram buffer sizes, congestion controller choice, pacing, keep-alive.
- Built with `panic = "abort"`; Zig owns every buffer that crosses the boundary.

**Relay mode**

Relayed paths run over HTTPS/WebSocket on TCP, so there is head-of-line blocking but no packet loss. When the path is relayed the core turns FEC off, caps bitrate, prefers lower resolution, and shows a relay badge in the overlay. Browser clients are always in this mode.

**Fallbacks if the transport spike fails**

1. Shim over `noq-proto` (sans-I/O QUIC with multipath and n0 NAT traversal) with a Zig driver and Zig congestion controller ([noq-proto](https://docs.rs/noq-proto/latest/noq_proto/)).
2. Native Zig UDP media pipe, with iroh kept for signaling and control.

The `PacketPipe` boundary means either fallback replaces only the transport.

## Media pipeline

The pipeline never buffers: every frame is encoded, sent, decoded and presented as soon as it exists, and the rate controller keeps the network queue near empty.

**Wire format**

- Every datagram carries a stream ID (video, audio, input, control-fast; mic reserved), so new streams need no protocol bump.
- Video packets are about 1150 bytes to fit any QUIC datagram path.
- Video header: frame ID, slice, shard index, FEC group, capture timestamp, encode-done timestamp.

**Encoder settings**

- No B-frames, no lookahead, one-frame VBV.
- Multiple slices per frame so packetizing starts before encode finishes.
- Intra-refresh instead of periodic keyframes; long-term references for RFI.
- Per-frame bitrate reconfiguration without forcing a keyframe.
- Codecs: H.264 and HEVC first, AV1 where the encoder supports it; 4:4:4 and HDR later.

**Loss recovery**

- RTT under about a quarter of the frame interval: NACK and selective retransmit.
- Otherwise: Reed-Solomon FEC, overhead set from measured loss (0 to 30%).
- Unrecoverable frame: reference frame invalidation; IDR only as last resort.
- Relayed path: no FEC (TCP underneath).

**Rate control**

- The client sends transport-wide feedback every 5 to 10 ms with per-packet arrival times.
- The host runs a delay-gradient estimator (GCC-style) and responds in order: bitrate, then resolution, then frame rate.
- Targets are bounded by user settings and by what the path reports.

**Pacing and presentation**

- WAN and Wi-Fi: spread a frame's packets over 50 to 70% of the frame interval; LAN: send in bursts.
- Client present modes: lowest latency (present on decode, tearing/VRR allowed) or smooth (pace to vsync).
- Desktop mode renders the cursor on the client to hide perceived lag.

**Audio**

- Opus at 5 to 10 ms frames, Opus in-band FEC plus light Reed-Solomon, about 20 ms jitter buffer. Audio is not the clock master.

**Input**

- Gamepads: full state snapshots, idempotent and repeated across datagrams.
- Keyboard and mouse: sequenced events with the last N events repeated in each packet.
- Relative mouse moves accumulate; absolute positions are sent as latest-wins.

**Clock and telemetry**

- Host/client clock offset estimated from round trips; used for one-way delay and glass-to-glass estimates.
- Every stage reports its time; the overlay shows capture, encode, network, decode and present per frame.

## Platform backends

Each OS implements the same small host and client interfaces; frames stay on the GPU from capture to encode and from decode to present.

| Function | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Capture | Desktop Duplication / Windows.Graphics.Capture (D3D11 textures) | ScreenCaptureKit (IOSurface) | PipeWire portal; KMS grab optional |
| Encode | NVENC (runtime-loaded), AMF, oneVPL; Media Foundation fallback | VideoToolbox, low-latency mode | VAAPI, NVENC; Vulkan Video later |
| Audio capture | WASAPI loopback | ScreenCaptureKit audio | PipeWire |
| Input injection | SendInput; virtual gamepad needs a signed driver | CGEvent (Accessibility permission); gamepad limited | uinput |
| Virtual display | IddCx driver (signing required) | CGVirtualDisplay (private API) | Compositor headless output |
| Decode | D3D11VA | VideoToolbox | VAAPI; Vulkan Video later |
| Present | Flip-model swapchain, waitable object, tearing allowed | CAMetalLayer | Wayland/EGL or Vulkan |
| Input capture | Raw Input; gamepads via SDL3 or GameInput | NSEvent / GameController | evdev via SDL3 |

**Zig interop**

- `@cImport` for C SDKs: NVENC, oneVPL, Opus and the shim header.
- Windows COM/D3D through generated bindings (for example zigwin32) or thin C shims.
- macOS frameworks (ScreenCaptureKit, VideoToolbox, Metal) behind small `.m` files compiled by `zig build`; the Zig side sees only a C ABI.
- Pin one Zig version per release; stdlib churn between versions is still real.

## Web client

The browser is just another iroh client that is always relayed, so the host needs no new transport or stack. In the browser, iroh connects only through a relay, end-to-end encrypted ([iroh browser docs](https://docs.iroh.computer/languages/wasm-browser)).

- **Transport:** iroh compiled to WASM through a small wasm-bindgen crate next to the native shim; same keys, tickets and pairing.
- **Core:** the Zig core compiled to `wasm32` for reassembly, feedback, input encoding and clock sync.
- **Video:** WebCodecs `VideoDecoder` with `prefer-hardware` and `optimizeForLatency`; H.264 by default, HEVC/AV1 when `isConfigSupported()` says yes.
- **Audio:** libopus compiled to WASM with `zig cc`, played through an AudioWorklet.
- **Rendering:** decode and draw in a Worker with OffscreenCanvas; close each frame immediately, no queue.
- **Input:** Pointer Lock with `unadjustedMovement`, Keyboard Lock where available (Chromium, fullscreen), Gamepad API polling.

**Expectations:** the TCP relay adds head-of-line blocking and a detour through the relay server, and browser compositing adds about one to two frames. Self-hosted relays near users keep it usable. If iroh later adds direct browser paths (WebTransport or WebRTC), the web client gets them by upgrading.

## Build, distribution and repo layout

The shim's source lives in the repo, but its built libraries are CI release artifacts pulled in by hash through `build.zig.zon`, so app builds never need Rust.

```
/core          pure Zig core (sans-I/O)
/transport     PacketPipe, iroh binding, sim pipe
/platform      host/{windows,macos,linux}, client/{windows,macos,linux,web}
/shim          Rust crate wrapping iroh (Cargo.lock, rust-toolchain.toml)
/shim-web      Rust wasm-bindgen crate for the browser
/web           browser client glue (TypeScript)
/spec          versioned wire protocol spec
/sim           simulation harness and scenarios
/tools         latency probe, netem scripts, interop harness
```

**Shim artifacts**

- CI builds each target (Windows x64/arm64, macOS universal, Linux x64/arm64) and publishes a tagged release, e.g. `shim-v0.1.0`.
- `build.zig.zon` lists each archive by URL and hash as a lazy dependency; a build downloads only its own target.
- `-Dshim=source` runs `cargo` locally for anyone changing the shim.
- Release profile: `opt-level = "s"`, fat LTO, one codegen unit, `panic = "abort"`, debug info stripped; iroh default features off, needed ones added back.
- Crypto backend: ring (simpler to cross-compile than aws-lc-rs).

**Linking rules**

- Windows: match ABIs (Zig `-target x86_64-windows-msvc` or Rust `*-windows-gnullvm`), or ship the shim as a DLL; link `ws2_32`, `bcrypt`, `ntdll`, `userenv`.
- macOS: same `MACOSX_DEPLOYMENT_TARGET` on both sides; `lipo` into a universal library.
- Linux: build against an old glibc or musl.

**Licensing**

- iroh and noq are MIT/Apache-2.0; ring has its own terms. CI generates a third-party notices file (for example with `cargo-about`) shipped with every build.

## Initial spikes

Nine time-boxed spikes, roughly three to four weeks in total, settle the decisions that are expensive to reverse; the transport spikes (S2 to S5) decide whether Rust iroh stays. Pass thresholds are proposed starting points to confirm in review.

| # | Question | Method | Pass | If it fails | Box |
| --- | --- | --- | --- | --- | --- |
| S1 | Does the shim build and link into Zig on all three OSes? | Minimal shim (bind, connect, datagram echo); CI matrix for 5 targets | Echo works on Windows, macOS, Linux; archive sizes recorded | Ship shim as a DLL/dylib/so | 3 days |
| S2 | Do iroh datagrams add hidden queueing or silent drops under load? | Push 50 to 150 Mbit/s through a `tc netem` bandwidth cap; log send-to-receive delay and drops | Added delay p99 under 2 ms when sending below the cap; every drop visible in stats | Tune buffers; else go to S3 fallback path | 4 days |
| S3 | Can we set the QUIC congestion controller and datagram config through iroh's builder? | Read iroh/noq APIs; wire a custom controller in the shim | Custom controller active on a live connection | noq-proto shim with Zig driver | 3 days |
| S4 | How much jitter does the FFI and tokio handoff add? | Timestamp at Zig send, shim entry, socket write; pinned high-priority threads | Handoff p99 under 0.5 ms | Dedicated current-thread runtime in the shim | 2 days |
| S5 | Can we see direct vs relayed path and per-path RTT/loss? | Force relay, then allow hole punch; watch shim events | Path changes and stats arrive within 100 ms | Patch shim to expose noq path stats | 2 days |
| S6 | What is our glass-to-glass baseline on Windows? | Desktop Duplication to NVENC to D3D11VA over LAN; photodiode or high-speed camera vs Moonlight and Parsec | Within 5 ms of Moonlight at 1080p60 | Profile per stage before building further | 5 days |
| S7 | Same baseline on a macOS host? | ScreenCaptureKit to VideoToolbox, Windows or macOS client | Encode under 8 ms at 1080p60 | Adjust VideoToolbox settings; check M-series vs Intel | 3 days |
| S8 | Do encoders support what the design needs? | Per-frame bitrate change without IDR, intra-refresh, long-term refs on NVENC, AMF, oneVPL, VideoToolbox | Matrix filled in; at least NVENC and VideoToolbox pass | Fall back to IDR on loss for that backend | 3 days |
| S9 | Is the web client usable over a relay? | iroh WASM plus WebCodecs H.264 against S6 host, self-hosted relay | Plays 1080p60 on Chrome with latency recorded | Defer web to a later phase | 4 days |

S1 runs first; S2 to S5 and S6 to S8 can run in parallel; S9 needs S1 and S6.

### Spike status

Updated Nov 7, 2026. Each spike's write-up, code and raw results are under [`spikes/`](../spikes); S1's code is the real shim at the repo root.

| # | Status | Headline |
| --- | --- | --- |
| S1 | Partial pass, CI pending | Shim links into Zig 0.16 statically and dynamically; echo passes on Linux x64; CI green on Linux x64/arm64 and Windows x64, macOS and Windows arm64 still being fixed; archive sizes not yet recorded |
| S2 | Pass with headroom; drop visibility fails | iroh adds 0.1–0.8 ms p99 under ~91% of capacity, but a 1 MiB send buffer hides 100–140 ms of queueing at the cap, and send-buffer evictions are not counted. Being rerun with S3's controller |
| S3 | Pass | A custom congestion controller installs through iroh's public builder and holds a target rate on a live connection; under 2% loss it keeps 12 ms p99 where Cubic collapses to ~4 Mbit/s and 500+ ms |
| S4 | Pass with the fallback | FFI call is free (p99 ≤ 0.4 µs); handoff to a shared multi-thread runtime fails under load (1–4 ms p99), a dedicated pinned current-thread runtime passes (≤ 0.4 ms p99) |
| S5 | Pass, with one config change | Path events arrive within 1 ms and per-path RTT/loss and direct vs relayed are all public API; a dead direct path takes 15 s to detect on defaults, 300 ms with a lower idle timeout |
| S6 | Pending | Needs a Windows GPU host |
| S7 | Pass, with non-obvious settings | M3 Max, real SCK capture at 1080p60: encode p99 6.75 ms (H.264) and 4.99 ms (HEVC), but only with `RealTime=false` and low-latency rate control off; with them on, 15.5 ms. Code only on Jeff's Mac |
| S8 | VideoToolbox done; NVENC, AMF, oneVPL pending | VideoToolbox: per-frame bitrate without IDR passes, intra-refresh fails, long-term refs pass on the low-latency path |
| S9 | Pending | Needs the S6 Windows host |

**S1: shim builds and links** ([`spikes/s1-shim`](../spikes/s1-shim/README.md), [`shim/README.md`](../shim/README.md))

- Findings: iroh pinned at 1.4.1 with default features off (`tls-ring`, `portmapper`, `fast-apple-datapath` added back). Linux links Zig's bundled libunwind instead of `libgcc_s`; Zig `*-windows-gnu` maps to Rust `*-pc-windows-gnullvm`. `iroh_conn_local_drops` counts only the shim's own inbound queue.
- Implications: static linking stays the default with a dynamic option already built in. Still owed: macOS and Windows arm64 CI, and archive sizes, before the "ship as DLL" fallback can be ruled out.

**S2: datagram queueing and drops** ([`spikes/s2-datagram-queueing`](../spikes/s2-datagram-queueing/README.md))

- Findings: median overhead 30–50 µs. Added p99 stays under 2 ms up to ~91% of wire capacity; at 96–98% it fails at 1 ms RTT (2.2–3.0 ms). Once Cubic backs off below the offered rate, iroh's 1 MiB datagram send buffer fills and adds 100–140 ms one-way while QUIC's RTT stays flat. Send-buffer evictions and receive-buffer drops are not counted anywhere. Slow start overshoots in the first ~200 ms. `datagram_send_buffer_space()` over-reports (noq bug, worth an upstream issue).
- Implications: the rate controller must own the send rate, stay ~10% under capacity and use our own one-way delay timestamps, not QUIC RTT. The shim sets a small send buffer (64 KiB or one frame) and counts drops itself (`sent − frame_tx.datagram`, `frame_rx.datagram − read`, plus media sequence numbers). Streams start below target. The "every drop visible in stats" criterion is met by the shim, not iroh.

**S3: custom congestion control** ([`spikes/s3-congestion`](../spikes/s3-congestion/README.md))

- Findings: `QuicTransportConfig::builder().congestion_controller_factory(..)` installs a controller with no forks; per-connection configs work on both connect and accept. The `AppRate` controller paces at an externally set target, sizes the window at 2× BDP and counts loss without cutting. noq builds one controller per path, and the factory doesn't know which connection it serves.
- Implications: the noq-proto fallback is not needed for congestion control. The shim gets `set_target_bitrate(conn, bps)` and per-path controller counters, applies the target to the selected path, and uses one factory per session. This retires the top risk ("QUIC CC fights our rate controller"), pending the S2 rerun with `AppRate`.

**S4: FFI and runtime handoff jitter** ([`spikes/s4-ffi-jitter`](../spikes/s4-ffi-jitter/README.md))

- Findings: all the cost is the cross-thread wakeup, not FFI or tokio. A dedicated current-thread runtime on a pinned real-time thread gives 0.1–0.4 ms p99 in every case; unpinned or multi-thread runtimes fail under CPU load. p99.9 is 1–3 ms on every wakeup path, likely the cloud VM's vCPU wake cost.
- Implications: the dedicated runtime is the shim's default design, not a fallback (S1 already adopted it, with a start hook so the host can pin it and set its priority). `send_datagram` is called directly on the caller's thread. Budget 0.1–0.4 ms for this hop; recheck the tail on bare metal and on the S6/S7 hosts.

**S5: path visibility** ([`spikes/s5-path-stats`](../spikes/s5-path-stats/README.md))

- Findings: `path_events()` (Opened/Selected/Closed/Lagged), `is_relay()` and per-path `PathStats` are all public; events land within 1 ms of the change on the wire. A blackholed direct path is invisible until the per-path idle timeout (15 s default) while `send_datagram` keeps returning Ok. A 150–300 ms idle timeout did not flap under 5% loss on loopback. Relay paths report zero loss, so relay trouble shows up only as RTT.
- Implications: the "patch shim for noq path stats" fallback is not needed. The shim sets `default_path_max_idle_timeout` to 300 ms and keepalive to 100 ms, forwards path events to Zig, samples `stats()` on the network thread, and exposes a "no ack progress" signal so the core can react before iroh switches paths. Re-check the idle timeout at real internet RTTs and through real NATs.

**S7: macOS host encode baseline** ([`spikes/s7-macos-encode`](../spikes/s7-macos-encode/README.md))

- Findings: on an M3 Max with real SCK capture at 1080p60, encode p50/p95/p99 is 6.24/6.57/6.75 ms (H.264) and 4.47/4.80/4.99 ms (HEVC) with `RealTime=false` and low-latency rate control off; with them on, 14.1/14.9/15.5 ms. SCK capture has a late tail (p99 9.6 ms) that drives vsync-to-encoded p99 to 15.7 ms. Without low-latency rate control, frames spike up to 3x; a `DataRateLimits` cap of one frame's budget fixes the spikes but undershoots the average bitrate. The probe and raw data live only on Jeff's Mac.
- Implications: the macOS backend uses the regular hardware encoder, RealTime off, a per-frame size cap, and HEVC where the client supports it. The capture tail is now the largest p99 contributor and needs its own look. Intel Macs untested.

**S8: encoder feature matrix** ([`spikes/s8-encoder-controls`](../spikes/s8-encoder-controls/README.md))

- Findings (VideoToolbox, H.264 and HEVC): bitrate changes between frames take effect with no IDR and settle within 0–11 frames. Intra-refresh fails on both: there is no public key, the private HEVC key is ignored, and the low-latency refresh setting emits periodic IDRs. Long-term refs pass on both, but only on the low-latency encoder path: recovery frames are 52–90 KB versus about 320 KB for an IDR, and the output is bit-exact afterwards. Apple's HEVC decoder breaks permanently if fed frames after a gap. NVENC, AMF and oneVPL are pending a Windows GPU host.
- Implications: no periodic keyframes and no intra-refresh on macOS; loss recovery is LTR ack plus `ForceLTRRefresh`, IDR as last resort. The protocol needs a client-to-host ack message carrying each frame's LTR token, which is a VideoToolbox sample attachment and so must travel in our video header, not the bitstream. Clients freeze decode on a gap until the recovery frame arrives (required for VT HEVC, harmless elsewhere).

**Open conflict between S7 and S8.** S7's fast settings use the regular encoder, but S8 found long-term refs exist only on the low-latency path, which S7 measured at 15.5 ms p99 with RealTime on. Before the macOS backend is built, measure the low-latency path with `RealTime=false` and real capture. If it stays slow, macOS has to choose per session between fast encode with IDR recovery and slower encode with LTR recovery.

**Still to run:** S6 and S9 need a Windows GPU host, which also fills in S8's NVENC, AMF and oneVPL rows and reruns S4 on target hardware.


## Implementation plan

Seven phases after the spikes, each ending at a measurable gate; the first usable product is a Windows-to-Windows LAN stream at the end of Phase 2. Sizes are rough estimates for two engineers, to be redone after the spikes.

*(Diagram: roadmap · spikes and 7 phases, not to scale.)*

Phases run in order; Phase 2 (highlighted) is the first point where someone can actually stream.

### Phase 1: Foundations (about 3 weeks)

- Repo layout, `build.zig`, CI matrix for all targets, shim release pipeline and `build.zig.zon` wiring.
- Shim v0.1 with the draft C ABI; `PacketPipe` with iroh and simulated implementations.
- Core skeleton: `proto` with stream IDs, wire spec v0 in `/spec`, `clock`, telemetry types.
- Simulation harness: seeded loss, jitter, reordering, bandwidth steps; runs in CI.

**Gate:** two processes exchange stream-tagged datagrams over iroh and over the sim pipe; CI green on every target.

### Phase 2: Windows LAN MVP (about 5 weeks)

- Host: Desktop Duplication, NVENC (H.264/HEVC), WASAPI loopback, SendInput.
- Client: D3D11VA, flip-model presentation, raw input, audio out.
- Packetizer, reassembly, NACK/retransmit, fixed bitrate; Opus audio; keyboard and mouse input.
- Latency overlay showing every stage.

**Gate:** glass-to-glass within 5 ms of Moonlight at 1080p60 on wired LAN; one hour without a freeze.

### Phase 3: Internet-grade (about 6 weeks)

- Delay-gradient rate controller with the bitrate, resolution, frame-rate ladder.
- Adaptive Reed-Solomon FEC and path-based choice between NACK and FEC.
- Sender pacing; relay mode; reconnect and path-change handling.
- Pairing with tickets and PIN/QR, host allowlist, self-hosted relay deployment.

**Gate:** sim suite passes (no freeze over 500 ms at 5% random loss; bitrate recovers within 2 s after a bandwidth halving); field tests on cable, LTE and hotel-grade Wi-Fi.

### Phase 4: macOS host and more clients (about 5 weeks)

- Host: ScreenCaptureKit, VideoToolbox, CGEvent input.
- Clients: macOS (VideoToolbox, Metal) and Linux (VAAPI, Wayland/EGL).
- Gamepads on all clients; virtual gamepad on Windows host (driver path decided in Phase 3).

**Gate:** every host/client pair in the target table streams with the Phase 2 latency bar.

### Phase 5: Quality and recovery (about 5 weeks)

- Reference frame invalidation and intra-refresh per encoder backend; AV1 where available.
- 4:4:4 and HDR; AMF and oneVPL encoders.
- Virtual displays (IddCx on Windows, CGVirtualDisplay on macOS); multi-monitor; clipboard; multi-user sessions.

**Gate:** loss recovery without keyframe spikes on NVENC and VideoToolbox; headless host works.

### Phase 6: Web client (about 4 weeks)

- wasm-bindgen iroh crate; Zig core in WASM; WebCodecs, libopus WASM, Worker rendering.
- Pointer Lock, Keyboard Lock, Gamepad API.

**Gate:** Chrome, Firefox and Safari play 1080p60 over a self-hosted relay; latency recorded against the native client.

### Phase 7: Linux host and hardening (about 5 weeks)

- Linux host: PipeWire capture, VAAPI/NVENC, uinput.
- Fuzzing of every parser; external security review of pairing and the shim boundary.
- Packaging, code signing, driver signing, notices; public C ABI frozen as 1.0.

**Gate:** fuzzing clean for a week of CPU time; signed installers on all host platforms.

## Risks, open questions and decisions

The biggest risk is QUIC congestion control fighting our rate controller; spikes S2 and S3 retire it first.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| QUIC congestion control and our rate controller conflict | Latency spikes or capped bitrate | S2/S3; custom controller in shim; noq-proto fallback |
| Windows virtual gamepad and IddCx display drivers need signing | No gamepads or headless host on Windows | Decide driver route by Phase 3; ship without until signed |
| macOS private API (CGVirtualDisplay) changes | Headless macOS host breaks on an OS update | Feature-flag it; test on every macOS beta |
| Relay quality for browsers | Stutter on lossy networks | Self-hosted regional relays; set expectations in UI |
| Zig stdlib churn | Rework on upgrade | Pin one Zig version per release; sans-I/O core limits exposure |
| Rust/Zig ABI and linking on Windows | Build breakage | S1 decides static vs DLL |

**Open questions**

- Which encoders must support RFI and intra-refresh for launch? (S8 answers.)
- Do we run our own discovery (DNS/pkarr) or rely on n0's public services?
- Multi-user sessions: one shared input owner, or input from all guests?
- License for the project itself?

**Decision log**

| Decision | Why |
| --- | --- |
| Rust iroh through an in-repo shim, not a Zig port | Weeks instead of months; n0's NAT hardening for free; port stays possible behind `PacketPipe` |
| Shim binaries as CI artifacts via `build.zig.zon` | Static archives are too large to commit; hash-pinned and per-target |
| Sans-I/O Zig core with dedicated threads | Deterministic simulation, WASM reuse, no dependence on Zig async |
| Web client relay-only over iroh | One transport and one stack; no WebRTC on the host |
| Voice chat out of scope | Reserved stream ID keeps it addable later |

**Sources**

- [Parsec technical overview](https://support.parsec.app/hc/en-us/articles/32361354307348-Overview)
- [Parsec: BUD networking protocol](https://blog.parsec.app/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007/)
- [Wolf: Moonlight protocol docs](https://games-on-whales.github.io/wolf/stable/protocols/index.html)
- [Iroh 1.0: Dial Keys, Not IPs](https://pinggy.io/amp/blog/iroh_1_0_dial_keys_not_ips/)
- [iroh: WebAssembly and browsers](https://docs.iroh.computer/languages/wasm-browser)
- [iroh C bindings](https://docs.iroh.computer/languages/c)
- [noq-proto docs](https://docs.rs/noq-proto/latest/noq_proto/)
- [Zig 0.16 I/O interface write-up](https://www.youngju.dev/transcribe/2026-07-16-zig-016-io-interface.en)
