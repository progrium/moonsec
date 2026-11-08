# codec/opus

libopus 1.5.2 built from source by `zig build` ([libopus.zig](libopus.zig)), and the Zig
binding the audio stage uses ([opus.zig](opus.zig)). The source comes from the `opus`
entry in `build.zig.zon` (xiph/opus git tree at the v1.5.2 tag), fetched by hash; no
system libopus, CMake or autotools.

- Float build, plain C: no SIMD intrinsics or run-time CPU detection yet (a 10 ms stereo
  frame encodes in well under a millisecond without them). No DNN features (deep PLC,
  DRED, OSCE), whose model weights are not in the git tree.
- `-ffp-contract=off`, so x86_64 and aarch64 compute the same floats.
- Targets: every native target, and wasm32-wasi (wasi-libc) for the browser client.
  `zig build check-opus` cross-compiles the library and binding for Linux, macOS and
  Windows (GNU ABI) on x86_64 and aarch64 plus wasm32-wasi; CI also builds and tests it
  natively for `x86_64-windows-msvc`.
- The CTL calls go through non-variadic C wrappers ([ctl.c](ctl.c)), so Zig never calls a
  C variadic function.

In-band FEC: Opus writes it only in SILK and hybrid modes (10 ms frames or longer, never
for 5 ms). `EncoderOptions.inband_fec` defaults to libopus' mode 2, which keeps music in
CELT (no FEC) instead of forcing it to hybrid; mode 1 cost music 12 dB of waveform SNR in
the audio sim for almost no FEC (`zig build audio-sim`). Mode 2 relies on libopus' music
detector, which only runs at complexity 7 or more.

```sh
zig build test-opus       # binding tests
zig build test-audio      # binding tests + audio scenarios over the sim
zig build audio-sim -Doptimize=ReleaseSafe   # full-length scenario table
zig build check-opus      # cross-compile for every target
```
