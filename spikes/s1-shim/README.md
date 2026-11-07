# Spike S1: iroh shim linked into Zig

**Question (design doc, S1):** does the shim build and link into Zig on all three OSes?
**Pass:** echo works on Windows, macOS and Linux; archive sizes recorded.

**Status: pass.** Echo works on Windows, macOS and Linux (all five targets, static and
dynamic linking), and archive sizes are recorded below. The "ship as DLL/dylib/so" fallback
isn't needed; static stays the default, with dynamic built and tested as an option. The S1 code
is not a throwaway spike: it is the real shim and lives at the repo root, not in this folder.

| Path | What |
| --- | --- |
| [`shim/`](../../shim) | Rust crate over iroh 1.4.1 with the C ABI in `shim/include/iroh_shim.h`; ABI, build modes and release flow in [`shim/README.md`](../../shim/README.md) |
| [`transport/iroh.zig`](../../transport/iroh.zig) | Zig binding |
| [`tools/shim-echo/main.zig`](../../tools/shim-echo/main.zig) | datagram echo harness (`zig build echo`) |
| [`.github/workflows/shim.yml`](../../.github/workflows/shim.yml) | 5-target CI matrix and `shim-v*` release |

## Results

CI run [42413917888](https://github.com/progrium/moonsec/actions/runs/42413917888)
(Zig 0.16.0, Rust 1.97.0, iroh 1.4.1). Every job links `shim-echo` statically and
dynamically, and each build passes a loopback selftest of 500 × 1150-byte datagrams.
The informational `--relay` selftest also passes on every target.

| Target | Runner | Echo (static / dynamic) | Static lib | Shared lib | Release `.tar.gz` | `shim-echo` static / dynamic (ReleaseSafe) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| linux-x86_64 | ubuntu-22.04 | pass / pass | 24.3 MB `.a` | 8.0 MB `.so` | 9.0 MB | 13.9 MB / 3.6 MB |
| linux-aarch64 | ubuntu-22.04-arm | pass / pass | 23.9 MB `.a` | 7.8 MB `.so` | 8.6 MB | 12.6 MB / 3.5 MB |
| windows-x86_64 | windows-2022 (msvc) | pass / pass | 15.5 MB `.lib` | 4.6 MB `.dll` | 6.9 MB | 5.9 MB / 1.3 MB |
| windows-aarch64 | windows-11-arm (msvc) | pass / pass | 14.7 MB `.lib` | 4.1 MB `.dll` | 6.5 MB | 5.4 MB / 1.3 MB |
| macos-universal | macos-15 (arm64 + x86_64 via Rosetta) | pass / pass | 27.9 MB `.a` (fat) | 12.3 MB `.dylib` (fat) | 14.3 MB | 6.8 MB / 0.5 MB (arm64) |

Static archives are large because they carry whole Rust objects; what lands in an executable
is much smaller (Linux executables include Zig's debug info, since ReleaseSafe isn't stripped).
Loopback echo RTT is 80–120 µs on Linux.

Native libraries the static archive needs (`rustc --print native-static-libs`):

- Linux: `-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc`. `gcc_s` is replaced by Zig's bundled LLVM libunwind (`-lunwind`).
- Windows (msvc): `legacy_stdio_definitions iphlpapi bcrypt advapi32 kernel32 ntdll userenv ws2_32 dbghelp`, dynamic CRT (`msvcrt`).
- macOS: `CoreFoundation Security SystemConfiguration` frameworks, `iconv`, `objc` and `Foundation` also listed. Zig needs the Xcode SDK's `usr/lib` and `System/Library/Frameworks` on its search paths; `build.zig` adds them on macOS hosts.

CI gotchas found along the way:

- Zig 0.16.0's native aarch64-windows binary segfaults at start on `windows-11-arm`, so that
  job runs the x86_64 Zig under Windows' x64 emulation (it still targets `aarch64-windows-msvc`).
- Linux shared builds set a SONAME (`shim/build.rs`) so executables find `libiroh_shim.so` via `$ORIGIN`.

Also adopted S4's finding: iroh runs on one shim-owned current-thread runtime, with a start
hook so the host can pin it and raise its priority.

Still to do: tag the first `shim-v0.1.0` release and wire its hashes into `build.zig.zon`
(`-Dshim=prebuilt`), and generate the third-party notices file.

On Linux the Rust std wants `libgcc_s` for `_Unwind_*`; the Zig link uses Zig's bundled
LLVM libunwind instead. Windows maps Zig `*-windows-gnu` to Rust `*-pc-windows-gnullvm`.
