# Low-Latency Streaming in Zig — Design & Plan

Nov 7, 2026 · @Jeff Lindsay

## Summary

We build a low-latency remote desktop and game streaming core library in Zig, with both host and client, that pairs Parsec's internet-first networking with Moonlight/Sunshine's media quality and openness. Networking uses Rust iroh through an in-repo shim that also owns QUIC congestion control and packet pacing; the rest of the latency-critical path (capture, encode, packetization, FEC, rate control, decode, present) is Zig. The Zig core decides the sending rate and the shim paces to it.

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
- A Zig port of iroh or noq; the transport spikes passed, so this stays off the table.
- WebRTC or WebTransport browser paths.
- Moonlight/GameStream protocol compatibility.
- Mobile clients and a hosted account service.

## What we take from Parsec and Moonlight/Sunshine

Both products run the same basic pipeline; Parsec wins over the internet because its transport and encoder share one feedback loop, and Moonlight/Sunshine wins on quality ceiling and openness.

| Idea | From | How we use it |
| --- | --- | --- |
| Transport feeds the encoder within milliseconds | Parsec ([BUD](https://blog.parsec.app/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007/)) | Delay-based rate controller in the Zig core drives per-frame encoder reconfiguration and the shim's pacing rate |
| Priority order: latency, then frame rate, then quality | Parsec | Encoded in the rate controller's response ladder |
| Zero-copy capture into the hardware encoder | Parsec ([overview](https://support.parsec.app/hc/en-us/articles/32361354307348-Overview)) | GPU textures/surfaces go straight to the encoder on every host OS |
| Peer-to-peer with NAT traversal and relay fallback, no setup | Parsec | iroh: dial by Ed25519 key, QUIC hole punching, relays |
| Reed-Solomon FEC per frame | Moonlight ([protocol notes](https://games-on-whales.github.io/wolf/stable/protocols/index.html)) | Adaptive FEC on WAN paths |
| Reference frame invalidation instead of keyframes | Moonlight | Long-term references acked by the client; IDR only as last resort (no intra-refresh) |
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
   - `recovery`: long-term reference bookkeeping, LTR acks, RFI, IDR fallback.
   - `pacing`: the pacing rate handed to the transport (the shim does the pacing) and the client's present policy.
   - `input`: event model, redundancy, gamepad state snapshots.
   - `clock`: host/client clock offset for one-way delay and end-to-end latency.
3. **Transport** (`PacketPipe`: send, receive, set pacing rate, path stats and drop counts). Implementations: iroh shim (production), simulated pipe (tests), and a native UDP pipe reserved as a fallback.
4. **Platform**: host (capture, encode, audio in, input injection, virtual display, cursor) and client (decode, present, audio out, input capture).

**Threading**

Each pipeline stage gets a dedicated OS thread connected by lock-free single-producer/single-consumer rings: capture, encode, network, decode, present, audio. Threads run at elevated priority (MMCSS on Windows, QoS classes on macOS). iroh runs on its own single-threaded (current-thread) tokio runtime on a thread the shim creates; a start hook lets the host pin that thread and give it real-time priority. The network stage calls `send_datagram` directly on its own thread. S4 measured this hop at 0.1–0.4 ms p99; a shared multi-thread runtime added 1–4 ms under load. We do not depend on Zig's `std.Io` evented backends; Zig 0.16 shipped only the threaded implementation for production use ([release notes summary](https://www.youngju.dev/transcribe/2026-07-16-zig-016-io-interface.en)).

**Why sans-I/O**

- Deterministic simulation: seeded loss, jitter and bandwidth-collapse scenarios run in CI against the real core.
- The same core compiles to `wasm32` for the browser client unchanged.
- Transports can be swapped without touching media logic.

## Transport

We use Rust iroh 1.x (pinned at 1.4.1) through a Rust shim that lives in the repo and exposes exactly the C ABI we need. iroh gives us key-based identity, discovery, QUIC NAT traversal, multipath and relays with a stable wire protocol ([iroh 1.0](https://pinggy.io/amp/blog/iroh_1_0_dial_keys_not_ips/)). Spikes S2 to S5 confirmed iroh works for media, but only with the shim doing more than wrapping it, so the shim is thicker than first planned.

**What iroh carries**

- Identity and pairing: endpoint ID = Ed25519 key; pairing adds a client key to the host allowlist via PIN or QR ticket.
- Discovery: DNS/pkarr and self-hosted relays; mDNS for LAN.
- Control: reliable QUIC streams for session setup, clipboard, display config and file transfer.
- Media: unreliable QUIC datagrams, tagged with stream IDs.

**What the shim owns**

- **Congestion control.** iroh's default controller (Cubic) let a 1 MiB datagram send buffer hide 100–140 ms of queueing while QUIC's RTT stayed flat (S2). The shim installs our own controller (S3's `AppRate`) through iroh's public transport-config builder. It paces at a target rate the core sets, sizes the window at 2× BDP and counts loss without cutting the rate.
- **Pacing.** The target rate is the core's estimate of link capacity, not the encoder bitrate; pacing at the encoder bitrate stretches every frame across the whole frame interval. The core keeps the encoder below that rate. iroh builds one controller per network path, so the shim applies the target to whichever path is selected and moves it when the path changes.
- **Drop accounting.** iroh counts neither send-buffer evictions nor receive-buffer drops. The shim counts its own (datagrams sent minus datagrams on the wire, datagrams received minus datagrams read) and reports them with path stats; media sequence numbers catch the rest.
- **Buffers and timeouts.** The datagram send buffer holds at least the largest frame at the top bitrate (S10: a 64 KiB buffer evicted 62% of an 85 Mbit/s 60 fps stream). The core's own queue bounds delay by age, so an encoder that outruns the target cannot build a ~90 ms queue, and the shim counts every eviction. Per-path idle timeout 300 ms (iroh's default is 15 s, during which a dead direct path looks healthy) and keep-alive 100 ms. Under review after S5b and S5c: 300 ms also closes the direct path on 200–400 ms outages, and stock iroh then takes 9–60 s to punch a new one. S5c's data for the decision is under S5c below.
- **Runtime threading.** One dedicated current-thread runtime per process, started through `iroh_shim_init` with the host's thread-start hook (see Threading).

The core still owns the rate decision. Its controller uses our own one-way delay from capture and send timestamps, not QUIC's RTT, which stays flat while the send buffer fills.

**Shim C ABI (draft)**

- Endpoint: `bind(secret_key, alpns, relay_urls)`, `connect(ticket)`, `accept()`, `close()`.
- Datagrams: `send_datagram(conn, buf, len)`, `recv_datagram(conn, buf, cap)` (non-blocking, with a wakeup fd/handle).
- Streams: open/accept bidirectional, read, write, finish.
- Rate: `set_target_bitrate(conn, bps)`, applied to the selected path's controller.
- Path stats: RTT, loss, congestion window, direct vs relayed, per-path controller counters, shim-counted send and receive drops, a "no ack progress" signal; path changes (opened, selected, closed) as events, which S5 saw arrive within 1 ms of the change on loopback and S5b within two RTTs over a real NAT.
- Config: datagram buffer sizes, path idle timeout and keep-alive.
- Runtime: `iroh_shim_init(on_thread_start, ctx)` before anything else.
- Built with `panic = "abort"`; Zig owns every buffer that crosses the boundary.

**Relay mode**

Relayed paths run over HTTPS/WebSocket on TCP, so there is head-of-line blocking but no packet loss. A public n0 relay carried about 8 Mbit/s in S5b, with 2–3 s of queue when offered 18 Mbit/s. When the path is relayed the core turns FEC off, caps bitrate, prefers lower resolution, and shows a relay badge in the overlay. Browser clients are always in this mode.

**Fallback**

If iroh later stops working for media, a native Zig UDP media pipe can replace it behind `PacketPipe`, with iroh kept for signaling and control.¹

¹ The original plan also listed a shim over `noq-proto` with a Zig driver and Zig congestion controller ([noq-proto](https://docs.rs/noq-proto/latest/noq_proto/)). S3 showed a custom controller installs through iroh's public API, so that fallback is no longer needed.

## Media pipeline

The pipeline never buffers: every frame is encoded, sent, decoded and presented as soon as it exists, and the rate controller keeps the network queue near empty.

**Wire format**

- Every datagram carries a stream ID (video, audio, input, control-fast; mic reserved), so new streams need no protocol bump.
- Video packets are about 1150 bytes to fit any QUIC datagram path.
- Video header: frame ID, slice, shard index, FEC group, capture timestamp, encode-done timestamp, long-term reference token.
- Frame ack (client to host, control-fast stream): the LTR tokens of frames the client decoded. VideoToolbox returns the token as a sample attachment, not in the bitstream, so it has to travel in our header.

**Encoder settings**

- No B-frames, no lookahead, one-frame VBV.
- Multiple slices per frame so packetizing starts before encode finishes.
- No periodic keyframes; long-term references for recovery. No intra-refresh as a baseline: VideoToolbox has none that works (S8), and the Windows encoders are untested.
- Per-frame bitrate reconfiguration without forcing a keyframe (VideoToolbox settles within 0–11 frames).
- Codecs: H.264 and HEVC first, AV1 where the encoder supports it; 4:4:4 and HDR later.

**Loss recovery**

- RTT under about a quarter of the frame interval: NACK and selective retransmit.
- Otherwise: Reed-Solomon FEC, overhead set from measured loss (0 to 30%).
- Unrecoverable frame: the client stops decoding at the gap. The host encodes the next frame against the newest acked long-term reference (`ForceLTRRefresh` on VideoToolbox), which was 52–90 KB in S8 versus about 320 KB for an IDR. IDR only as last resort, or for a backend without long-term references.
- The client drops every frame after a gap until that recovery frame arrives. Apple's HEVC decoder breaks permanently if fed frames after a gap, and dropping is harmless on other decoders, so all clients do it.
- Relayed path: no FEC (TCP underneath).

**Rate control**

- The client sends transport-wide feedback every 5 to 10 ms with per-packet arrival times.
- The host runs a delay-gradient estimator (GCC-style) on our own one-way delay timestamps, not QUIC RTT, and responds in order: bitrate, then resolution, then frame rate. It keeps libwebrtc's burst grouping, without which Wi-Fi aggregation reads as overuse and halves the rate (S11, simulated).
- It produces two numbers: a capacity estimate, which becomes the shim's pacing rate, and an encoder target kept below it. The capacity estimate comes from frame packet trains: when a frame is paced faster than the bottleneck, its receive dispersion is the bottleneck rate (a 300 ms median read 1.00–1.02x capacity in S11's simulation). It measures the link, not our share of it, so it sets pacing but never the target alone.
- Stock GCC is not enough (S11, simulated): with no probing it ramps at 8%/s and holds 24–35% of capacity, and a delay gradient cannot see a queue that has stopped growing, so it leaves 40–70 ms of queue for ~4 s after a capacity drop. Two additions fix that: the target jumps to 0.85x the train estimate when there is no recent congestion (the job WebRTC's padding probes do), and an absolute standing-queue check (min OWD over 20 ms against the 10 s minimum) cuts the rate to drain the queue in ~200 ms when it stays above 30 ms for 150 ms, but backs off for 10 s if the queue doesn't fall within 1.5 s, since a loss-based flow is then filling it. Simulated, this holds 0.86x capacity on wired links and 0.74–0.76x on Wi-Fi, reaches 80% of capacity in 1.3–1.7 s, and drains a capacity drop in 0.7–0.9 s with 10.8 ms queueing p99 (wired). Thresholds are hand-tuned starting points; real Wi-Fi validation is pending.
- At a given utilization, frame transport time is about (encoder rate / capacity) x the frame interval, whatever the pacing, so the encoder target's share of the estimate trades bitrate for frame delay (S11: 88% gives a 16 ms frame p50 at 60 fps, 60% about 10 ms). The controller must be told that share, or its acked-rate rules read an app-limited stream as a smaller link and spiral down.
- Streams start below target and ramp up, since there is no QUIC slow start to probe for them. The train estimate ramps in about 1.5 s, versus over 20 s for GCC's multiplicative increase.
- Targets are bounded by user settings and by what the path reports, including shim-counted drops.

**Pacing and presentation**

- The shim paces every path at the capacity estimate, so a frame leaves at link rate instead of in a burst. S2 measured 0.9–2.6 ms added p99 over raw UDP for this; occasional 5–23 ms pacer stalls on a shared runtime are still to recheck on the dedicated one.
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
| Capture | Desktop Duplication / Windows.Graphics.Capture (D3D11 textures) | ScreenCaptureKit (IOSurface); late-frame tail needs handling | PipeWire portal; KMS grab optional |
| Encode | NVENC (runtime-loaded), AMF, oneVPL; Media Foundation fallback (all untested) | VideoToolbox: low-latency encoder with LTR, RealTime on, ExpectedFrameRate 1000 (S7b); HEVC preferred | VAAPI, NVENC; Vulkan Video later |
| Audio capture | WASAPI loopback | ScreenCaptureKit audio | PipeWire |
| Input injection | SendInput; virtual gamepad needs a signed driver | CGEvent (Accessibility permission); gamepad limited | uinput |
| Virtual display | IddCx driver (signing required) | CGVirtualDisplay (private API) | Compositor headless output |
| Decode | D3D11VA | VideoToolbox | VAAPI; Vulkan Video later |
| Present | Flip-model swapchain, waitable object, tearing allowed | CAMetalLayer | Wayland/EGL or Vulkan |
| Input capture | Raw Input; gamepads via SDL3 or GameInput | NSEvent / GameController | evdev via SDL3 |

**macOS encode and capture (S7, S7b, S8)**

- On an M3 Max at 1080p60, the regular encoder with `RealTime=false` and low-latency rate control off encodes at 6.75 ms p99 (H.264) and 4.99 ms (HEVC). With RealTime on, or on the low-latency path, it is 15.5 ms.
- Without low-latency rate control, frame sizes spike up to 3×; a `DataRateLimits` cap of one frame's budget fixes the spikes but undershoots the average bitrate.
- Long-term references exist only on the low-latency path (S8). There, `RealTime=false` does not help (it adds long tails), but `ExpectedFrameRate=1000` with `RealTime=true` brings encode with LTR on to 8.6 ms p99 (HEVC) and 8.1–10.9 ms (H.264), about 2–4 ms slower than the regular encoder. LTR recovery stays bit-exact there (S7b).
- ScreenCaptureKit sometimes delivers a frame late (capture p99 9.6 ms), which is now the largest contributor to p99. The capture stage has to time-stamp and tolerate late frames rather than assume a steady cadence.
- Intel Macs untested.

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
- Release profile: `opt-level = "s"`, fat LTO, one codegen unit, `panic = "abort"`, debug info stripped; iroh default features off, `tls-ring`, `portmapper` and `fast-apple-datapath` added back.
- Compressed archives (S1): Linux 8.6–9.0 MB, Windows 6.5–6.9 MB, macOS universal 14.3 MB.
- Crypto backend: ring (simpler to cross-compile than aws-lc-rs).

**Linking rules**

Static linking is the default and works on all five targets (S1); a dynamic library is also built and tested, for anyone who needs it.

- Windows: Zig `*-windows-gnu` pairs with Rust `*-pc-windows-gnullvm`; link `ws2_32`, `bcrypt`, `ntdll`, `userenv`.
- macOS: same `MACOSX_DEPLOYMENT_TARGET` on both sides; `lipo` into a universal library.
- Linux: build against an old glibc or musl; link Zig's bundled libunwind instead of `libgcc_s`.
- CI on Windows arm64 runs the x86_64 Zig under emulation, because the native Zig 0.16.0 binary segfaults there. Revisit on each Zig upgrade.

**Licensing**

- iroh and noq are MIT/Apache-2.0; ring has its own terms. CI generates a third-party notices file (for example with `cargo-about`) shipped with every build.

## Initial spikes

Nine time-boxed spikes, roughly three to four weeks in total, settle the decisions that are expensive to reverse; the transport spikes (S2 to S5) decide whether Rust iroh stays. Pass thresholds are proposed starting points to confirm in review.

As of Nov 7, 2026, S1 to S5, S5's real-network rerun S5b, S7 and its follow-up S7b, and S10 have run and iroh stays (for media too: S10), with the shim changes described under Transport. S8 has run on VideoToolbox only. S11 (capacity estimation, added after the original plan) has run in simulation; its real Wi-Fi run is pending. S6, S9 and S8's Windows rows need a Windows GPU host. The table below is the original plan; results are under Spike status.

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

Updated Nov 8, 2026. Each spike's write-up, code and raw results are under [`spikes/`](../spikes); S1's code is the real shim at the repo root.

| # | Status | Headline |
| --- | --- | --- |
| S1 | Pass | Shim links into Zig 0.16 statically and dynamically; 500/500 datagram echo passes on all five targets (Linux x64/arm64, Windows x64/arm64, macOS universal). Release archives are 6.5–14.3 MB compressed |
| S2 | Pass with `AppRate`, one open item | With Cubic, a 1 MiB send buffer hides 100–140 ms of queueing at the cap and evictions are uncounted. With S3's `AppRate` the hidden queue is gone and every bottleneck drop is counted, but its pacer adds 1–3 ms p99 to frame bursts and stalls 5–23 ms now and then on smooth traffic; likely the shared runtime (see S4), to recheck |
| S3 | Pass | A custom congestion controller installs through iroh's public builder and holds a target rate on a live connection; under 2% loss it keeps 12 ms p99 where Cubic collapses to ~4 Mbit/s and 500+ ms |
| S4 | Pass with the fallback | FFI call is free (p99 ≤ 0.4 µs); handoff to a shared multi-thread runtime fails under load (1–4 ms p99), a dedicated pinned current-thread runtime passes (≤ 0.4 ms p99) |
| S5 | Pass, with one config change | Path events arrive within 1 ms and per-path RTT/loss and direct vs relayed are all public API; a dead direct path takes 15 s to detect on defaults, 300 ms with a lower idle timeout |
| S5b | Pass on punching and stats; idle timeout open | Real NAT pair (MacBook at home ↔ AWS VM, 75 ms RTT): 16/16 connections hole-punched, direct 0.53–0.55 s after dialing; path RTT and loss match app probes; 300 ms detects a dead path in 295–377 ms and had 0 false switches in a 10-minute 18 Mbit/s soak, but closes on 200–300 ms blackouts, and iroh takes 9–60 s to re-punch after any close |
| S5c | Data gathered; decision open | Lab with two NATs, local relay, 75/150/250 ms RTT, 324 blackouts. The idle setting is a floor: noq uses max(idle, 3×PTO), so "300 ms" closes a dead path in 342/606/955 ms and "1000 ms" in 1038/1076/1125 ms. 300 closes on outages from 200–400 ms, 1000 from 800–1000 ms. Every close costs 21–57 s on the relay with stock iroh at either setting; a prototype re-punch patch brings that to 0.13–1.07 s after the outage ends |
| S6 | Pending | Needs a Windows GPU host |
| S7 | Pass, with non-obvious settings | M3 Max, real SCK capture at 1080p60: encode p99 6.75 ms (H.264) and 4.99 ms (HEVC), but only with `RealTime=false` and low-latency rate control off; with them on, 15.5 ms |
| S7b | Close, not quite | Low-latency encoder with LTR on (S7/S8 follow-up): 8.6 ms p99 HEVC, 8.1–10.9 ms H.264 with `RealTime=true` and `ExpectedFrameRate=1000`; 101/101 simulated losses recovered bit-exact |
| S8 | VideoToolbox done; NVENC, AMF, oneVPL pending | VideoToolbox: per-frame bitrate without IDR passes, intra-refresh fails, long-term refs pass on the low-latency path |
| S9 | Pending | Needs the S6 Windows host |
| S10 | Done: keep iroh for media | noq-proto driven from Zig (Zig owns socket, timers, pacer, drops) beats iroh + `AppRate` on its pinned runtime by ~0.9 ms p99 on frame bursts (1.3 vs 2.2 ms over raw UDP; 0.6 ms with one frame of pacer credit), counts every drop, and halves the hand-off tail (62–202 µs; 11–30 µs when the media thread sends inline). But iroh's socket can't be shared without a fork, and a second socket's hole punch only worked through port-preserving NATs, so a relay path over iroh is still needed. Not worth a second traversal path. Found along the way: the 64 KiB send buffer evicts 62% of an 85 Mbit/s frame stream, and S2's pacer stalls are host scheduling, not tokio |
| S11 | Simulation done; real Wi-Fi pending | Stock GCC holds only 24–35% of capacity and leaves a standing queue after drops. GCC plus a frame-train capacity estimate and a standing-queue drain holds 0.86x capacity wired and 0.74–0.76x on simulated Wi-Fi, reaches it in ~1.5 s and drains a drop in 0.7–0.9 s at 10.8 ms queueing p99; it still gets only ~55% of its fair share against a Reno flow |

**S1: shim builds and links** ([`spikes/s1-shim`](../spikes/s1-shim/README.md), [`shim/README.md`](../shim/README.md))

- Findings: iroh pinned at 1.4.1 with default features off (`tls-ring`, `portmapper`, `fast-apple-datapath` added back). Linux links Zig's bundled libunwind instead of `libgcc_s`; Zig `*-windows-gnu` maps to Rust `*-pc-windows-gnullvm`. `iroh_conn_local_drops` counts only the shim's own inbound queue.
- Implications: static linking stays the default with a dynamic option already built and tested, so the "ship as DLL" fallback is not needed. Compressed release archives: Linux 8.6–9.0 MB, Windows 6.5–6.9 MB, macOS universal 14.3 MB; static `shim-echo` executables are 5.4–13.9 MB. Windows arm64 CI runs the x86_64 Zig under emulation, because the native Zig 0.16.0 binary segfaults there. Next: tag `shim-v0.1.0` and wire `-Dshim=prebuilt`.

**S2: datagram queueing and drops** ([`spikes/s2-datagram-queueing`](../spikes/s2-datagram-queueing/README.md))

- Findings (Cubic, iroh default): median overhead 30–50 µs; added p99 under 2 ms up to ~91% of wire capacity, failing at 96–98% on 1 ms RTT (2.2–3.0 ms). Once Cubic backs off below the offered rate, the 1 MiB datagram send buffer fills and adds 100–140 ms one-way while QUIC's RTT stays flat; send-buffer evictions and receive-buffer drops are not counted anywhere. Slow start overshoots in the first ~200 ms. `datagram_send_buffer_space()` over-reports (noq bug, worth an upstream issue).
- Findings (S3's `AppRate`): at and above the cap iroh now behaves like raw UDP. Overload lands in the network queue (37–76 ms p99 instead of Cubic’s 60–147; a 50% overload still evicts), there are no send-buffer evictions, and QUIC `lost_packets` matches the bottleneck's drop count exactly. If the encoder outruns the target, the send buffer is the queue again (86–97 ms at 1 MiB, 15–17 ms at 64 KiB, evictions uncounted). Below the cap, pacing at the encoder rate stretches each 60 fps frame over ~16 ms (frame p99 up to 3× Cubic's); pacing at the capacity estimate fixes most of that but still adds 0.9–2.6 ms p99 over UDP (Cubic: 0.5–0.8). Smooth runs show occasional 5–23 ms sender-side stalls with no loss, probably the rate-mode pacer losing credit when the shared tokio runtime wakes late (unverified).
- Implications: use `AppRate`, with its pacing rate set from the core's capacity estimate (not the encoder bitrate) and the encoder kept under it. The rate controller uses our own one-way delay timestamps, not QUIC RTT. The shim keeps a 64 KiB send buffer and still counts evictions (`sent − frame_tx.datagram`, `frame_rx.datagram − read`, plus media sequence numbers). Streams start below target. S10 reran these cases on the pinned runtime: the stalls remain and also hit a Zig thread with no tokio (host scheduling), and S10 found that 64 KiB is too small for frame bursts.

**S3: custom congestion control** ([`spikes/s3-congestion`](../spikes/s3-congestion/README.md))

- Findings: `QuicTransportConfig::builder().congestion_controller_factory(..)` installs a controller with no forks; per-connection configs work on both connect and accept. The `AppRate` controller paces at an externally set target, sizes the window at 2× BDP and counts loss without cutting. noq builds one controller per path, and the factory doesn't know which connection it serves.
- Implications: the noq-proto fallback is not needed for congestion control. The shim gets `set_target_bitrate(conn, bps)` and per-path controller counters, applies the target to the selected path, and uses one factory per session. This retires the top risk ("QUIC CC fights our rate controller"); the S2 rerun confirmed it removes the hidden queue, with pacer stalls still to check on S4's runtime.

**S4: FFI and runtime handoff jitter** ([`spikes/s4-ffi-jitter`](../spikes/s4-ffi-jitter/README.md))

- Findings: all the cost is the cross-thread wakeup, not FFI or tokio. A dedicated current-thread runtime on a pinned real-time thread gives 0.1–0.4 ms p99 in every case; unpinned or multi-thread runtimes fail under CPU load. p99.9 is 1–3 ms on every wakeup path, likely the cloud VM's vCPU wake cost.
- Implications: the dedicated runtime is the shim's default design, not a fallback (S1 already adopted it, with a start hook so the host can pin it and set its priority). `send_datagram` is called directly on the caller's thread. Budget 0.1–0.4 ms for this hop; recheck the tail on bare metal and on the S6/S7 hosts.

**S5: path visibility** ([`spikes/s5-path-stats`](../spikes/s5-path-stats/README.md))

- Findings: `path_events()` (Opened/Selected/Closed/Lagged), `is_relay()` and per-path `PathStats` are all public; events land within 1 ms of the change on the wire. A blackholed direct path is invisible until the per-path idle timeout (15 s default) while `send_datagram` keeps returning Ok. A 150–300 ms idle timeout did not flap under 5% loss on loopback. Relay paths report zero loss, so relay trouble shows up only as RTT.
- Implications: the "patch shim for noq path stats" fallback is not needed. The shim sets `default_path_max_idle_timeout` to 300 ms and keepalive to 100 ms, forwards path events to Zig, samples `stats()` on the network thread, and exposes a "no ack progress" signal so the core can react before iroh switches paths. Re-check the idle timeout at real internet RTTs and through real NATs (done in S5b, below).

**S5b: S5 across a real network** ([`spikes/s5b-path-stats-wan`](../spikes/s5b-path-stats-wan/README.md))

- Setup: MacBook Pro behind a home NAT ↔ Linux VM in AWS us-west-2 behind a security group that drops unsolicited inbound UDP, n0 production relay, 71–77 ms RTT. The host applies iptables blocks, loss and blackouts to its own direct UDP port. The VM kernel has no netem, so added delay and jitter are untested.
- Findings: dialed by key + relay URL only, 16 of 16 connections hole-punched and went direct 0.53–0.55 s after dialing. Selected(direct) follows the first direct packet by ~150 ms (two RTTs of path validation). Path RTT matches probe RTT within ~0.5 ms and `lost_packets` tracks injected 2/5/20% loss. A blocked direct path closes after 295–377 ms at idle 300 (1.0 s at 1000, 15 s on defaults), and a 10-minute 18 Mbit/s soak had no false switch. But at idle 300, blackouts of 200–300 ms and above closed the direct path, and 20% loss closed it once in two runs; at idle 1000 nothing up to 600 ms did. After any close, iroh took 9–60 s to go direct again: it does not re-punch when a path is abandoned, only on its 60 s upgrade check, on address changes or on a major network change, and `Endpoint::network_change()` did not trigger it. Path RTT is network RTT only: when loss collapsed the congestion window, probe RTT reached 1–4 s while `stats().rtt` read 72 ms. The n0 relay carried ~8 Mbit/s.
- Implications: punching and stats pass. The 300 ms idle timeout is right for detection, but each false close costs up to a minute on the relay, so either the shim gets a way to re-punch right after a direct path closes (iroh exposes none; needs an upstream change or a patch), or the idle timeout moves to about 1 s and the core's "no ack progress" signal covers the first second. Undecided; the 300 ms setting stands until then. Latency signals must include the shim's send buffer, not just `stats().rtt`. Relay mode should cap well under 8 Mbit/s on public relays.

**S5c: the idle timeout decision, at long RTTs** ([`spikes/s5c-idle-timeout`](../spikes/s5c-idle-timeout/README.md))

- Setup: network namespaces on one VM. S10's two Linux NATs (neither forwards a port), a local iroh-relay with QUIC address discovery, and a userspace L2 delay line (no netem in the kernel) giving 75, 150 and 250 ms RTT on both the direct and relay paths. S5b's harness: the host drops its direct UDP port for 100–2000 ms, three times per length, at idle 300 and 1000, with stock iroh 1.4.1 and with a prototype patch that re-punches when the last direct path is abandoned. At 75 ms RTT it reproduces S5b (block → relay 342 ms, 200 ms blackouts close at 300, 50–57 s to re-punch).
- Findings: the setting is a floor. noq arms the path idle timer at max(idle, 3×PTO), so a dead path closes after 342/606/955 ms at "300" and 1038/1076/1125 ms at "1000" (75/150/250 ms RTT). Outages close the path from 200 ms (75 ms RTT), 300 ms (150) and 400 ms (250) at "300", and from 800 ms (75, 150) and 1000 ms (250) at "1000". On stock iroh every close, at either setting, cost 21–57 s on the relay (median ~55 s, the 60 s upgrade check). With the patch, all 92 patched closes went direct again 0.13–1.07 s after the outage ended (0.15–2.06 s on the relay). Because the relay carries media after a close, the longest media gap at "300" is about the effective timeout (310/530/830 ms) however long the outage lasts; at "1000" it is the outage itself, up to ~1.0–1.2 s. Short outages can leave gaps longer than the outage, since the sender waits for its backed-off PTO probe.
- For the decision (not made): 300 ms + patch gives the shortest gaps and fast recovery, but carries an iroh patch and two path switches (and a relay bitrate drop on public relays) per outage of 200–400 ms or more. ~1 s on stock iroh avoids closes up to 600–800 ms, but every outage of 1 s or more (Wi-Fi roams) still costs ~20–56 s on the relay, so the re-punch problem remains, just less often. ~1 s + patch is also possible. At 250 ms RTT the two settings are within ~170 ms of each other. Untested: jitter, random loss, `AppRate` instead of Cubic, a bandwidth-limited relay, outages that also take down the relay.

**S7: macOS host encode baseline** ([`spikes/s7-macos-encode`](../spikes/s7-macos-encode/README.md))

- Findings: on an M3 Max with real SCK capture at 1080p60, encode p50/p95/p99 is 6.24/6.57/6.75 ms (H.264) and 4.47/4.80/4.99 ms (HEVC) with `RealTime=false` and low-latency rate control off; with them on, 14.1/14.9/15.5 ms. SCK capture has a late tail (p99 9.6 ms) that drives vsync-to-encoded p99 to 15.7 ms. Without low-latency rate control, frames spike up to 3x; a `DataRateLimits` cap of one frame's budget fixes the spikes but undershoots the average bitrate.
- Implications: the regular encoder is the fastest, but it has no long-term references; S7b settles which path the backend uses. The capture tail is now the largest p99 contributor and needs its own look. Intel Macs untested.

**S8: encoder feature matrix** ([`spikes/s8-encoder-controls`](../spikes/s8-encoder-controls/README.md))

- Findings (VideoToolbox, H.264 and HEVC): bitrate changes between frames take effect with no IDR and settle within 0–11 frames. Intra-refresh fails on both: there is no public key, the private HEVC key is ignored, and the low-latency refresh setting emits periodic IDRs. Long-term refs pass on both, but only on the low-latency encoder path: recovery frames are 52–90 KB versus about 320 KB for an IDR, and the output is bit-exact afterwards. Apple's HEVC decoder breaks permanently if fed frames after a gap. NVENC, AMF and oneVPL are pending a Windows GPU host.
- Implications: no periodic keyframes and no intra-refresh on macOS; loss recovery is LTR ack plus `ForceLTRRefresh`, IDR as last resort. The protocol needs a client-to-host ack message carrying each frame's LTR token, which is a VideoToolbox sample attachment and so must travel in our video header, not the bitstream. Clients freeze decode on a gap until the recovery frame arrives (required for VT HEVC, harmless elsewhere).

**S7b: macOS encode with long-term references** ([`spikes/s7b-macos-ltr-encode`](../spikes/s7b-macos-ltr-encode/README.md))

- Question: S7's fast settings use the regular encoder, but S8 found long-term refs only on the low-latency path. How fast is that path with LTR on and real capture, and does recovery still work?
- Findings: `RealTime=false` does not help on the low-latency encoder (14.5 ms p50 and tails up to 86 ms p99). The knob that matters is `ExpectedFrameRate`: at 1000 with `RealTime=true`, encode p50/p99 is 8.0/8.6 ms for HEVC (stable over two 30 s runs) and 7.6 ms / 8.1–10.9 ms for H.264 (bimodal between runs). The regular encoder in the same session was 6.55 ms (H.264) and 4.56 ms (HEVC) p99. With simulated loss and acks, 101 of 101 loss events recovered bit-exact from a non-IDR refresh frame of 63–81 KB (about 1.8x a P frame). On full-screen noise the low-latency encoder drops half its frames rather than overshoot.
- Implications: LTR on macOS costs about 2–4 ms of encode and misses the 8 ms bar by about 0.6 ms at p99 (HEVC). Decided (Nov 7, 2026): take it as the default anyway, since a loss then costs a ~1.8x P frame instead of an IDR at about 8x, and keep the regular encoder with IDR recovery as an option for near-lossless links. The backend has to handle frames the encoder drops.

**S10: media over noq-proto from Zig** ([`spikes/s10-noq-proto`](../spikes/s10-noq-proto/README.md))

- Question: should media datagrams move from iroh to `noq-proto` driven by the Zig core (the original fallback 1), with iroh kept for dialing and hole punching?
- Findings: S2 and S4 were rerun against a sans-I/O shim (noq-proto 1.4.0, the version iroh pins) and against iroh + `AppRate` on S4's pinned current-thread runtime, two runs per case. Frame bursts below the cap add 1.3 ms p99 over raw UDP with noq, against 2.2 ms with iroh. Raising the Zig pacer's credit to one frame brings it to 0.6 ms. noq's own pacer driven from the same loop scores within 0.1 ms of the Zig pacer, so the gain comes from removing tokio and from the burst policy, not from where the pacer sits. Every datagram is accounted for in all 98 noq runs (Zig queue drops + QUIC loss = TBF drops). Hand-off p99 is 62–202 µs through a pinned network thread and 11–30 µs when the media thread drives QUIC itself (iroh: 102–398 µs). iroh owns its sockets, with no demux or raw-send hook, so sharing its path needs a fork. A demo with a second Zig socket, rendezvous and cert pinning over an iroh stream, and a hole punch works through two port-preserving NATs, but only after adding TTL-limited opening probes (the naive version failed on conntrack port clashes). It fails through a port-randomizing NAT.
- Implications: media stays on iroh. Two changes come out of it. (1) The shim's datagram send buffer must hold at least the largest frame: with 64 KiB, iroh silently evicted 62% of datagrams at 85 Mbit/s 60 fps, well below the cap. The shim counts evictions (`sent − frame_tx.datagram`), and a time-based limit stays in the core's own queue. (2) Give `AppRate` about a frame of burst credit, or pace slightly above capacity, and remeasure. S2's open item is answered: the 5–23 ms stalls also hit a pinned SCHED_FIFO Zig thread with no tokio, so they come from host scheduling, to recheck on bare metal. Revisit noq-proto only if Phase 2's LAN gate misses by about 1 ms because of the transport, and then through a small iroh fork that shares the socket, not a second socket.

**S11: capacity estimation and rate control** ([`spikes/s11-capacity-estimation`](../spikes/s11-capacity-estimation/README.md))

- Question: every transport option paces at the core's capacity estimate (S2), and nothing had tested that estimate. How accurately and how fast does a delay-gradient estimator track capacity, and how much queue builds, with Wi-Fi jitter and cross traffic?
- Method: a deterministic Zig simulator (60 fps sender with scene-change frames, pacer, one droptail bottleneck with a 500 KB buffer, A-MPDU-like delivery batching and 5–60 ms radio stalls for Wi-Fi, 5 ms transport-wide feedback) over eight scenarios: capacity steps 50→20→80 Mbit/s on wired and Wi-Fi, a 2 ms-RTT LAN, random MCS fades, on/off UDP, a Reno flow and line-rate bursts. A port of libwebrtc's delay-based GCC was compared with variants and with a queue-delay-target controller, 5 seeds each. The same estimator code runs over real UDP (`s11net`).
- Findings: stock GCC holds 24–35% of capacity: it climbs at 8%/s, backs off at every scene-change frame and needs over 20 s to fill a link. Frame trains measure link capacity within 2%. Pacing at that estimate instead of 2.5x the target cuts wired queueing p99 from 35 to 10 ms, and pacing at the encoder rate backs frames up 0.5–1.4 s in the pacer. After a capacity drop, GCC's one cut leaves a standing queue the gradient can't see. An absolute standing-queue drain with a hold (ignores stalls and bursts) and a give-up (yields to loss-based flows) fixes that. That combination (`gcc-hybrid`) holds 0.86x capacity on wired, 0.74–0.76x on simulated Wi-Fi and 0.68x beside on/off UDP. It reaches 80% of capacity in 1.3–1.7 s and cuts below a new lower capacity in 300 ms, but in those 300 ms the old pacing rate fills the AP buffer to 170–200 ms. Against Reno it gets 55% of its fair share. The queue-delay controller fills the link better (0.85–0.92x) at 2.5x the wired queueing p99.
- Implications: the core's rate controller is GCC's trendline detector with burst grouping, plus the frame-train capacity estimate (pacing rate and upward jumps) and the standing-queue drain, behind one interface so the queue-delay controller can still be compared. The encoder target is a share of the controller's target that the controller knows about. The real Wi-Fi run, AQM (fq_codel) bottlenecks and Cubic/BBR competition are still open.

**Still to run:** S11's real Wi-Fi run needs a far-end receiver. S6 and S9 need a Windows GPU host, which also fills in S8's NVENC, AMF and oneVPL rows and reruns S4 on target hardware.


## Implementation plan

Seven phases after the spikes, each ending at a measurable gate; the first usable product is a Windows-to-Windows LAN stream at the end of Phase 2. Sizes are rough estimates for two engineers, to be redone after the spikes.

*(Diagram: roadmap · spikes and 7 phases, not to scale.)*

Phases run in order; Phase 2 (highlighted) is the first point where someone can actually stream.

### Phase 1: Foundations (about 3 weeks)

- Repo layout, `build.zig`, CI matrix for all targets, shim release pipeline and `build.zig.zon` wiring.
- Shim v0.1 with the draft C ABI, including `AppRate`, `set_target_bitrate`, drop counters, path events and the dedicated runtime; `PacketPipe` with iroh and simulated implementations.
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
- Capacity estimate driving the shim's pacing rate; relay mode; reconnect and path-change handling.
- Pairing with tickets and PIN/QR, host allowlist, self-hosted relay deployment.

**Gate:** sim suite passes (no freeze over 500 ms at 5% random loss; bitrate recovers within 2 s after a bandwidth halving); field tests on cable, LTE and hotel-grade Wi-Fi.

### Phase 4: macOS host and more clients (about 5 weeks)

- Host: ScreenCaptureKit, VideoToolbox, CGEvent input.
- Clients: macOS (VideoToolbox, Metal) and Linux (VAAPI, Wayland/EGL).
- Gamepads on all clients; virtual gamepad on Windows host (driver path decided in Phase 3).

**Gate:** every host/client pair in the target table streams with the Phase 2 latency bar.

### Phase 5: Quality and recovery (about 5 weeks)

- Long-term reference recovery with client acks per encoder backend; AV1 where available.
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

The original top risk, QUIC congestion control fighting our rate controller, is retired: S3's controller in the shim removes the hidden queue (S2). The biggest open risks are now on the encoder side: the 2–4 ms that long-term references cost on macOS (S7b), and whether the Windows encoders support long-term references at all.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| ~~QUIC congestion control and our rate controller conflict~~ | Latency spikes or capped bitrate | Retired by S2/S3: `AppRate` in the shim, paced at the core's capacity estimate |
| Long-term references on macOS cost 2–4 ms of encode (S7b) | LTR encode is 8.6 ms p99 (HEVC) vs 4.6 ms on the regular encoder; just over the 8 ms bar | Default to the low-latency encoder with LTR and `ExpectedFrameRate=1000`; regular encoder with IDR recovery as a per-session option; recheck on newer macOS and other M-series chips |
| NVENC, AMF or oneVPL lack usable long-term references | Keyframe spikes on loss for that backend | S8 Windows rows; IDR recovery per backend as fallback |
| Capacity estimation validated only in simulation (S11) | Real Wi-Fi stalls or aggregation could fool the train estimate or trigger needless drains | S11 real Wi-Fi run; keep thresholds configurable and log estimator state in field builds |
| Delay-based control loses to loss-based flows (S11: ~55% of fair share against Reno) | Lower bitrate on links shared with downloads | Drain give-up already avoids starvation; consider a loss-based floor while a foreign queue persists; test Cubic/BBR and fq_codel |
| Shim pacer stalls (5–23 ms, seen in S2 on a shared runtime) | Occasional frame delay on smooth traffic | Rerun on the dedicated runtime; else more burst credit or pace slightly above capacity |
| iroh/noq internals we depend on (drop counting, per-path controllers) change on upgrade | Silent drops or a lost pacing rate | Pin iroh; shim tests for drop counts and path-change rate handoff; upstream the uncounted-drop and `datagram_send_buffer_space()` issues |
| 300 ms path idle timeout closes on short outages (S5b: 200–300 ms blackouts at 75 ms RTT) and iroh re-punches only after 9–60 s | Up to a minute on the relay after a Wi-Fi stall | Re-punch on path close (upstream or patch), or a ~1 s timeout with the core reacting to "no ack progress". S5c measured both at 75–250 ms RTT: a ~1 s timeout still closes on outages of 0.8–1 s and longer, with the same 21–57 s re-punch on stock iroh; a prototype re-punch patch cuts it to 0.13–1.07 s at either setting. Decision open |
| Windows virtual gamepad and IddCx display drivers need signing | No gamepads or headless host on Windows | Decide driver route by Phase 3; ship without until signed |
| macOS private API (CGVirtualDisplay) changes | Headless macOS host breaks on an OS update | Feature-flag it; test on every macOS beta |
| Relay quality for browsers | Stutter on lossy networks | Self-hosted regional relays; set expectations in UI |
| Zig stdlib churn | Rework on upgrade | Pin one Zig version per release; sans-I/O core limits exposure |
| ~~Rust/Zig ABI and linking on Windows~~ | Build breakage | Retired by S1: static linking works on all targets; Windows arm64 CI uses x64 Zig under emulation |

**Open questions**

- ~~Can VideoToolbox's low-latency path run fast enough with `RealTime=false` and real capture to keep long-term references?~~ Answered by S7b: `RealTime=false` doesn't help, but `ExpectedFrameRate=1000` gets LTR encode to 8.6 ms p99 (HEVC), 2–4 ms over the regular encoder. Decided Nov 7, 2026: the low-latency encoder with LTR is the macOS default for now, accepting the ~0.6 ms miss on the S7 bar; revisit if newer macOS or chips change the numbers.
- Do NVENC, AMF and oneVPL support per-frame bitrate changes and long-term references, and which must for launch? (S8 Windows rows.)
- What is our Windows glass-to-glass baseline against Moonlight and Parsec? (S6.)
- Is the web client usable over a relay? (S9.)
- ~~Do the shim's pacer stalls go away on the dedicated runtime?~~ No: S10 saw them on a pinned SCHED_FIFO thread with no tokio as well, so they are host scheduling on the VM. Recheck on bare metal.
- Does a frame's worth of burst credit in `AppRate` get iroh's frame overhead under 2 ms p99 like it did for the Zig pacer? (S10 follow-up.)
- Does S11's simulated result hold on a real Wi-Fi link, and does `gcc-hybrid` or the queue-delay controller win there? (S11 real run.)
- What encoder share of the capacity estimate should each mode use (game vs desktop)? S11 shows the frame-delay vs bitrate trade but not the right point.
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
| Keep iroh; noq-proto fallback dropped (Nov 2026) | S3 installs a custom controller through iroh's public API; S5 found path stats and events public |
| Media stays on iroh datagrams, not noq-proto driven from Zig (Nov 2026) | S10: ~0.9 ms p99 better on frames and exact drop counts, but no shared socket without forking iroh, and a second socket needs its own NAT traversal plus the iroh relay path anyway |
| Shim owns congestion control, pacing, drop counts and its runtime; core sets the rate | iroh's Cubic hid 100–140 ms of queue and iroh counts no datagram drops (S2); pacing must live where packets leave |
| Pace at the capacity estimate, not the encoder bitrate | Encoder-rate pacing spreads each frame over the whole interval (S2) |
| Rate controller uses our one-way timestamps, not QUIC RTT | QUIC RTT stays flat while the send buffer fills (S2) |
| Send buffer sized to the largest frame (not 64 KiB), evictions counted; 300 ms path idle timeout | 64 KiB bounded smooth-traffic queueing (S2) but evicted 62% of an 85 Mbit/s frame stream (S10); dead direct path detected in 300 ms instead of 15 s (S5) |
| Dedicated current-thread iroh runtime on a pinned real-time thread | Shared multi-thread runtime added 1–4 ms p99 under load; dedicated one 0.1–0.4 ms (S4) |
| Static shim linking by default | Works on all five targets (S1); dynamic build kept as an option |
| Loss recovery is LTR-first with client acks; no intra-refresh baseline | VideoToolbox has no working intra-refresh; LTR recovery frames are 3–6× smaller than IDRs (S8) |
| Clients drop frames after a gap until the recovery frame | Required for Apple's HEVC decoder, harmless elsewhere (S8) |
| macOS encoder: low-latency path with LTR, RealTime on, `ExpectedFrameRate=1000`, HEVC preferred (Nov 2026; accepts ~0.6 ms over the S7 bar) | Only path with long-term refs (S8); 8.6 ms p99 with LTR vs 15.5 ms on defaults; `RealTime=false` adds tails there (S7b) |

**Sources**

- [Parsec technical overview](https://support.parsec.app/hc/en-us/articles/32361354307348-Overview)
- [Parsec: BUD networking protocol](https://blog.parsec.app/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007/)
- [Wolf: Moonlight protocol docs](https://games-on-whales.github.io/wolf/stable/protocols/index.html)
- [Iroh 1.0: Dial Keys, Not IPs](https://pinggy.io/amp/blog/iroh_1_0_dial_keys_not_ips/)
- [iroh: WebAssembly and browsers](https://docs.iroh.computer/languages/wasm-browser)
- [iroh C bindings](https://docs.iroh.computer/languages/c)
- [noq-proto docs](https://docs.rs/noq-proto/latest/noq_proto/)
- [Zig 0.16 I/O interface write-up](https://www.youngju.dev/transcribe/2026-07-16-zig-016-io-interface.en)
