// Test host for the web client's media pipeline: a real moonsec host (the native
// `moonsec-sim` binary, `zig build web-host`) replaying an H.264 fixture through the
// whole host session (packetizer, NACK retransmits, recovery, rate controller, Opus
// audio), bridged to the browser over WebSocket until shim-web's iroh transport (6A)
// replaces the bridge.
//
//   browser (web/src/media) --WebSocket /ws-- this server --UDP-- moonsec-sim peer sim host
//
// The host runs `peer sim host --hub PORT`: it speaks transport/simlink.zig's hub
// protocol over loopback UDP, and this server is the hub. Every WebSocket gets its own
// host process and hub socket. Datagrams pass straight through; there is no simulated
// network in between (the WebSocket is TCP, like a relay), unless the WebSocket URL asks
// for loss: `/ws?loss=0.05&outage=2000:300&seed=1` drops that share of host-to-browser
// datagrams (seeded), and every one for 300 ms starting 2 s into the session, so NACKs,
// recovery and the browser's drop-until-keyframe path run.
//
// Also serves client.html, web/dist and zig-out/web (wasm under /dist/). Logs each host's
// end-of-session report to stderr, and keeps the last ones at /reports.
//
// Usage: node e2e/media-host.mjs [--port 8788] [--fixture PATH] [--fps 60] [--size 640x360]

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createSocket } from "node:dgram";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { WebSocketServer } from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, "..");
const repoRoot = path.resolve(webRoot, "..");

const args = process.argv.slice(2);
const arg = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
};
const port = Number(arg("--port", process.env.MEDIA_PORT ?? 8788));
const fixture = path.resolve(arg("--fixture", path.join(webRoot, "testdata/testsrc_640x360_60.h264")));
const fps = arg("--fps", "60");
const size = arg("--size", "640x360");
const hostBin = path.join(repoRoot, "zig-out/bin", process.platform === "win32" ? "moonsec-sim.exe" : "moonsec-sim");

/** Host reports, newest last. */
const reports = [];
let sessions = 0;

/** Deterministic PRNG (mulberry32). */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function startHost(ws, query) {
  const id = ++sessions;
  const loss = Number(query.get("loss") ?? 0);
  const [outAt, outFor] = (query.get("outage") ?? "0:0").split(":").map(Number);
  const random = rng(Number(query.get("seed") ?? 1));
  const t0 = Date.now();
  let dropped = 0;
  const drop = () => {
    const t = Date.now() - t0;
    if (outFor > 0 && t >= outAt && t < outAt + outFor) return true;
    return loss > 0 && random() < loss;
  };
  const udp = createSocket("udp4");
  let peer = null; // the host's address, once it registered
  const early = []; // browser datagrams before the host registered
  let child = null;
  let closed = false;
  let out = "";

  const toHost = (tag, body) => {
    const b = Buffer.alloc(1 + (body ? body.length : 0));
    b[0] = tag.charCodeAt(0);
    if (body) b.set(body, 1);
    udp.send(b, peer.port, peer.address);
  };

  udp.on("message", (msg, rinfo) => {
    switch (String.fromCharCode(msg[0])) {
      case "H": // register (repeated until answered)
        peer = rinfo;
        toHost("W");
        for (const d of early.splice(0)) toHost("D", d);
        break;
      case "D":
        if (drop()) dropped++;
        else if (ws.readyState === ws.OPEN) ws.send(msg.subarray(1), { binary: true });
        break;
      case "R": // pacing rate: the WebSocket does its own flow control
        break;
    }
  });

  // Path stats every 50 ms ('S' i64 rtt, u64 send drops, recv drops, send queue bytes).
  const stats = setInterval(() => {
    if (!peer) return;
    const b = Buffer.alloc(32);
    b.writeBigUInt64LE(BigInt(ws.bufferedAmount ?? 0), 24);
    toHost("S", b);
  }, 50);

  udp.bind(0, "127.0.0.1", () => {
    const argv = ["peer", "sim", "host", "--hub", String(udp.address().port), "--fixture", fixture, "--size", size, "--fps", fps, "--bitrate", "1000000"];
    child = spawn(hostBin, argv, { stdio: ["ignore", "pipe", "pipe"] });
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", (e) => {
      console.error(`[media-host] session ${id}: cannot start ${hostBin}: ${e.message} (run \`zig build web-host\`)`);
      ws.close();
    });
    child.on("exit", (code) => {
      clearInterval(stats);
      udp.close();
      reports.push({ session: id, code, dropped, report: out });
      while (reports.length > 20) reports.shift();
      console.error(`[media-host] session ${id}: host exited ${code}, bridge dropped ${dropped}\n${out}`);
      if (ws.readyState === ws.OPEN) ws.close();
    });
  });

  ws.on("message", (data, isBinary) => {
    if (!isBinary) return;
    const d = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (peer) toHost("D", d);
    else if (early.length < 256) early.push(d);
  });
  ws.on("close", () => {
    if (closed) return;
    closed = true;
    // The host ends on the client's bye, or on its 5 s peer timeout; don't wait longer.
    setTimeout(() => child && child.exitCode === null && child.kill(), 7000);
  });
}

const types = { ".html": "text/html", ".js": "text/javascript", ".map": "application/json", ".wasm": "application/wasm", ".json": "application/json" };

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/reports") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify(reports));
  }
  let rel = url.pathname === "/" ? "/client.html" : url.pathname;
  const candidates = [path.join(webRoot, rel)];
  if (rel.startsWith("/dist/")) candidates.push(path.join(repoRoot, "zig-out/web", rel.slice(6)));
  for (const file of candidates) {
    if (!file.startsWith(webRoot) && !file.startsWith(path.join(repoRoot, "zig-out"))) break;
    try {
      const body = await readFile(file);
      res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
      return res.end(body);
    } catch {}
  }
  res.writeHead(404);
  res.end("not found");
});

const wss = new WebSocketServer({ server, path: "/ws" });
wss.on("connection", (ws, req) => startHost(ws, new URL(req.url, "http://x").searchParams));

server.listen(port, "127.0.0.1", () => console.error(`[media-host] http://127.0.0.1:${port}/ (fixture ${path.relative(repoRoot, fixture)})`));
