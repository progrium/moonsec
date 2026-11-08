# shim-web: iroh in the browser

The browser twin of the native shim ([`shim/`](../shim)): a wasm-bindgen crate over the same
iroh (`=1.4.1`), with the same Ed25519 endpoint keys, `EndpointTicket` text and ALPNs, so a
browser endpoint dials a native moonsec host directly. Pairing and admission
([spec/pairing-v0.md](../spec/pairing-v0.md)) run in the browser through `core/pair` compiled
to wasm, not a second implementation. Design context: docs/design.md, "Web client".

| Path | What it is |
| --- | --- |
| [`src/lib.rs`](src/lib.rs) | The crate: `Endpoint`, `Connection`, `BiStream` for JS |
| [`pair/pair.zig`](pair/pair.zig) | `core/pair` as a 35 KB wasm module (`zig build web-pair`) |
| [`js/pair.js`](js/pair.js) | Pairing (QR secret or PIN) and admission over a shim-web connection |
| [`js/transport.js`](js/transport.js) | `IrohTransport`: shim-web as the web client's datagram `Transport` (`web/src/transport.ts`) |
| [`build.sh`](build.sh) | Builds all of it into `pkg/` |
| [`test/`](test) | Headless browsers through a local relay to native moonsec ([`run.mjs`](test/run.mjs)) |

## Browser vs native

- **Relay only.** Browsers can't open UDP sockets, so every path is a relay path: QUIC
  packets over a WebSocket to the relay's HTTPS port. The native peer still holepunches to
  whatever else it talks to; with a browser it stays on the relay. A self-hosted relay is the
  browser's home relay (`relay/`), and a browser session's latency is the relay's.
- **The browser does the relay TLS.** There is no `relay_ca_pem`: the relay needs a
  certificate the browser trusts (Let's Encrypt in `relay/iroh-relay.toml`). The tests use
  the lab CA and tell the browser to ignore certificate errors.
- **No AppRate.** iroh's default congestion controller runs. The browser client mostly
  receives; it sends feedback, input and acks. `setTargetBitrate` and burst credit come when
  something in the browser needs to send media.
- **Promises.** Each blocking native call returns a `Promise`; its `timeoutMs` (0 or omitted
  means none) rejects with code `"timeout"`. There is no wakeup handle: `recvDatagram()` resolves
  on the next datagram and `drainDatagrams()` takes everything queued without waiting.
- **Datagram accounting** is simpler: the receive side matches native (wire, read, QUIC drops,
  queue drops, queued); the send side reports `dgramSent`, `dgramTxWire` and their difference
  `dgramSendBacklog` (evicted plus still queued, not split).

## API

Mirrors `shim/include/iroh_shim.h` where it makes sense. Errors are `Error`s with `code`:
`"invalid"`, `"closed"`, `"timeout"`, `"busy"`, `"internal"`. Types: `pkg/iroh_web.d.ts`.

```js
import init, { Endpoint } from "./pkg/iroh_web.js";
import { loadPair, ALPN } from "./js/pair.js";
import { IrohTransport } from "./js/transport.js";
await init();

const ep = await Endpoint.bind({ relayUrls: ["https://relay.example.com"], secretKey });  // key optional
await ep.online(15000);
ep.id; ep.secretKey(); ep.ticket();

// Pair once (QR ticket text, or an address ticket plus the PIN), keep the result and the key.
const pair = await loadPair(new URL("./pkg/moonsec-pair.wasm", import.meta.url));
const host = await pair.pairWithTicket(ep, "MOONSEC1:...", { name: "Browser", pin: "" });

// Start a session: dial, admit, then datagrams.
const conn = await ep.connect(host.addr, ALPN, 30000);
await pair.admit(conn);
const t = new IrohTransport(conn);
t.onDatagram = (d) => { /* wire-v0 message */ };
t.send(bytes);
```

| JS | Native |
| --- | --- |
| `Endpoint.bind({secretKey, alpn, relayMode, relayUrls, datagramSendBuffer, datagramRecvBuffer, recvQueueLen, connIdleTimeoutMs})` | `iroh_endpoint_bind`; `relayMode` is `"custom"` (default: only `relayUrls`, dial by ticket) or `"default"` (n0) |
| `ep.online(ms)`, `ep.id`, `ep.ticket()`, `ep.connect(ticket, alpn, ms)`, `ep.accept(ms)`, `ep.close()` | `iroh_endpoint_*` |
| `ep.secretKey()` | (the native key lives in the key store) |
| `conn.sendDatagram(u8)`, `conn.recvDatagram(ms)`, `conn.drainDatagrams(max)` | `iroh_conn_send_datagram`, `_recv_datagram` |
| `conn.maxDatagramSize()`, `conn.remoteId`, `conn.close(code, reason)`, `conn.closed()` | `_max_datagram_size`, `_remote_id`, `iroh_conn_free` |
| `conn.pollEvent()` | `iroh_conn_poll_event`: `{kind, name, pathId, tUs, value, isRelay, remoteAddr}`, kinds = `IROH_EV_*` (no no-ack-progress events) |
| `conn.stats()`, `conn.pathStats()` | `iroh_conn_stats`, `_path_stats`, camelCase fields |
| `conn.openBi(ms)`, `conn.acceptBi(ms)`, `s.write(u8, ms)`, `s.read(max, ms)` (`null` = end), `s.finish()`, `s.reset(code)` | `iroh_conn_open_bi`, `iroh_stream_*` |
| `nowUs()`, `version()` | `iroh_shim_now_us`, `iroh_shim_version` (0x000200) |

Size: `iroh_web_bg.wasm` is 4.9 MB, 1.35 MB gzipped (release, `opt-level = "s"`, fat LTO,
no `wasm-opt` yet), plus 56 KB of JS bindings and the 35 KB pairing module.

## Build and test

```sh
cargo install wasm-bindgen-cli@0.2.106 --locked      # must match Cargo.lock
cargo install iroh-relay@1.4.1 --features server --locked
shim-web/build.sh                                    # pkg/: wasm, bindings, moonsec-pair.wasm
zig build install-moonsec -Doptimize=ReleaseSafe     # native peers: shim-echo, moonsec
(cd shim-web/test && npm install && npx playwright install chromium firefox webkit)
node shim-web/test/run.mjs --browsers chromium,firefox,webkit
```

`run.mjs` starts `iroh-relay` with `relay/lab.toml` and a lab CA, serves the test page, runs
`shim-echo serve` (datagram and stream echo, plus throughput commands) and, per browser:

1. **echo**: 200 sequential 1150-byte datagram pings, a 100-datagram burst through
   `IrohTransport`, and 256 KiB through a bidirectional stream, all checked byte for byte;
   every browser path must be a relay path.
2. **rate**: native to browser and browser to native at 2, 10, 25 and 50 Mbit/s offered.
3. **pairing**: `moonsec pair host --qr-only` and the browser pairs with the QR ticket's
   secret; then `--pin-only`, where a wrong PIN is refused (4 attempts left) and the right one
   pairs. `moonsec paired` must list both browser keys, and core/pair must derive the same ID
   from the key as iroh does.
4. **admission**: `moonsec peer iroh host --state-dir` refuses an unpaired browser key
   (`not_paired`) and admits the paired one.

CI: [`.github/workflows/shim-web.yml`](../.github/workflows/shim-web.yml). Chromium gates;
Firefox and WebKit run with `continue-on-error` until they have been seen green.

## Measurements (local relay, one machine)

Container, Nov 8 2026, headless Chromium 153 (Playwright 1.63), relay/lab.toml on loopback
(per-client limit 50 Mbit/s), native peer `shim-echo serve` in ReleaseSafe:

- online (home relay) 250 ms, connect 27 ms, max datagram 1414 B over the relay
- datagram echo, 200 x 1150 B: RTT min 0.3 / p50 0.8 / p90 1.1 / p99 3.5 / max 5.9 ms
- stream echo, 256 KiB: 45 ms
- pairing exchange (after connect): 10 ms (QR), 12 ms (PIN)

| offered | native to browser | loss | browser to native | loss |
| ---: | ---: | ---: | ---: | ---: |
| 2 Mbit/s | 2.0 Mbit/s | 0% | 2.0 Mbit/s | 0% |
| 10 Mbit/s | 10.0 Mbit/s | 0% | 10.0 Mbit/s | 0% |
| 25 Mbit/s | 24.9 Mbit/s | 0% | 25.0 Mbit/s | 0% |
| 50 Mbit/s | 48.8 Mbit/s | 0% | 49.9 Mbit/s | 0% |

So on loopback the relay path is not the limit below the relay's own per-client cap; 1080p60
at 20–30 Mbit/s fits. What a public relay adds (RTT to the relay, its uplink, WebSocket
over TCP under loss) is the Phase 6 gate's question and needs the deployed relay.

## Not covered yet

- **Firefox and WebKit** run in CI only (the container has no Playwright Firefox/WebKit
  builds); real Safari is 6C's harness.
- **A public relay** with a real certificate, and real networks between browser and relay.
- **A full session**: admission passes, then `moonsec peer iroh host` waits for the client's
  session setup, which the web client (6B) sends. The admission test counts 0 media datagrams
  in its second of listening for that reason.
- AppRate and burst credit in the browser; send-side eviction accounting; `wasm-opt`.
