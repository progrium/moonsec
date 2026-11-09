# Fuzzing

Phase 7 asks for a fuzz harness on every function that parses bytes from the network or
from a file, and for the fuzzers to run clean for a week of CPU time (docs/design.md,
"Phase 7: Linux host and hardening"). This page lists those parsers, says which harness
covers each one, and explains how to run them.

## How to run

| Command | What it does |
| --- | --- |
| `zig build test` | Replays every harness's seed corpus and saved crashes (part of the normal tests). |
| `zig build fuzz` | The same replay on its own, in ReleaseSafe. |
| `zig build fuzz --fuzz=1M -Dfuzz-filter=pair_ticket` | Fuzzes one harness for a million runs on one core. |
| `tools/fuzz/run.sh -t 3600` | Fuzzes every harness for an hour on all cores, keeping corpora in `.fuzz/`. |
| `zig build fuzz-repro` | Builds `zig-out/bin/fuzz-repro <harness> <input>...`, which replays saved inputs outside the fuzzer. |
| `zig build fuzz-wasm` | Replays the corpora on wasm32-wasi under Node. |
| `cd shim && cargo +nightly fuzz run c_abi` | Fuzzes the shim's C ABI under AddressSanitizer (shim/fuzz/README.md). |
| Actions, `fuzz` workflow | Both of the above for up to 6 hours on one runner; corpora carry over between runs. |

The Zig harnesses use Zig 0.16's built-in fuzzer (`std.testing.fuzz`). Each harness is a
function `fn (gpa, *std.testing.Smith) !void` in `fuzz/`, so one function runs under the
fuzzer, on its corpus in a plain test run, and on a single input in `fuzz-repro`. Every
harness checks four things:

- **No crash and no safety-check panic.** Fuzz builds are ReleaseSafe, so overflow,
  out-of-bounds indexing, `unreachable` and bad enum casts all stop the run.
- **No leak.** The fuzzer checks `std.testing.allocator` after every input.
- **Bounded allocation.** Harnesses for stateful receivers wrap the allocator in
  `common.Bounded`, which fails the input if live allocations pass a limit derived from
  the receiver's config. A peer must not be able to make us hold more than that.
- **Round trip.** Where an encoder exists, what decodes re-encodes to bytes that decode to
  the same value, and re-encoding is a fixed point (one canonical form per value).

Seeds come from the real encoders (the packetizer, the audio sender, the input sender,
the pairing client, ticket encoding) and from the existing test vectors. Crashes found
by `tools/fuzz/run.sh` are minimized and saved under `fuzz/corpus/<harness>/`, where the
build embeds them, so every later `zig build test` replays them.

### Workarounds for Zig 0.16.0

Three problems with Zig 0.16.0's fuzzer are worked around here; each can go once a release
fixes it.

- `zig build --fuzz` does not compile any test that calls `std.testing.fuzz`: the test
  runner passes an error return trace to `std.debug.writeStackTrace`. `fuzz/test_runner.zig`
  is 0.16.0's runner with that one line fixed, used only by the `fuzz` step.
- A module with C sources (the Opus binding's `ctl.c`) gets coverage counters but no PC
  table, and the fuzzer refuses to start. The binding module is built without
  instrumentation; libopus itself never was. Crashes inside libopus are still caught.
- The fuzzer needs ReleaseSafe or faster (Debug builds have no coverage map), and its
  unlimited mode (`--fuzz` with no count) runs one slow instance behind the web UI, so
  `tools/fuzz/run.sh` runs one limited fuzzer process per harness and schedules them
  itself.

## Parsers and their harnesses

### On `main`

| Parser | Input from | Harness |
| --- | --- | --- |
| `core/proto/wire.zig` `Decoder` (LEB128 varints, ints) | network | `proto_varint`, and every harness below |
| `core/proto` `decode`: envelope, video shard header, frame ack, transport feedback | network | `proto_datagram` |
| `core/media/nack.zig` `parse`, `Iterator` | network (client to host) | `proto_datagram`, `media_retransmit` |
| `core/media/reassembly.zig`, `receiver.zig` (shards into frames, FEC rebuild, NACK list) | network | `media_receiver` |
| `core/media/retransmit.zig` `History.resend` (answering NACKs) | network | `media_retransmit` |
| `core/audio/wire.zig` `Frame.parse`, `Parity.parse` | network | `audio_messages` |
| `core/audio/receiver.zig` (jitter buffer, RS recovery) | network | `audio_receiver` |
| Opus packet path: `codec/opus/stage.zig` `ClientAudio`, libopus decode, FEC, PLC | network | `audio_opus_client` |
| `core/recovery/wire.zig` `applyFrameAck`, `frameMeta`; `core/recovery` host and client | network | `recovery_host`, `recovery_client` |
| `core/input` `Receiver.process`, `decodeAck` | network | `input_receiver`, `input_round_trip` |
| `core/clock` `Ping.decode`, `Pong.decode`, `sampleOf`, `Estimator`, `Pinger.onPong` | network | `clock_sync` |
| `core/pair/ticket.zig` `Ticket.decode` (base32, CRC) | QR code, pasted text | `pair_ticket` |
| `core/pair/pin.zig` `parse`, `id.zig` `parseHex`, `allowlist.zig` `sanitizeName` | typed text, network | `pair_text` |
| `core/pair/allowlist.zig` `Allowlist.parse` | file (paired-devices list) | `pair_text` |
| `core/pair/exchange.zig` `Host.onMessage`, `Framer` | network (pairing stream) | `pair_exchange_host` |
| `core/pair/exchange.zig` `Client.onMessage`, `classify`, `admitResult` | network | `pair_exchange_client` |
| `app/wire.zig` `Hello`, `Config`, `ClockReport` | network | `app_session` |
| `platform/synthetic` decoder (`AuHeader.decode`, `configure` with the host's dimensions) | network | `video_passthrough_decoder` |
| Shim C ABI (`shim/include/iroh_shim.h`): datagrams, streams, tickets, bind options | the Zig side | `shim/fuzz` `c_abi` |

`core/pair/qr.zig` only encodes, so it has no parser. `app/keystore.zig` reads a 64-digit
hex key behind a fixed header with `std.fmt.hexToBytes` and a length check; it is small
enough that the unit tests cover it, and it reads only files the user's own account
wrote with 0600 permissions.

### In open PRs

Each of these gets a harness when its PR merges, in a follow-up PR stacked on it.

| Parser | PR |
| --- | --- |
| `core/control` (reliable control channel, clipboard) and the shim's stream calls | #31 |
| `core/display` (display list, mid-stream display changes) | #37 |
| `core/multi` (multi-user sessions) | #38 |
| Video format negotiation, `platform/format.zig` | #36 |
| shim-web pairing (iroh in the browser) | #33 |

## wasm32

The web client runs the core on wasm32. `zig build check-wasm` compiles every harness for
wasm32-wasi, and `zig build fuzz-wasm` runs their corpora and round-trip checks there
under Node's WASI. The fuzzer itself does not run on wasm32 (it needs a 64-bit host).

## Findings

Bugs the fuzzers found, fixed in the PR that added them:

| Harness | Bug | Fix |
| --- | --- | --- |
| `audio_opus_client` | A host frame with `samples` above 2880 made the client slice past its 2880 × 2 render buffer (index out of bounds). | `ClientAudio.render` checks the frame against the buffer (`error.FrameTooLong`); the app's buffer now holds a 120 ms Opus frame, the longest the spec allows. |
| `proto_datagram` | A video shard header with `shard = 255` overflowed `shard + 1` (u8) in `ShardHeader.payloadLen`, so one datagram crashed the client in a safe build. | The comparison is done in u16. |
| `video_passthrough_decoder` | `width * height * 4` in the synthetic decoder's `configure` overflowed u32 for dimensions the host sends. | `configure` rejects sizes that do not fit (`error.Unsupported`). |
| `clock_sync` | `sampleOf` subtracted host timestamps (t2, t3 from a pong) in i64 and overflowed on extreme values; the client calls it on every pong. | The arithmetic is done in i128, and a sample that does not fit is dropped. |

Each crash's input is saved under `fuzz/corpus/<harness>/crash-*`. The `pair_text` input
there was a harness bug (`id.parseHex` ignores surrounding whitespace, which the check did
not allow for).

## The week of CPU time

The gate is a clean run of about 168 CPU hours: for example `tools/fuzz/run.sh -t 75600
-j 8` (8 cores for 21 hours) on a dedicated Linux machine, repeated with the same `-o`
directory until a full run finds nothing, plus `cargo fuzz run c_abi` for its share.
Cloud containers are reclaimed when idle, so this needs a machine that stays up (see
plans/phase7-briefs.md, "Needs Jeff's hardware or accounts"). The `fuzz` workflow can
also add up to 6-hour runs on GitHub's 4-core runners; corpora carry over between runs.

Hardware check for Jeff, on a Linux machine with Zig 0.16.0 that stays up (exits 0 when
the week's share finishes clean):

```
tools/fuzz/run.sh -t 75600 -j 8 -o ~/moonsec-fuzz
```
