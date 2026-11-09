// Stub host for the browser test harness. Stands in for a moonsec host behind a relay
// until shim-web (6A) and the media pipeline (6B) land:
//
// - /ws: datagrams over WebSocket (web/src/transport.ts). Input datagrams are decoded
//   by the core's own input Receiver (zig-out/web/moonsec-host-stub.wasm) and acked, so
//   input is checked against the same code a real host runs. `?loss=0.3` drops that
//   share of input datagrams and acks (seeded, deterministic) to exercise redundancy.
// - /media: replays the committed video fixtures and a 440 Hz tone for the decode and
//   audio checks (test framing, not the wire format; see harness.ts).
// - /state, /reset: what the "host" applied, for the tests to compare.
// - Static: the harness page, the bundles in web/dist, the wasm in zig-out/web.
//
// Usage: node e2e/stub-host.mjs [--port 8787]

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { WebSocketServer } from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, "..");
const repoRoot = path.resolve(webRoot, "..");

const args = process.argv.slice(2);
const portArg = args.indexOf("--port");
const port = portArg >= 0 ? Number(args[portArg + 1]) : Number(process.env.PORT ?? 8787);

const wasmBytes = await readFile(path.join(repoRoot, "zig-out/web/moonsec-host-stub.wasm"));
const wasmModule = await WebAssembly.compile(wasmBytes);

// --- fixtures -------------------------------------------------------------

/** Split an Annex B stream into access units at access unit delimiters (NAL type 9). */
function splitAnnexB(buf) {
  const starts = [];
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 0 && buf[i + 1] === 0 && buf[i + 2] === 1) {
      const nalStart = i + 3;
      const zero4 = i > 0 && buf[i - 1] === 0;
      if ((buf[nalStart] & 0x1f) === 9) starts.push(zero4 ? i - 1 : i);
      i += 2;
    }
  }
  const units = [];
  for (let k = 0; k < starts.length; k++) {
    const data = buf.subarray(starts[k], k + 1 < starts.length ? starts[k + 1] : buf.length);
    let key = false;
    for (let i = 0; i + 3 < data.length; i++) {
      if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1 && (data[i + 3] & 0x1f) === 5) key = true;
    }
    units.push({ key, data });
  }
  return units;
}

/** Frames of an IVF file. */
function splitIvf(buf) {
  const headerLen = buf.readUInt16LE(6);
  const frames = [];
  let off = headerLen;
  while (off + 12 <= buf.length) {
    const size = buf.readUInt32LE(off);
    const data = buf.subarray(off + 12, off + 12 + size);
    // VP8: bit 0 of the first byte is 0 for a keyframe.
    frames.push({ key: (data[0] & 1) === 0, data });
    off += 12 + size;
  }
  return frames;
}

const fixtures = {
  h264: splitAnnexB(await readFile(path.join(here, "testdata/testsrc_320x180_60f.h264"))),
  vp8: splitIvf(await readFile(path.join(here, "testdata/testsrc_320x180_60f.ivf"))),
};

// --- input host -----------------------------------------------------------

const actionWords = 10;
const statNames = ["packets", "stalePackets", "events", "duplicateEvents", "lostEvents", "reconciled"];

class InputHost {
  constructor(ws, loss, seed) {
    this.ws = ws;
    this.loss = loss;
    this.rng = seed >>> 0 || 1;
    this.inst = new WebAssembly.Instance(wasmModule, {});
    this.x = this.inst.exports;
    this.x.moonsec_host_reset();
    this.seq = 0;
    this.state = {
      keysDown: [],
      keyLog: [],
      buttonsDown: [],
      buttonLog: [],
      scroll: { x: 0, y: 0 },
      motion: { x: 0, y: 0 },
      abs: null,
      pads: [null, null, null, null],
      padUpdates: 0,
      datagrams: 0,
      dropped: 0,
      acksDropped: 0,
      bad: 0,
    };
  }

  /** xorshift32: deterministic loss for a given seed. */
  random() {
    let x = this.rng;
    x ^= x << 13;
    x >>>= 0;
    x ^= x >>> 17;
    x ^= x << 5;
    x >>>= 0;
    this.rng = x;
    return x / 2 ** 32;
  }

  onDatagram(buf) {
    const s = this.state;
    s.datagrams++;
    if (this.loss > 0 && this.random() < this.loss) {
      s.dropped++;
      return;
    }
    if (buf.length > this.x.moonsec_host_in_cap()) return void s.bad++;
    new Uint8Array(this.x.memory.buffer, this.x.moonsec_host_in_ptr(), buf.length).set(buf);
    const n = this.x.moonsec_host_on_datagram(buf.length);
    if (n === -2) return; // not input
    if (n < 0) return void s.bad++;
    const w = new Int32Array(this.x.memory.buffer, this.x.moonsec_host_actions_ptr(), n * actionWords);
    for (let i = 0; i < n; i++) this.apply(w.subarray(i * actionWords, (i + 1) * actionWords));
    if (this.loss > 0 && this.random() < this.loss) {
      s.acksDropped++;
      return;
    }
    const len = this.x.moonsec_host_build_ack(this.seq++ >>> 0);
    this.ws.send(new Uint8Array(this.x.memory.buffer, this.x.moonsec_host_out_ptr(), len).slice());
  }

  apply(w) {
    const s = this.state;
    switch (w[0]) {
      case 1: {
        const [code, down] = [w[1], w[2] !== 0];
        s.keyLog.push([code, down]);
        s.keysDown = down ? [...new Set([...s.keysDown, code])] : s.keysDown.filter((k) => k !== code);
        break;
      }
      case 2: {
        const [code, down] = [w[1], w[2] !== 0];
        s.buttonLog.push([code, down]);
        s.buttonsDown = down ? [...new Set([...s.buttonsDown, code])] : s.buttonsDown.filter((b) => b !== code);
        break;
      }
      case 3:
        s.scroll.x += w[1];
        s.scroll.y += w[2];
        break;
      case 4:
        s.motion.x += w[1];
        s.motion.y += w[2];
        break;
      case 5:
        s.abs = { x: w[1], y: w[2] };
        break;
      case 6:
        s.padUpdates++;
        s.pads[w[1]] = w[2]
          ? { buttons: w[3] >>> 0, lx: w[4], ly: w[5], rx: w[6], ry: w[7], lt: w[8], rt: w[9] }
          : null;
        break;
    }
  }

  snapshot() {
    const stats = {};
    statNames.forEach((name, i) => (stats[name] = this.x.moonsec_host_stat(i)));
    return { ...this.state, receiver: stats, loss: this.loss };
  }
}

let latest = null;

// --- media stub -----------------------------------------------------------

/** Frame message: u8 1, u8 key, u32 index, u32 count, data. End: u8 255. */
async function streamVideo(ws, codec, fps) {
  const frames = fixtures[codec];
  if (!frames) return ws.send(JSON.stringify({ error: `no fixture for ${codec}` }));
  const interval = 1000 / fps;
  const t0 = performance.now();
  for (let i = 0; i < frames.length; i++) {
    if (ws.readyState !== ws.OPEN) return;
    const f = frames[i];
    const msg = Buffer.alloc(10 + f.data.length);
    msg[0] = 1;
    msg[1] = f.key ? 1 : 0;
    msg.writeUInt32LE(i, 2);
    msg.writeUInt32LE(frames.length, 6);
    f.data.copy(msg, 10);
    ws.send(msg);
    const due = t0 + (i + 1) * interval;
    await new Promise((r) => setTimeout(r, Math.max(0, due - performance.now())));
  }
  ws.send(Buffer.from([255]));
}

/** Audio message: u8 2, then 20 ms of 48 kHz mono f32 PCM (960 samples): a 440 Hz tone. */
async function streamAudio(ws, ms) {
  const rate = 48000;
  const per = 960;
  let phase = 0;
  const t0 = performance.now();
  for (let k = 0; k * 20 < ms; k++) {
    if (ws.readyState !== ws.OPEN) return;
    const pcm = new Float32Array(per);
    for (let i = 0; i < per; i++) {
      pcm[i] = 0.5 * Math.sin(phase);
      phase += (2 * Math.PI * 440) / rate;
    }
    const msg = Buffer.alloc(1 + pcm.byteLength);
    msg[0] = 2;
    Buffer.from(pcm.buffer).copy(msg, 1);
    ws.send(msg);
    const due = t0 + (k + 1) * 20;
    await new Promise((r) => setTimeout(r, Math.max(0, due - performance.now())));
  }
  ws.send(Buffer.from([255]));
}

// --- HTTP -----------------------------------------------------------------

const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".map": "application/json",
  ".wasm": "application/wasm",
  ".json": "application/json",
};

const routes = [
  ["/dist/", path.join(webRoot, "dist")],
  ["/wasm/", path.join(repoRoot, "zig-out/web")],
];

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const send = (status, body, type = "application/json") => {
    res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
    res.end(body);
  };
  if (url.pathname === "/state") return send(200, JSON.stringify(latest ? latest.snapshot() : null));
  if (url.pathname === "/" || url.pathname === "/harness.html") {
    return send(200, await readFile(path.join(here, "harness.html")), types[".html"]);
  }
  for (const [prefix, dir] of routes) {
    if (!url.pathname.startsWith(prefix)) continue;
    const file = path.join(dir, path.normalize(url.pathname.slice(prefix.length)));
    if (!file.startsWith(dir)) return send(403, "{}");
    try {
      return send(200, await readFile(file), types[path.extname(file)] ?? "application/octet-stream");
    } catch {
      return send(404, "{}");
    }
  }
  send(404, "{}");
});

const wss = new WebSocketServer({ noServer: true });
server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url, "http://localhost");
  wss.handleUpgrade(req, socket, head, (ws) => {
    if (url.pathname === "/ws") {
      const host = new InputHost(ws, Number(url.searchParams.get("loss") ?? 0), Number(url.searchParams.get("seed") ?? 1));
      latest = host;
      ws.on("message", (data, isBinary) => isBinary && host.onDatagram(new Uint8Array(data)));
    } else if (url.pathname === "/media") {
      ws.on("message", (data, isBinary) => {
        if (isBinary) return;
        const req = JSON.parse(String(data));
        if (req.video) void streamVideo(ws, req.video, req.fps ?? 30);
        if (req.audio) void streamAudio(ws, req.ms ?? 1000);
      });
    } else {
      ws.close();
    }
  });
});

server.listen(port, "127.0.0.1", () => console.log(`stub host on http://127.0.0.1:${port}/`));
