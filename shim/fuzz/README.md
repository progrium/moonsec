# shim C ABI fuzzer

A [cargo-fuzz](https://github.com/rust-fuzz/cargo-fuzz) (libFuzzer) target that drives the
shim's C ABI (`../include/iroh_shim.h`) the way the Zig side does, under AddressSanitizer:

- datagrams of any length (0, past `iroh_conn_max_datagram_size`, from a NULL pointer) and
  receives into buffers of any size (0, too small, NULL);
- `iroh_endpoint_connect` with any ticket text and ALPN, and with near misses of a real
  ticket;
- bidirectional streams opened, written, finished twice, read through 0- to 255-byte
  buffers and freed with or without a reset;
- every call again after the peer closed the connection;
- `iroh_endpoint_bind` with any options: buffer sizes, timeouts, relay mode and URLs, bind
  address, relay CA PEM;
- stats, path stats, events, IDs and tickets with any buffer capacity.

Each call must return a documented status code, write only inside the buffer it got (a
guard byte after each buffer is checked), and never crash. Everything stays on loopback:
the target never uses the default relay mode.

## Run

```sh
rustup toolchain install nightly --profile minimal   # cargo-fuzz needs -Zsanitizer
cargo install cargo-fuzz
cd shim
cargo +nightly fuzz run c_abi -O -- -max_total_time=3600 -timeout=30
```

The corpus is kept in `fuzz/corpus/c_abi` and crashes in `fuzz/artifacts/c_abi`. Replay one
with `cargo +nightly fuzz run c_abi -O fuzz/artifacts/c_abi/<file>`, and minimize it with
`cargo +nightly fuzz tmin c_abi -O fuzz/artifacts/c_abi/<file>`. The `fuzz` workflow runs this
target too (docs/fuzzing.md).

Each input sets up a loopback connection once (kept across inputs), so the first input is
slow; expect about 80 inputs per second on one core after that.
