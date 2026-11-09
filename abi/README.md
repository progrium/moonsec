# abi: the public C ABI's build, tests and ABI dump

The ABI itself: [include/moonsec.h](../include/moonsec.h) (header),
[spec/c-abi-v1.md](../spec/c-abi-v1.md) (rules and design),
[app/abi.zig](../app/abi.zig) (implementation over the host and client apps).

| File | What |
| --- | --- |
| [build.zig](build.zig) | The libraries, tests and examples (`@import`ed by the root build.zig). |
| [test_loopback.c](test_loopback.c) | Host and client through the ABI over the in-process sim, in virtual time, on the clean, LAN and WAN profiles: events, frames through the frame callback, input (keys, buttons, scroll, motion, gamepads), clipboard both ways, telemetry, `struct_size` handling for an older caller, error codes, close and destroy from either side, no common codec. |
| [test_iroh.c](test_iroh.c) | Over iroh on loopback with the library's threads: an unpaired client refused, pairing by wrong PIN (fails) and QR ticket, a session with input and clipboard, persistence of keys and allowlists in the state directories, a client that requires pairing refusing an unknown host. |
| [test_system.c](test_system.c) | `MOONSEC_BACKEND_SYSTEM` over iroh: the host captures the screen and encodes with the OS's encoder, the client decodes and shows it in a window; the frame callback sees every picture, input reaches the host app, the loopback refuses system sessions. With `-- multi`, the same on a multi-user host (`max_clients` 2: the shared capture and encode). On Linux it serves the host tests' ScreenCast portal backend under `platform/host/linux/headless.sh`, one mode per headless.sh (its Weston crashes on a capture after a finished session). |
| [test_multi.c](test_multi.c) | A multi-user host over iroh: two members stream one encode, a third is refused while both are in, input follows the owner (dropped from the other member until the host gives it input), `INPUT_OWNER` on both sides, clipboard per member, one member leaving keeps the other streaming and frees its slot. Runs with `test-abi-iroh`. |
| [test_reconnect.c](test_reconnect.c) | Reconnect over iroh: the connection under a session drops (the library's internal `moonsec__test_drop_connection`, not part of the ABI), from the client's end and the host's, on a one-client and a multi-user host; the client redials through admission, both sides keep the same session streaming and count the reconnect, input still arrives, and a close still ends both at once. Runs with `test-abi-iroh`. |
| [include_check.cpp](include_check.cpp) | The header compiles as C++17, every function has its frozen signature (`static_assert` on its type), and the library links and runs from C++. |
| [abi_dump.c](abi_dump.c) | Every struct's size and field offsets, every constant's value and every function (by address, so the library must export it). `--check abi-v1.txt` compares with the frozen dump. |
| [abi-v1.txt](abi-v1.txt) | The frozen dump, for 64-bit targets. |
| [header_test.zig](header_test.zig) | Fails when the header has a struct, field, constant or function that `abi_dump.c` or `include_check.cpp` does not list, so the checks stay complete. |

## Commands

```sh
zig build test-abi        # C test over the sim, C++ check, ABI dump (no Rust; part of `zig build test`)
zig build test-abi-iroh   # the iroh, multi-user and reconnect tests (builds the shim; part of `zig build test-shim`)
platform/host/linux/headless.sh zig build test-abi-system -Dabi-system=true   # OS backends (Linux)
platform/host/linux/headless.sh zig build test-abi-system -Dabi-system=true -- multi   # the same, multi-user host
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

Across two machines add `--relay` to both, and `--system` to both to stream the host's
screen into a window on the client (a library built with `-Dabi-system`).

## Changing the ABI

Before the freeze, any change goes: edit the header, then `zig build abi-dump -- --write
$PWD/abi/abi-v1.txt`, and update `include_check.cpp` for a changed signature.

After the freeze (spec/c-abi-v1.md, "Versioning"), only additions: new functions, new
constants, new fields at the end of a `struct_size` struct. The dump then gains lines and
loses none; a test failure that shows a changed or missing line is a break of 1.0.
