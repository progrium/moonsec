# moonsec pairing v0

Status: draft, Nov 2026. Reference implementation: [`core/pair`](../core/pair) (sans-I/O:
tickets, PINs, the paired-device list, the exchange, a QR encoder),
[`app/pairing.zig`](../app/pairing.zig) and [`app/keystore.zig`](../app/keystore.zig)
(state directory, key storage, the exchange over a byte stream) and
[`app/pair_cmd.zig`](../app/pair_cmd.zig) (the `moonsec pair` commands over iroh). Design
context: [docs/design.md](../docs/design.md), "Transport".

There is no account server. A device's identity is its iroh endpoint key, and pairing adds
a client's key to a host's allowlist. After that, the host admits a session only from a
client on its list, and the client connects only to a host on its own list.

## Identity

- Each device has one Ed25519 secret key (32 bytes), created on first use and kept in a
  `KeyStore` (below). iroh binds with it, so the **endpoint ID** is its public key.
- Text form of an endpoint ID: 64 lowercase hex digits, as the shim prints it. The first 8
  digits are its short form in prompts and logs.
- iroh's QUIC handshake authenticates both endpoint IDs on every connection, so everything
  below runs on a channel where each side knows the other's ID for certain. Pairing does not
  add encryption; it adds proof that the client holds a secret the host is showing.

## Tickets

A ticket tells a client how to reach a host and which host to expect.

| Kind | Carries | Used for |
| --- | --- | --- |
| QR ticket | host ID, address, one-time 128-bit secret, expiry | scan (or paste) to pair, no PIN |
| address ticket | host ID, address | pair by typing the PIN |

Binary form, then the text form `MOONSEC1:` + RFC 4648 base32 (upper case, no padding) of
it. The text uses only QR alphanumeric characters. Decoders ignore case and whitespace.

| Size | Field | Meaning |
| ---: | --- | --- |
| 1 | `version` | `1`. Anything else: unsupported. |
| 1 | `flags` | bit 0: a secret follows. Other bits 0; decoders refuse a ticket with others set. |
| 32 | `host_id` | the host's endpoint ID |
| 16 | `secret` | only when flag bit 0 is set |
| 8 | `expires` | unix seconds after which the host refuses the secret; 0 = none (u64 LE) |
| 2 | `addr_len` | u16 LE, at most 1024 |
| n | `addr` | the shim's endpoint ticket text (`iroh_endpoint_ticket`), opaque to the core |
| 4 | `crc` | CRC-32 (IEEE) of everything above, LE. Catches typos in pasted tickets. |

The client dials `addr` and, before sending anything, checks that the connection's remote
ID equals `host_id`. A ticket whose `expires` has passed is refused locally.

## PIN

Six decimal digits, drawn uniformly (rejection sampling) from the host's secure RNG and
shown as `123 456`. Clients accept digits with spaces or dashes.

## Pairing window

The host pairs only while a window is open. A window holds:

- the QR secret and/or the PIN (`--qr-only`, `--pin-only` offer one),
- a deadline (default 120 s),
- **attempts**: wrong proofs allowed before the window locks (5),
- **pairings**: confirmed pairings before the window closes (default 1).

A window closes at its deadline, after its last pairing, or when its attempts run out.
Attempts are shared by every connection, so guessing on many connections gains nothing:
with 5 attempts, a PIN guesser wins with probability 5 × 10⁻⁶ per window. Refusals at
`hello` (no window, method not offered) cost no attempt.

## Exchange

On the first bidirectional stream the client opens (ALPN `moonsec/0`). Messages are framed
`len: u16 LE | kind: u8 | body`, `1 ≤ len ≤ 98`. Integers are little-endian.

```
client                                    host
hello(method, client_nonce, name)   ->
                                    <-    challenge(host_nonce, attempts_left) | reject
proof(client_mac)                   ->
                                    <-    accept(host_mac, host_name)          | reject
confirm                             ->    host adds the client to its allowlist
```

| Kind | Name | Direction | Body |
| ---: | --- | --- | --- |
| 1 | `hello` | C→H | `version` (1), `method`, `client_nonce[16]`, `name_len`, `name` (≤ 64 bytes UTF-8) |
| 2 | `challenge` | H→C | `host_nonce[16]`, `attempts_left`; PIN method: then `host_share[32]` |
| 3 | `proof` | C→H | PIN method: `client_share[32]`, then `client_mac[32]`; QR method: `client_mac[32]` |
| 4 | `accept` | H→C | `host_mac[32]`, `name_len`, `name` |
| 5 | `reject` | either | `reason`, `attempts_left` |
| 6 | `confirm` | C→H | (empty) |
| 7 | `admit` | C→H | admission `version` (0); see Admission |
| 8 | `admitted` | H→C | (empty) |

Methods: `1` QR ticket secret, `2` PIN. Nonces are fresh random bytes per connection.
Version 0 used a PIN-keyed HMAC for the PIN method too (no shares); a version 1 host refuses a
version 0 `hello` with `unsupported_version`. `admit` keeps its own version byte (0).

Keys and MACs (HMAC-SHA256, `label` = ASCII `moonsec-pair-v0`):

```
transcript = label || method || host_id || client_id || client_nonce || host_nonce || name_len || name
client_mac = HMAC(K, "client" || transcript)
host_mac   = HMAC(K, "host"   || transcript)
```

The key `K` depends on the method.

**QR method** (a 128-bit secret, so a plain HMAC key):

```
K = HMAC(key = label, method || secret)        secret = the 16 ticket bytes
```

**PIN method**: CPace ([draft-irtf-cfrg-cpace](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/),
simplified) over ristretto255, so that neither side can test PIN guesses offline. `lv(x)` is
one length byte then `x`; `H` is SHA-512.

```
g           = ristretto255.from_uniform(H(lv("moonsec-pair-v1-cpace") || lv(PIN digits as ASCII) ||
                lv(host_id) || lv(client_id) || lv(name) || lv(client_nonce) || lv(host_nonce)))
y           = reduce64(H(seed))                    seed = 32 fresh secret random bytes per connection
host_share  = g * y_host                           client_share = g * y_client
K           = H(lv("moonsec-pair-v1-cpace-isk") || lv(client_nonce) || lv(host_nonce) ||
                lv(peer_share * y_own) || lv(client_share) || lv(host_share))[0..32]
```

The host sends its share in the challenge, the client its share in the proof. Each side
refuses a share that does not decode to a ristretto255 point or decodes to the identity
(host: a wrong proof, costing an attempt; client: `reject(protocol)`). Why: with a MAC keyed
by the PIN alone, a host the client dials by mistake (an attacker's address ticket) receives
a proof it can check all 10⁶ PINs against in under a second, then pair with the real host
inside the window. With CPace the proof depends on `g * (y_client * y_host)`, which a host
that used another PIN for `g` cannot compute for any PIN guess without solving a discrete
logarithm, so each run tests exactly one guess, online.
`host_id` and `client_id` are the IDs the connection authenticated. Binding both means a
proof cannot be replayed on another connection, relayed to another host, or made for
another client. `name` is the client's name after sanitizing (below), so a host that
changes it fails the MAC. Both sides compare MACs in constant time.

The host checks the `proof`; a wrong one costs an attempt and gets `reject(bad_proof)`, or
`reject(locked)` for the last attempt. A right one gets `accept`, and the host holds the
pairing until `confirm`. The client checks `host_mac`; if it is wrong the client sends
`reject(host_proof)` and stops, and the host drops the pending pairing. On `confirm` the
host adds the client to its allowlist and the client adds the host (with its address) to
its own list. After the exchange, each side finishes its stream and waits for the other's
end before closing, so the last message is delivered.

Reject reasons: `1` no window, `2` method not offered, `3` bad proof, `4` locked,
`5` expired, `6` unsupported version, `7` protocol (malformed or unexpected message),
`8` host proof failed, `9` not paired.

## Admission

A client that wants a session opens its first stream and sends `admit`. The host answers
`admitted` if the connection's remote ID is on its allowlist and `reject(not_paired)`
otherwise, then closes the connection (application error `0x5050`). Media datagrams start
only after `admitted`. A client first checks that the host's ID is on its own list of
paired hosts and refuses to connect otherwise.

## Paired-device lists

Text, one device per line; `#` lines and blank lines are ignored:

```
# moonsec paired devices v0: id, paired (unix s), name, address, perms=
<64 hex id> TAB <paired unix s> TAB <name> [TAB <address>] [TAB perms=<list>]
```

`perms=` (on the host's list) says what the client may do besides watching and listening:
`input` (its keyboard, mouse and gamepad input is applied), `clipboard` (the clipboard syncs
with it), comma-separated, or `view` for neither. Without the field a client has both, so
lists from before permissions keep working; the host writes the field only when it is not
both. The host reads the list at every admission and applies the permissions of the device
behind the session's current connection: input it lacks is acknowledged and dropped, and
without the clipboard permission the control channel runs without the clipboard feature (a
revocation during a channel also drops clipboard messages at once). `moonsec pair host
--allow PERMS` sets them for devices paired in that window, `moonsec allow ID-PREFIX PERMS`
changes them, `moonsec paired` shows them; the C ABI has `moonsec_host_set_permissions`.

Names are sanitized on the way in: control characters and tabs become `?`, invalid UTF-8
bytes become `?`, and names are cut to 64 bytes at a character boundary. Addresses contain
no whitespace. The host keeps `paired-clients` (its allowlist); the client keeps
`paired-hosts` (with each host's address). Both are written like key files: 0600 on POSIX,
through a temporary file and a rename.

## Key storage

`KeyStore` loads, stores and removes named 32-byte keys. The device key is `identity`.

- `FileKeyStore`: `<state dir>/<name>.key`, holding the line `moonsec secret key v0`, then 64
  hex digits. On POSIX it is created 0600 in a 0700 directory, loading refuses a key file
  that group or others can read, and opening refuses a state directory that group or others
  can write (whoever can write it can replace the allowlist). Writes go through a temporary file and a rename.
- On Windows the file inherits the state directory's ACL (under `%APPDATA%`, the user's).
  A DPAPI store (Windows) and a Keychain store (macOS) come later behind the same interface.

The state directory is `--state-dir`, else `$MOONSEC_STATE_DIR`, else
`$XDG_CONFIG_HOME/moonsec` or `~/.config/moonsec` (Linux), `~/Library/Application
Support/moonsec` (macOS), `%APPDATA%\moonsec` (Windows).

## Not yet

- LAN discovery (mDNS), so a PIN alone finds the host without an address ticket.
- Revocation beyond `moonsec unpair` (which applies from the device's next connection).
- Permissions for multi-user members over `peer iroh` (the C ABI's multi-user host already
  takes "may control" from the `input` permission and syncs a member's clipboard only with
  `clipboard`).
- An external security review (Phase 7): threat model in [docs/security.md](../docs/security.md),
  reviewer packet and our findings in [docs/security-review.md](../docs/security-review.md).
