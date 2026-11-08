# moonsec

Low-latency remote desktop and game streaming core in Zig, with networking from
Rust [iroh](https://github.com/n0-computer/iroh) through a small in-repo shim.

Design and plan: [docs/design.md](docs/design.md). Wire protocol: [spec/wire-v0.md](spec/wire-v0.md). Spike write-ups, code and results:
[spikes/](spikes) (status table in the design doc's "Spike status" section).

Zig is pinned to **0.16.0** (`build.zig.zon` `minimum_zig_version`).

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
/docs          design doc
/spikes        time-boxed spikes S1–S9
```

## Quick start

```sh
zig build test            # core unit tests (pure Zig, no Rust needed)
zig build check-wasm      # compile the core for wasm32
zig build test-shim       # build the shim with cargo and run its loopback selftest
zig build echo            # builds the shim with cargo, links it, runs the loopback datagram echo
zig build echo -- selftest --relay -n 50   # same, but through n0's public relays
```

See [shim/README.md](shim/README.md) for the shim ABI, build modes and the S1 results.
