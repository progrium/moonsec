# abi: the public C ABI's build, tests and ABI dump

The ABI itself: [include/moonsec.h](../include/moonsec.h) (header),
[spec/c-abi-v1.md](../spec/c-abi-v1.md) (rules and design),
[app/abi.zig](../app/abi.zig) (implementation over the host and client apps).

| File | What |
| --- | --- |
| [build.zig](build.zig) | The libraries, tests and examples (`@import`ed by the root build.zig). |
| [test_loopback.c](test_loopback.c) | Host and client through the ABI over the in-process sim, in virtual time, on the clean, LAN and WAN profiles: events, frames through the frame callback, input (keys, buttons, scroll, motion, gamepads), clipboard both ways, telemetry, `struct_size` handling for an older caller, error codes, close and destroy from either side, no common codec. |
| [test_iroh.c](test_iroh.c) | Over iroh on loopback with the library's threads: an unpaired client refused, pairing by wrong PIN (fails) and QR ticket, a session with input and clipboard, persistence of keys and allowlists in the state directories, a client that requires pairing refusing an unknown host. |
| [include_check.cpp](include_check.cpp) | The header compiles as C++17, every function has its frozen signature (`static_assert` on its type), and the library links and runs from C++. |
| [abi_dump.c](abi_dump.c) | Every struct's size and field offsets, every constant's value and every function (by address, so the library must export it). `--check abi-v1.txt` compares with the frozen dump. |
| [abi-v1.txt](abi-v1.txt) | The frozen dump, for 64-bit targets. |
| [header_test.zig](header_test.zig) | Fails when the header has a struct, field, constant or function that `abi_dump.c` or `include_check.cpp` does not list, so the checks stay complete. |

## Commands

```sh
zig build test-abi        # C test over the sim, C++ check, ABI dump (no Rust; part of `zig build test`)
zig build test-abi-iroh   # the iroh test (builds the shim; part of `zig build test-shim`)
zig build abi             # zig-out/include/moonsec.h, zig-out/lib/libmoonsec.{a,so} + libiroh_shim.a
zig build abi-sim         # libmoonsec-sim.{a,so}: loopback only, no Rust
zig build examples        # zig-out/bin/moonsec-example-{host,client} on the shared library
zig build abi-dump        # print the dump
```

The examples on one machine (two terminals):

```sh
zig-out/bin/moonsec-example-host --pair --state-dir /tmp/h      # prints a ticket, a QR ticket and a PIN
zig-out/bin/moonsec-example-client pair MOONSEC1:... --state-dir /tmp/c
zig-out/bin/moonsec-example-client connect MOONSEC1:... --state-dir /tmp/c
```

Across two machines add `--relay` to both.

## Changing the ABI

Before the freeze, any change goes: edit the header, then `zig build abi-dump -- --write
$PWD/abi/abi-v1.txt`, and update `include_check.cpp` for a changed signature.

After the freeze (spec/c-abi-v1.md, "Versioning"), only additions: new functions, new
constants, new fields at the end of a `struct_size` struct. The dump then gains lines and
loses none; a test failure that shows a changed or missing line is a break of 1.0.
