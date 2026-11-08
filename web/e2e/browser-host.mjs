#!/usr/bin/env node
// Browser host spike, end to end: a headless Chromium tab hosts the demo game (host.html:
// canvas -> WebCodecs -> core in wasm -> iroh) and another tab plays it as a client
// (client.html over iroh), both through a local iroh-relay.
//
//   node web/e2e/browser-host.mjs [--variants default,webcodecs-audio,stream,av1] [--seconds 6]
//                                 [--samples 20] [--json out.json] [--headed]
//
// Needs: zig-out/web (zig build web-wasm), shim-web/pkg (shim-web/build.sh), web/dist
// (npm run build), iroh-relay 1.4.1 on PATH (or IROH_RELAY), openssl, Playwright's Chromium.
//
// Checks per variant: the client streams, frames are drawn and not blank, the game's audio
// is heard (client) and captured (host); keys, mouse (position, buttons, wheel) and a
// gamepad reach the game. Measures input-to-photon latency on the demo's probe square
// (hold L / left button / pad A: the square turns white) from the client page's DOM event
// to the client drawing the frame that shows the change, plus the core's stage times.
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const web = resolve(here, "..");
const root = resolve(web, "..");
const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith("--") ? [...a, [v.slice(2), all[i + 1]?.startsWith("--") ? "1" : (all[i + 1] ?? "1")]] : a), []));
const variants = (args.variants ?? "default,webcodecs-audio,stream").split(",");
const seconds = Number(args.seconds ?? 6);
const samples = Number(args.samples ?? 20);
const relayUrl = "https://127.0.0.1:3443";

const variantQuery = {
  default: "",
  "webcodecs-audio": "&audioenc=webcodecs",
  stream: "&capture=stream",
  av1: "&codec=av1",
  // 2% of the host's datagrams dropped, and all of them for 400 ms every 3 s: recovery with keyframes only, then with long-term
  // references (WebCodecs manual reference buffers, a Chromium feature flag; see README).
  loss: "&loss=0.02&outage=400&ltr=0",
  "loss-av1": "&loss=0.02&outage=400&codec=av1&ltr=0",
  "loss-ltr-av1": "&loss=0.02&outage=400&codec=av1",
  // Headed only (xvfb-run): another tab in front of the host for 8 s.
  background: "",
};
const launchArgs = (v) => ["--autoplay-policy=no-user-gesture-required", ...(v.includes("ltr") ? ["--enable-blink-features=WebCodecsVideoEncoderBuffers"] : [])];

const require_ = createRequire(join(web, "package.json"));
const { chromium } = require_("playwright");

const procs = [];
function start(name, cmd, argv, opts = {}) {
  const p = spawn(cmd, argv, { stdio: ["ignore", "pipe", "pipe"], ...opts });
  p.log = "";
  const tee = (d) => {
    p.log += d;
    if (process.env.VERBOSE) process.stderr.write(`[${name}] ${d}`);
  };
  p.stdout.on("data", tee);
  p.stderr.on("data", tee);
  procs.push(p);
  return p;
}
process.on("exit", () => procs.forEach((p) => p.exitCode === null && p.kill("SIGKILL")));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(what, fn, ms = 20000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await sleep(50);
  }
  throw new Error(`timed out waiting for ${what}`);
}

// --- relay ------------------------------------------------------------------------------
const lab = mkdtempSync(join(tmpdir(), "browser-host-"));
execFileSync(join(root, "relay/lab-cert.sh"), [lab], { stdio: "ignore" });
start("relay", process.env.IROH_RELAY ?? "iroh-relay", ["--config-path", join(root, "relay/lab.toml")], { cwd: lab });
await waitFor("relay", () => {
  try {
    execFileSync("curl", ["-sf", "--cacert", join(lab, "ca.crt"), `${relayUrl}/ping`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
});

// --- static server: web/ (pages, demo, dist), zig-out/web wasm, shim-web/pkg ---------------
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".map": "application/json" };
const server = createServer((req, res) => {
  const p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  let file;
  if (p.startsWith("/pkg/")) file = join(root, "shim-web/pkg", p.slice(5));
  else if (p.startsWith("/dist/") && p.endsWith(".wasm")) file = join(root, "zig-out/web", p.slice(6));
  else file = join(web, p);
  if (!file.startsWith(root) || file.includes("..")) return res.writeHead(403).end();
  if (!existsSync(file)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" }).end(readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

// --- helpers ------------------------------------------------------------------------------
const pct = (xs, p) => {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
const summary = (xs) => ({ n: xs.length, min: pct(xs, 0), p50: pct(xs, 50), p90: pct(xs, 90), max: pct(xs, 100) });
const round = (o) => JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === "number" ? Math.round(v * 100) / 100 : v)));

// A scriptable gamepad on the client page (the client's InputCapture polls getGamepads).
function fakePad() {
  const pad = {
    id: "test pad (STANDARD GAMEPAD Vendor: 054c Product: 09cc)",
    index: 0,
    connected: true,
    mapping: "standard",
    timestamp: 0,
    axes: [0, 0, 0, 0],
    buttons: Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 })),
  };
  window.__pad = {
    set(i, on) {
      pad.buttons[i] = { pressed: on, touched: on, value: on ? 1 : 0 };
      pad.timestamp = performance.now();
      window.__padAt = performance.timeOrigin * 1000 + performance.now() * 1000;
    },
    axis(i, v) {
      pad.axes[i] = v;
      pad.timestamp = performance.now();
    },
  };
  Object.defineProperty(navigator, "getGamepads", { value: () => [{ ...pad, buttons: pad.buttons.map((b) => ({ ...b })), axes: [...pad.axes] }, null, null, null] });
  // DOM event times on the client page, absolute µs.
  const abs = (e) => (performance.timeOrigin + e.timeStamp) * 1000;
  addEventListener("keydown", (e) => (window.__keyAt = abs(e)), true);
  addEventListener("mousedown", (e) => (window.__mouseAt = abs(e)), true);
}

async function runVariant(browser, name) {
  const r = { variant: name, failures: [] };
  const check = (cond, what) => {
    if (!cond) r.failures.push(what);
  };
  const hostCtx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1000, height: 760 } });
  const clientCtx = process.env.ONECTX ? hostCtx : await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1000, height: 600 } });
  const host = await hostCtx.newPage();
  const client = await clientCtx.newPage();
  const logs = [];
  for (const [who, p] of [["host", host], ["client", client]]) {
    p.on("console", (m) => {
      if (m.type() === "error" || process.env.VERBOSE) logs.push(`[${who}] ${m.text()}`);
    });
    p.on("pageerror", (e) => logs.push(`[${who}] pageerror ${e.message}`));
  }
  try {
    const t0 = Date.now();
    await host.goto(`${base}/host.html?autostart&relay=${encodeURIComponent(relayUrl)}${variantQuery[name] ?? ""}`);
    const ticket = await waitFor("host ticket", () => host.evaluate(() => window.moonsecHost.report?.ticket), 30000);
    r.hostReadyMs = Date.now() - t0;
    await client.addInitScript(fakePad);
    const t1 = Date.now();
    await client.goto(`${base}/client.html?autostart&probe&mouse=absolute&ticket=${encodeURIComponent(ticket)}&relay=${encodeURIComponent(relayUrl)}`);
    await waitFor("client streaming", () => client.evaluate(() => window.moonsec.stats?.state === "streaming" && window.moonsec.stats.video.drawn > 0), 30000);
    r.connectToFirstFrameMs = Date.now() - t1;

    // --- stream ---
    await sleep(seconds * 1000);
    const cs = await client.evaluate(() => window.moonsec.stats);
    if (process.env.DEBUG) console.error("CLIENT", JSON.stringify(cs.transport));
    const hs = await host.evaluate(() => window.moonsecHost.report);
    if (process.env.DEBUG) console.error(JSON.stringify(hs).slice(0, 3000));
    r.codec = hs.codec;
    r.client = { video: { ...cs.video, decodeMs: undefined, drawMs: undefined }, audio: cs.audio, stages: cs.overlay.stages, rttMs: cs.overlay.rttUs / 1000, stats: cs.stats };
    r.host = { transport: hs.transport, stats: hs.stats, encoder: hs.encoder, audio: hs.audio, captured: await host.evaluate(() => window.moonsecHost.host.captured) };
    check(cs.video.drawn > seconds * (name.startsWith("loss") ? 20 : 30), `client drew ${cs.video.drawn} frames in ${seconds}s`);
    check(cs.video.nonBlank, "client frames are blank");
    check(cs.video.errors.length === 0, `decode errors: ${cs.video.errors.join("; ")}`);
    check(cs.audio.loud > 0, `client heard no audio (played ${cs.audio.played})`);
    check(hs.stats.audio_frames > 0, "host sent no audio");
    check(hs.encoder.errors.length === 0, `encoder errors: ${hs.encoder.errors.join("; ")}`);

    if (name === "background") {
      const sample = async () => ({
        drawn: await client.evaluate(() => window.moonsec.stats.video.drawn),
        captured: await host.evaluate(() => window.moonsecHost.host.captured),
        gameFrames: await host.evaluate(() => window.game.frame),
        timerFrames: await host.evaluate(() => window.__moonsecHost.timerFrames),
        audio: await client.evaluate(() => window.moonsec.stats.stats.audio_decoded),
        vis: await host.evaluate(() => document.visibilityState),
      });
      const rates = async (ms) => {
        const a = await sample();
        await sleep(ms);
        const b = await sample();
        const per = (k) => Math.round(((b[k] - a[k]) * 1000) / ms);
        return { visibility: b.vis, timerFramesPerS: per("timerFrames"), clientFps: per("drawn"), capturedFps: per("captured"), gameFps: per("gameFrames"), audioFramesPerS: per("audio") };
      };
      r.background = { front: await rates(3000) };
      const other = await hostCtx.newPage();
      await other.goto("about:blank");
      await other.bringToFront();
      await sleep(1000);
      r.background.behind = await rates(8000);
      await host.bringToFront();
      await other.close();
      await sleep(500);
      r.background.frontAgain = await rates(3000);
      process.stderr.write(`  ${JSON.stringify(r.background)}\n`);
    }

    // --- input reaches the game ---
    const canvas = await client.$("#video");
    const box = await canvas.boundingBox();
    const g0 = await host.evaluate(() => ({ x: window.game.x, y: window.game.y, r: window.game.r }));
    // The client takes keys while its canvas has focus, which a click gives it.
    await client.mouse.click(box.x + box.width * 0.5, box.y + box.height * 0.5);
    await client.mouse.move(box.x + box.width * 0.25, box.y + box.height * 0.75);
    await client.mouse.move(box.x + box.width * 0.75, box.y + box.height * 0.25, { steps: 5 });
    await client.keyboard.down("ArrowRight");
    await sleep(400);
    await client.keyboard.up("ArrowRight");
    await client.mouse.wheel(0, -100);
    await client.evaluate(() => {
      window.__pad.axis(1, -1); // left stick up
    });
    await sleep(400);
    await client.evaluate(() => window.__pad.axis(1, 0));
    await sleep(300);
    const g1 = await host.evaluate(() => ({ x: window.game.x, y: window.game.y, r: window.game.r, mouse: window.game.mouse, wheel: window.game.wheel, pad: window.game.pad, keyCodesSeen: [...window.game.keyCodes] }));
    r.input = { before: g0, after: g1, injector: await host.evaluate(() => window.moonsecHost.host.injector.stats) };
    check(g1.x > g0.x + 20, `ArrowRight did not move the player (${g0.x} -> ${g1.x})`);
    check(g1.y < g0.y - 20, `left stick up did not move the player (${g0.y} -> ${g1.y})`);
    check(Math.abs(g1.mouse.x - 960 * 0.75) < 8 && Math.abs(g1.mouse.y - 540 * 0.25) < 8, `mouse landed at ${g1.mouse.x},${g1.mouse.y}, want 720,135`);
    check(g1.wheel !== 0 && g1.r !== g0.r, "wheel did not reach the game");
    check(g1.pad.id.includes("moonsec"), `no virtual pad in getGamepads (id "${g1.pad.id}")`);

    // --- input to photon ---
    const waitProbe = async (light, after) =>
      waitFor(`probe ${light ? "light" : "dark"}`, () => client.evaluate(([l, a]) => window.moonsec.probe.find((e) => e.light === l && e.at > a)?.at, [light, after]), 3000);
    const now = () => client.evaluate(() => (performance.timeOrigin + performance.now()) * 1000);
    const lat = { key: [], mouse: [], pad: [] };
    await waitProbe(false, 0).catch(() => {});
    for (let i = 0; i < samples; i++) {
      for (const kind of ["key", "mouse", "pad"]) {
        const before = await now();
        if (kind === "key") await client.keyboard.down("KeyL");
        if (kind === "mouse") await client.mouse.down();
        if (kind === "pad") await client.evaluate(() => window.__pad.set(0, true));
        const at = await client.evaluate((k) => (k === "key" ? window.__keyAt : k === "mouse" ? window.__mouseAt : window.__padAt), kind);
        try {
          const shown = await waitProbe(true, before);
          lat[kind].push((shown - at) / 1000);
        } catch {
          r.failures.push(`${kind} press ${i} never showed`);
        }
        const up = await now();
        if (kind === "key") await client.keyboard.up("KeyL");
        if (kind === "mouse") await client.mouse.up();
        if (kind === "pad") await client.evaluate(() => window.__pad.set(0, false));
        await waitProbe(false, up).catch(() => r.failures.push(`${kind} release ${i} never showed`));
        await sleep(30 + Math.random() * 30);
      }
    }
    r.inputToPhotonMs = { key: summary(lat.key), mouse: summary(lat.mouse), pad: summary(lat.pad) };
    const hs2 = await host.evaluate(() => window.moonsecHost.report);
    const cs2 = await client.evaluate(() => window.moonsec.stats);
    r.hostStages = hs2.stats.stages;
    r.clientStages = cs2.overlay.stages;
    r.clientFinal = { drawn: cs2.video.drawn, failed: cs2.video.failed, freezes: cs2.stats.freezes, lost: cs2.stats.frames_lost, recoveryRequests: cs2.stats.recovery_requests, audioFec: cs2.stats.audio_fec, audioRs: cs2.stats.audio_rs_recovered, audioConcealed: cs2.stats.audio_concealed };
    r.hostFinal = { ltr: hs2.ltr, ltrMarks: hs2.encoder.ltrMarks, ltrRefreshes: hs2.encoder.ltrRefreshes, refreshes: hs2.stats.refreshes, frameAcks: hs2.stats.frame_acks, frames: hs2.stats.frames, keyframes: hs2.stats.keyframes, bytes: hs2.stats.bytes, nacks: hs2.stats.nacks, retransmits: hs2.stats.retransmits, recovery: hs2.stats.recovery_requests, busyDrops: hs2.encoder.busyDrops, timeouts: hs2.encoder.timeouts, encodeMs: summary(hs2.encoder.encodeMs) };

    // --- leave ---
    await client.evaluate(() => window.moonsec.client.close());
    await waitFor("host back to waiting", () => host.evaluate(() => window.moonsecHost.report.state === "waiting" && window.moonsecHost.report.sessions === 1), 10000).catch(() => r.failures.push("host did not return to waiting after the client left"));
  } catch (e) {
    r.failures.push(String(e?.stack ?? e));
  }
  r.logs = logs.slice(0, 30);
  await hostCtx.close();
  await clientCtx.close();
  return round(r);
}

const results = { browser: "", relayUrl, variants: [] };
for (const v of variants) {
  process.stderr.write(`variant ${v}...\n`);
  const browser = await chromium.launch({ headless: !args.headed, args: launchArgs(v) });
  results.browser = `chromium ${browser.version()}`;
  const r = await runVariant(browser, v);
  await browser.close();
  results.variants.push(r);
  const l = r.inputToPhotonMs ?? {};
  const f = (s) => (s && s.n ? `p50 ${s.p50} / p90 ${s.p90} / max ${s.max} ms (n ${s.n})` : "-");
  if (r.hostFinal) process.stderr.write(`  host ${JSON.stringify(r.hostFinal)}\n  client ${JSON.stringify(r.clientFinal)}\n`);
  process.stderr.write(`  codec ${r.codec}; connect->first frame ${r.connectToFirstFrameMs} ms\n  key ${f(l.key)}\n  mouse ${f(l.mouse)}\n  pad ${f(l.pad)}\n`);
  for (const x of r.failures) process.stderr.write(`  FAIL ${x}\n`);
  for (const x of r.logs) process.stderr.write(`  log ${x}\n`);
}
server.close();
if (args.json) writeFileSync(args.json, JSON.stringify(results, null, 2));
else console.log(JSON.stringify(results, null, 2));
const failed = results.variants.some((v) => v.failures.length > 0);
process.exit(failed ? 1 : 0);
