# Spike S1: iroh shim linked into Zig

**Question (design doc, S1):** does the shim build and link into Zig on all three OSes?
**Pass:** echo works on Windows, macOS and Linux; archive sizes recorded.

**Status: partial pass, CI still pending.** The S1 code is not a throwaway spike: it is the
real shim and lives at the repo root, not in this folder.

| Path | What |
| --- | --- |
| [`shim/`](../../shim) | Rust crate over iroh 1.4.1 with the C ABI in `shim/include/iroh_shim.h`; ABI, build modes and release flow in [`shim/README.md`](../../shim/README.md) |
| [`transport/iroh.zig`](../../transport/iroh.zig) | Zig binding |
| [`tools/shim-echo/main.zig`](../../tools/shim-echo/main.zig) | datagram echo harness (`zig build echo`) |
| [`.github/workflows/shim.yml`](../../.github/workflows/shim.yml) | 5-target CI matrix and `shim-v*` release |

## Results so far

- Links into Zig 0.16 both statically and as a shared library; echo passes 500/500 on Linux x64.
- CI: Linux x64, Linux arm64 and Windows x64 pass. macOS (SDK paths for system libs) and
  Windows arm64 (Zig crash, now using x64 Zig) were still being fixed when this was merged;
  see draft PR #1.
- Archive sizes per target: not yet recorded (comes from the CI release's `SIZES.md`).
- Adopted S4's finding: iroh runs on one shim-owned current-thread runtime, with a start
  hook so the host can pin it and raise its priority.

On Linux the Rust std wants `libgcc_s` for `_Unwind_*`; the Zig link uses Zig's bundled
LLVM libunwind instead. Windows maps Zig `*-windows-gnu` to Rust `*-pc-windows-gnullvm`.
