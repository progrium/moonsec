# moonsec threat model

Status: draft, Nov 2026 (Phase 7, workstream 7E). Scope: what is on `main` at the time of
writing: pairing and admission ([spec/pairing-v0.md](../spec/pairing-v0.md)), the iroh shim
and its C ABI ([shim/include/iroh_shim.h](../shim/include/iroh_shim.h)), the session
protocols (wire, control, input, audio, multi-user specs in [spec/](../spec)) and the host
and client apps. The review findings against this model are in
[security-review.md](security-review.md).

moonsec streams a host's screen and audio to a client and injects the client's keyboard,
mouse and gamepad input on the host. Whoever is admitted to a session can, by design, do
anything the host's logged-in user can do with a keyboard and mouse. So the question this
document answers is mostly: **who can get admitted, and what can anyone who is not admitted
do to either side?**

## Assets

| Asset | Where | Why it matters |
| --- | --- | --- |
| Host device key | `<state dir>/identity.key` (Ed25519 seed) | It is the host's identity. Whoever holds it can impersonate the host to every paired client and see what they type. |
| Client device key | the client's `identity.key` | It is the client's credential: the host admits whoever proves this key, so a stolen client key is a paired client. |
| Host allowlist | `<state dir>/paired-clients` | Whoever can add a line to it can admit their own device. |
| Client host list | `<state dir>/paired-hosts` | Decides which hosts a client will stream from and send input to. |
| Pairing secrets | QR ticket secret (128 bit), PIN (6 digits), while a window is open | Whoever has one during the window can pair a device of their choosing. |
| Input injection | `platform` input backends (SendInput, CGEvent, uinput, ViGEmBus) | Full control of the host's desktop session. |
| Screen and audio | capture backends | Anything shown on the host, including secrets on screen. |
| Clipboard | `--clipboard` (opt-in) | Passwords and tokens the user copies, both ways. |
| Availability | the host's accept loop, pairing window | A user who cannot connect to their own machine. |

## Attackers

| Attacker | Can | Cannot (if the design holds) |
| --- | --- | --- |
| **On-path network attacker** (Wi-Fi, ISP, hostile LAN) | See and drop UDP, learn IPs, timing and packet sizes, block paths. | Read or change QUIC traffic (TLS 1.3 to the peer's key), impersonate an endpoint without its key, learn a PIN from a pairing exchange (the MACs travel inside QUIC). |
| **Relay operator** (n0's public relays with `--relay`, or a self-hosted relay) | Everything the on-path attacker can, plus the endpoint IDs of both sides and when they talk. Refuse or delay service. | Decrypt: relayed packets are the same end-to-end QUIC. |
| **Unpaired peer** (anyone who can reach the host's endpoint: has its address ticket, or finds it via discovery) | Complete a QUIC handshake, open streams, send any bytes to the pairing/admission parser, guess the PIN while a window is open (5 tries per window), tie up the accept loop. | Start a session, send datagrams the session acts on, or pair without the secret. |
| **Paired but malicious client** | Everything a session allows: watch the screen, inject input (under the multi-user input policy), read and set the clipboard if enabled, send malformed media feedback, control messages and input to every session parser. | Escape the session's message parsers into memory corruption, or affect other clients beyond what the input policy allows. |
| **Malicious host** (a host the user paired with, or one the user was tricked into dialing) | Show anything; receive everything the client types; send malformed media, audio and control traffic to the client's parsers and decoders. | Learn the client's key; for a host the user only *tried* to pair with, learn the PIN (the PIN method is a PAKE, so it can test one guess per run, online). |
| **Local unprivileged user on the host or client** | Read world-readable files, see other users' command lines, plant files in shared directories. | Read the device key or lists (0600 in a 0700 directory), change the allowlist. |

Out of scope: an attacker who is already the host's or client's logged-in user or root (they
own the keys and the session anyway), supply-chain compromise of the toolchains, and
physical attacks.

## Trust boundaries

```
           network (untrusted)
                │  UDP / relay WebSocket
┌───────────────▼───────────────────────────────────┐
│ iroh (Rust): QUIC + TLS, hole punching, relays    │  authenticates both endpoint IDs
├───────────────────────────────────────────────────┤
│ shim (Rust, C ABI): datagram queue, streams, rate │  B2: core ↔ shim (FFI, buffers, handles)
├───────────────────────────────────────────────────┤
│ core (Zig, sans-I/O): pairing, wire, control,     │  B1: network → core (every parser)
│   input, audio, multi-user, recovery              │
├───────────────────────────────────────────────────┤
│ app + platform (Zig/C/ObjC): capture, encode,     │  B4: app → OS (input injection, capture,
│   decode, present, inject, clipboard              │       clipboard, files, DLL loading)
└───────────────────────────────────────────────────┘
```

- **B1, network to core.** Every byte after the QUIC layer is attacker-controlled until
  admission, and paired-peer-controlled after it. The parsers are sans-I/O and fuzzed
  ([fuzzing.md](fuzzing.md)). The rule that matters most: *nothing but the pairing and
  admission parsers sees bytes from a connection that has not been admitted*
  (`app/pair_cmd.zig`, `acceptAdmitted`).
- **B2, core to shim.** A C ABI between Zig and Rust. The caller owns every buffer; the shim
  copies in and out and never returns heap memory except opaque handles. Panics abort the
  process (`panic = "abort"`), so a reachable panic is a remote crash.
- **B3, shim to iroh.** iroh authenticates the peer's endpoint ID in the TLS handshake. The
  shim's `iroh_conn_remote_id` is what pairing and admission trust; everything else in iroh
  (discovery, relays, path selection) affects only availability and metadata.
- **B4, app to OS.** Input injection runs with the logged-in user's rights (and the
  Accessibility / uinput / ViGEmBus permissions they granted). Capture sees the whole
  desktop. Files the app writes (keys, lists, tickets) and libraries it loads at run time
  are part of this boundary.

## Security properties we claim

1. **Only paired devices stream.** A host admits a session only from a connection whose
   authenticated endpoint ID is on its allowlist, on every connection: the first and each
   reconnect. Only lab runs opt out, with `--insecure-no-pairing`.
2. **Pairing needs the secret the host shows**, and each wrong guess costs one of the
   window's five attempts whatever connection it arrives on: a PIN guesser wins with
   probability 5 × 10⁻⁶ per window. A QR secret is 128 bits.
3. **Pairing proofs bind both endpoint IDs and both nonces**, so they cannot be replayed on
   another connection, relayed to another host, or made for another client.
4. **The client checks the host's identity** against the ticket before pairing and against
   its own list before a session.
5. **Keys and lists are private to the user** on POSIX (0600 files in a 0700 directory;
   a key file or directory others can read or write is refused).
6. **No parser crashes on any input** (fuzzed; ReleaseSafe builds stop on overflow and
   out-of-bounds), and **no peer can make the receiver hold more memory** than its config
   allows.
7. **Everything on the wire is encrypted and authenticated** by QUIC; relays see metadata
   only.
