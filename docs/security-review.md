# moonsec security review packet

For an external reviewer of pairing and the shim boundary (Phase 7, workstream 7E), and the
record of our own pass over the same code. Threat model: [security.md](security.md).

Status: our pass done Nov 2026 against `main` at `443e321` (Phase 5 PRs #31 control channel
and #38 multi-user merged). Fixes from it are in the same PR as this file.

## Scope

In scope, in priority order:

1. **Pairing and admission.** [spec/pairing-v0.md](../spec/pairing-v0.md) against
   [core/pair](../core/pair) (sans-I/O: tickets, PINs, exchange, allowlist),
   [app/pairing.zig](../app/pairing.zig) (state directory, exchange over a stream),
   [app/keystore.zig](../app/keystore.zig) (key files) and
   [app/pair_cmd.zig](../app/pair_cmd.zig) (`moonsec pair`, `acceptAdmitted`).
2. **The shim boundary.** [shim/include/iroh_shim.h](../shim/include/iroh_shim.h) and
   [shim/src/lib.rs](../shim/src/lib.rs) (with `apprate.rs`, `wakeup.rs`), and its Zig
   callers [transport/iroh.zig](../transport/iroh.zig) and
   [transport/iroh_pipe.zig](../transport/iroh_pipe.zig).
3. **What a paired peer can reach.** The session parsers (wire, control, input, audio,
   multi-user specs in [spec/](../spec)), as the threat model's "paired but malicious
   client" and "malicious host". These are fuzzed ([fuzzing.md](fuzzing.md)); review the
   policy, not the parsing.

Out of scope: iroh itself (an upstream dependency, pinned at 1.4.1), the platform capture,
encode and decode backends (they parse only what the local OS and the codec libraries hand
them, except the decoders, which take a paired host's bitstream), and the web client
(`shim-web`, PR #33 era, reviewed separately once it ships).

## Code map

| Path | What | Lines |
| --- | --- | ---: |
| `core/pair/exchange.zig` | Pairing messages, `Window` (attempts, deadline), host and client state machines, admission messages | 680 |
| `core/pair/ticket.zig` | `MOONSEC1:` tickets: base32, CRC, fields | 270 |
| `core/pair/pin.zig` | PIN generation (rejection sampling) and parsing | 69 |
| `core/pair/allowlist.zig` | Paired-device list: text format, name sanitizing | 238 |
| `core/pair/id.zig` | Endpoint IDs (Ed25519 public keys) | 54 |
| `app/keystore.zig` | `KeyStore`, `FileKeyStore` (0600 files, refuses readable keys), atomic writes | 236 |
| `app/pairing.zig` | State directory, the exchange over a byte stream | 375 |
| `app/pair_cmd.zig` | `moonsec pair host/client`, `paired`, `unpair`; `acceptAdmitted`, `requestSession` | 575 |
| `app/main.zig` `peerIroh`, `peerPaired` | Where a session decides between pairing-enforced and open mode | ~120 |
| `shim/src/lib.rs` | Every C ABI function | 1500 |
| `shim/src/apprate.rs` | Congestion controller (pure arithmetic, no unsafe) | 270 |
| `shim/src/wakeup.rs` | Pollable wakeup socket pair | 91 |
| `transport/iroh.zig` | Zig wrapper over the C ABI | 321 |
| `core/control`, `core/multi`, `app/multi_host.zig` | Control channel, clipboard, multi-user roster and input policy | ~1500 |

## Build and test

Toolchains: Zig 0.16.0, Rust 1.97.0 (`shim/rust-toolchain.toml`), nightly Rust for Miri and
cargo-fuzz. Everything below runs on Linux without a GPU.

```sh
zig build test --summary all            # core and app unit tests, fuzz corpus replay
zig build test-app --summary all        # host and client end to end over the sim
zig build test-pair --summary all       # pairing and admission over iroh on loopback (builds the shim)
zig build test-shim --summary all       # shim ABI tests over loopback, gate over iroh, pairing
zig build check-win --summary all       # cross-compile the Windows platform code

cd shim
cargo test --lib                        # shim boundary unit tests
cargo +nightly miri test --lib          # the same under Miri
cargo audit                             # RustSec advisories
cargo deny check                        # advisories, licences, sources (shim/deny.toml)
cargo +nightly fuzz run c_abi           # the C ABI under AddressSanitizer (fuzz/README.md)
cd ../shim-web && cargo audit && cargo deny --config ../shim/deny.toml check

tools/fuzz/run.sh -t 3600               # every Zig parser harness, all cores, an hour
```

Results of our pass (Nov 2026): all of the above pass; `test` 379/379, `test-app` 36/36,
`test-shim` 10/10 plus the iroh gate and pairing runs; Miri clean on the shim's boundary
tests; `cargo audit` reports no vulnerabilities (two unmaintained crates, below).

## How pairing holds up

Checked against the spec, with what we found:

| Property | Where | Verdict |
| --- | --- | --- |
| PIN is uniform over 10⁶ from a secure RNG | `pin.fromRandom` (rejection sampling over u32), `cmdPairHost` (`io.randomSecure`) | Holds. |
| Brute force is bounded per window | `Window.attempts_left` (5), decremented on every wrong proof on any connection; window closes at 0 | Holds: 5 × 10⁻⁶ per window. Opening a new window needs the host's user. |
| Proofs bind both endpoint IDs, both nonces, method and client name | `Transcript.mac` | Holds. IDs come from iroh's authenticated handshake (`iroh_conn_remote_id`), not from the messages. |
| No replay | Host nonce from `randomSecure` per connection | Holds. |
| MACs compared in constant time | `std.crypto.timing_safe.eql` on both sides | Holds. |
| Client checks it reached the ticket's host before sending anything | `cmdPairClient` compares `remoteId` with `t.host_id` | Holds. |
| QR secret is single-use and expires | `pairings_left`, `deadline_us` (monotonic, host side); `expires` in the ticket is advisory for the client | Holds; `expires` and the CRC are not authenticated, which is fine because the host enforces the window. |
| PIN offline guessing | Client sends its proof before the host proves anything | **Does not hold against a host the client was tricked into dialing** (O2). |
| Ticket parsing | `Ticket.decode`: CRC, length checks, version | Holds; now also refuses undefined flag bits (fixed). |
| Names cannot break the list format | `sanitizeName` on the way in; `cleanField` on addresses | Holds (fuzzed by `pair_text`). |
| Admission checks the allowlist by authenticated ID | `admitOne` | Holds, **when the host runs with `--state-dir`** (O1). |
| Key and list storage | `FileKeyStore`, `State` | Keys held. Lists were 0644 and a group-writable state directory went unnoticed (fixed). Windows relies on `%APPDATA%`'s ACL (O6). |
| What a paired client can do | Everything; multi-user input policy is a host-wide setting | As designed; no per-device permissions yet (O4). |

## How the shim boundary holds up

| Question | Answer |
| --- | --- |
| Who owns buffers? | The caller, always. The shim copies in (`to_vec`, `Bytes::copy_from_slice`) and out (`copy_nonoverlapping` bounded by `cap`); strings out go through `write_cstr`, which checks `cap` before writing and reports the needed length. Unit tests check that nothing is written past `cap`; the ASan fuzzer adds guard bytes to every buffer. |
| Length checks | `recv_datagram` refuses a datagram larger than `cap` (and drops it); `stream_read` asks iroh for at most `cap` bytes; `path_stats` writes at most `cap` rows; `IrohEvent.remote_addr` is truncated and NUL-terminated (unit test). |
| NULL handles and buffers | Every function checks its handle (`as_ref`) and out pointers and returns `IROH_ERR_INVALID`; `*_free(NULL)` is a no-op; `bytes_arg(NULL, n)` is empty. Unit tests cover each, under Miri. |
| Stale handles | Not detectable: handles are raw `Box` pointers. A use after `*_free`, or a free while another thread is inside a call on the same handle, is a use after free. This is now written in the header as the caller's contract; the reviewer should check the Zig callers (`IrohLink` swaps and frees connections from a worker task) against it. |
| Thread safety | Handles are `Sync`: per-connection state is atomics and mutexes; streams hold tokio mutexes. All iroh work runs on one shim thread; blocking calls wait on it, so calling them from the thread-start hook would deadlock (documented). |
| `panic = "abort"` | Set for `release` and `dev` (the shim is built in release). Remaining `unwrap`/`expect`: mutex poisoning (only after a panic, which already aborted), runtime start-up (`iroh_shim_init` or the first call; no peer input), and `RelayUrl`/ticket parsing, which return errors. The `expect` on the per-connection wakeup socket was reachable by a peer that makes the host run out of file descriptors; it now returns `IROH_ERR_INTERNAL` (fixed). |
| iroh errors | Mapped to `IROH_ERR_CLOSED`, `_TIMEOUT` or `_INTERNAL` with the message in `iroh_last_error`; none panic. Stream reads and writes that time out drop a cancel-safe future (`read_chunk`, `write`); `iroh_stream_write`'s timeout can leave part of the buffer written, which the header says (use `write_some` when that matters). |
| Undefined behaviour | `recv_datagram` copied a zero-length datagram into a NULL buffer with `copy_nonoverlapping`, which requires non-null pointers even for zero bytes (fixed). Miri finds nothing in the boundary tests. |
| Unauthenticated peers | `iroh_endpoint_accept` completes the QUIC handshake for anyone; the handshake timeout is `max(10 s, accept timeout)`, so with a long accept timeout a stalled handshake holds the caller for that long (part of O3). |

## Findings

Severity is for a release build that ships to users; nothing has shipped yet.

### Fixed in this PR

| # | Severity | Finding | Fix |
| --- | --- | --- | --- |
| F1 | Medium | `pair host --ticket-file/--pin-file/--qr-svg` wrote the QR secret, its SVG and the PIN with the umask's permissions (usually 0644), through a fixed `<file>.tmp` that followed symlinks. Another local user could read the secret and pair their own device during the window, or plant a symlink at the `.tmp` name to overwrite a file the host's user can write. | Written 0600 through an exclusive, randomly named temporary file in the same directory (`keystore.writeFileAtomic`). |
| F2 | Medium | `State.open` accepted a state directory that group or others can write, so another local user could replace `paired-clients` (admitting their device) or the key file. | Refused on POSIX with `error.InsecurePermissions` and a `chmod go-w` hint. Directories moonsec creates are 0700, so only pre-existing loose directories are affected. |
| F3 | Low | `paired-clients` and `paired-hosts` were written 0644. | Written 0600, like the key. |
| F4 | Low | `Ticket.decode` ignored undefined flag bits, though the spec says they are 0. | Refused as `UnsupportedVersion`. |
| F5 | Low | Shim `iroh_conn_recv_datagram`: a peer's empty datagram received into a NULL buffer reached `copy_nonoverlapping(NULL, ...)`, undefined behaviour (and an abort in a debug build). | No copy for empty datagrams. |
| F6 | Low | Shim `wrap_conn` `expect`ed the wakeup socket pair; with `panic = "abort"`, file-descriptor exhaustion while accepting a connection ended the process. | Returns `IROH_ERR_INTERNAL` and closes that connection. |
| F7 | Low | The Windows client loaded `d3dcompiler_47.dll` with `LoadLibraryW`, which also searches the executable's and the current directory: a planted DLL there runs in the client. | `LoadLibraryExW(..., LOAD_LIBRARY_SEARCH_SYSTEM32)`, as the NVENC loader already does. |

Also added: `shim/deny.toml` (cargo-deny policy for both crates), shim boundary unit tests
that run under Miri, and the threading contract in `iroh_shim.h`.

### Open

| # | Severity | Finding | Recommendation |
| --- | --- | --- | --- |
| O1 | **High (release blocker)** | `moonsec peer iroh host` without `--state-dir` admits any peer that has its address ticket: video, audio, input injection, and the clipboard with `--clipboard`. In that mode `IrohLink` also accepts a replacement connection after a drop without any check, so a stranger who reaches the endpoint can take over a running session. Pairing-enforced mode (`peerPaired`) has no reconnect. | Before any release: make pairing the only mode outside the `run` lab commands (an explicit `--insecure-no-pairing` for labs), and run admission on every connection `IrohLink` accepts, including reconnects. |
| O2 | Medium | PIN pairing is not a PAKE. The client sends `client_mac = HMAC(K(PIN), transcript)` before the host proves anything, so a host the client dials by mistake (an attacker's address ticket, substituted wherever the user got it) receives a value it can brute-force offline in well under a second (10⁶ HMACs), then pair with the real host as itself inside the same window. The QR method (128-bit secret) is not affected. | Use a balanced PAKE for the PIN method (CPace or SPAKE2 over the same transcript), or show the host's short ID next to the PIN and have the client confirm it before sending its proof. At minimum, say in the spec that an address ticket must come from the host itself. |
| O3 | Medium | Availability: the host serves pairing and admission one connection at a time, with 10 s timeouts per step, up to about 32 s draining a stream on close, and an accept handshake bound of `max(10 s, accept timeout)` (600 s for `peer iroh --relay`). One unpaired peer that keeps connecting and stalling can stop the user from pairing or starting a session. No compromise. | Serve each connection on its own task with a total deadline (a few seconds for pairing, less for admission), cap concurrent unauthenticated connections, and bound the handshake by `ACCEPT_HANDSHAKE_TIMEOUT` alone. |
| O4 | Medium | Every paired client gets full control. There are no per-device permissions (view-only, no clipboard) in the allowlist; the multi-user "may control" flag is a host-wide setting, and `app/multi_host.zig` is not wired to iroh admission yet. | Add a permissions field to the allowlist (the spec lists it as a follow-up) before multi-user ships over the network. |
| O5 | Low | Secrets on the command line: `pair client --ticket <QR ticket>` and `--pin` are visible to other local users on the client (`ps`, `/proc`), who could race the pairing. | Read the ticket or PIN from stdin or a file by default (`--ticket-file` exists) and warn when they are given as arguments. |
| O6 | Low | Key storage: Windows keys rely on the inherited `%APPDATA%` ACL (no check, no DPAPI); macOS has no Keychain store yet; the POSIX check does not verify the file's owner; key bytes are not wiped from memory after use. | DPAPI and Keychain stores behind `KeyStore` (planned); check `st_uid` on POSIX; `std.crypto.secureZero` the secret after binding. |
| O7 | Low | Not fuzzed yet although on `main`: `core/control` (control channel, clipboard), `core/multi` messages, `platform/format.zig` negotiation. | Harnesses in 7D (fuzzing.md lists them under "In open PRs"; those PRs have merged). |
| O8 | Info | Relays (n0's public ones with `--relay`) see both endpoint IDs, IP addresses, timing and sizes, not contents. iroh's default discovery publishes the endpoint's addresses. | Document for users; recommend `--relay-url` (self-hosted, custom-only mode) for privacy. |
| O9 | Info | `cargo audit`: no vulnerabilities; two unmaintained crates arrive through iroh 1.4.1: `atomic-polyfill` (RUSTSEC-2023-0089, via heapless 0.7 ← postcard ← iroh-relay) and `paste` (RUSTSEC-2024-0436, build-time proc-macro via netlink-packet-core ← netwatch). | Ignored with reasons in `shim/deny.toml`; revisit on the next iroh update. |

## Dependencies

Rust (shim and shim-web; `Cargo.lock` pins every version): iroh 1.4.1, iroh-tickets 1.0.0,
tokio 1, rustls with ring (through iroh), bytes, n0-future, rustls-pki-types; shim-web adds
wasm-bindgen 0.2.106 and getrandom 0.4. 375 crates in the shim's tree, 368 in shim-web's.
`cargo deny check` passes for both with the licences in `shim/about.toml` plus `Unlicense`
(three wasm-only crates of iroh-relay's browser WebSocket).

C and system libraries:

| Library | Version | Used by | How |
| --- | --- | --- | --- |
| libopus | 1.5.2 (git `ddbe4838`, pinned by hash in `build.zig.zon`) | audio, all platforms | built from source, static |
| NVENC API header | Video Codec SDK 12.0.16 (`third_party/nvenc`) | Windows host | `nvEncodeAPI64.dll` loaded at run time from System32 |
| libavcodec, libavutil | system (distro) | Linux client decode | dynamic; must be an LGPL build to redistribute (7G) |
| libva | system | Linux client (VAAPI) | dynamic |
| wayland-client, wayland-egl, EGL, GLESv2 | system | Linux client present, clipboard | dynamic |
| libpipewire-0.3 | system | Linux client audio, Linux host capture | dynamic |
| dbus-1 | system | Linux host (xdg-desktop-portal) | dynamic |
| X11, Xfixes | system | Linux clipboard | dynamic |
| Windows system DLLs | OS | Windows host and client (D3D11, Media Foundation, WASAPI, SendInput, `d3dcompiler_47`, `winmm`, `user32`) | system |
| AppKit, Foundation and the macOS media frameworks | OS | macOS host and client | system |

AMF and oneVPL (PR #35) and ViGEmBus (PR #26) are not on `main` yet; add them here when
they merge.

## Questions for the reviewer

1. Is the HMAC exchange sound for the QR method as specified, and which PAKE would you
   want for the PIN method (O2)?
2. Is binding the client name into the transcript, but not the host name, a problem? (The
   host's name reaches the client only inside the accepted, MAC-verified exchange.)
3. Does relying on iroh's TLS for endpoint authentication leave anything for us to check
   beyond `remote_id`?
4. Anything in the shim's handle model (raw boxed pointers, caller-enforced lifetimes) you
   would change before the public C ABI (7F) wraps it?
