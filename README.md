# moonsec

Low-latency remote desktop and game streaming core in Zig, with networking from
Rust [iroh](https://github.com/n0-computer/iroh) through a small in-repo shim.

Design and plan: [docs/design.md](docs/design.md). Wire protocol: [spec/wire-v0.md](spec/wire-v0.md) (audio: [spec/audio-v0.md](spec/audio-v0.md); pairing: [spec/pairing-v0.md](spec/pairing-v0.md)). Spike write-ups, code and results:
[spikes/](spikes) (status table in the design doc's "Spike status" section).

Zig is pinned to **0.16.0** (`build.zig.zon` `minimum_zig_version`).

```
/core          pure Zig core (sans-I/O)
/transport     PacketPipe, iroh binding, sim pipe
/codec         libopus built from source and its Zig binding
/platform      host/{windows,macos,linux}, client/{windows,macos,linux,web}
/shim          Rust crate wrapping iroh (Cargo.lock, rust-toolchain.toml)
/shim-web      Rust wasm-bindgen crate for the browser
/web           browser client glue (TypeScript)
/spec          versioned wire protocol spec
/sim           simulation harness and scenarios
/tools         latency probe, netem scripts, interop harness
/docs          design doc
/spikes        time-boxed spikes S1–S9
```

## Quick start

```sh
zig build test            # core unit tests (pure Zig, no Rust needed)
zig build check-wasm      # compile the core for wasm32 (and libopus for wasm32-wasi)
zig build test-audio      # libopus binding + audio stream scenarios over the sim
zig build audio-sim -Doptimize=ReleaseSafe   # audio scenario table at full length
zig build check-opus      # cross-compile libopus for every target
zig build test-shim       # build the shim with cargo, run its loopback tests and the Phase 1 gate
zig build gate-sim        # Phase 1 gate over the simulated network only (two processes, no Rust)
zig build gate            # Phase 1 gate over iroh (loopback) and the sim; `-- run iroh --seed 3` etc.
zig build test-app        # Phase 2 host and client apps over the in-process sim
zig build soak            # one hour of simulated LAN streaming, fails on any freeze
zig build moonsec -- run all   # host and client processes over iroh and the sim (builds the shim)
zig build test-pair       # pairing (QR ticket, PIN) and session admission over iroh (part of test-shim)
zig build echo            # builds the shim with cargo, links it, runs the loopback datagram echo
zig build echo -- selftest --relay -n 50   # same, but through n0's public relays
```

See [shim/README.md](shim/README.md) for the shim ABI, build modes and the S1 results.

The Phase 1 gate ([tools/gate](tools/gate/main.zig)) starts a host and a client process that
exchange stream-tagged datagrams through the core (video through the packetizer with NACK
retransmits, audio, input with acks, transport feedback driving the rate controller, whose
pacing rate goes back to the transport) over `PacketPipe`: once over iroh, once over the
simulated network, where the parent process is the hub that owns the network. Each side
checks every byte it received and the other side's counts; CI runs it on every target.

The Phase 2 session spine ([app/](app/README.md)) runs a host and a client over any platform
backend ([platform/api.zig](platform/api.zig)); the synthetic backend streams a self-checking
test pattern, so it runs end to end on any machine.
