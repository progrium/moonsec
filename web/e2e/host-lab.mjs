// Shared by the browser host's end-to-end runs (browser-host.mjs, browser-host-multi.mjs):
// a local iroh-relay (relay/lab.toml), a static server for web/ (plus zig-out/web's wasm and
// shim-web/pkg), and helpers.
//
// Needs: zig-out/web (zig build web-wasm), shim-web/pkg (shim-web/build.sh), web/dist
// (npm run build), iroh-relay 1.4.1 on PATH (or IROH_RELAY), openssl, Playwright browsers.
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
export const web = resolve(here, "..");
export const root = resolve(web, "..");
export const relayUrl = "https://127.0.0.1:3443";
export const playwright = createRequire(join(web, "package.json"))("playwright");

export const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith("--") ? [...a, [v.slice(2), all[i + 1]?.startsWith("--") ? "1" : (all[i + 1] ?? "1")]] : a), []));

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

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export async function waitFor(what, fn, ms = 20000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await sleep(50);
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Starts the relay and the static server; resolves to { base, server }. */
export async function startLab() {
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
  return { base: `http://127.0.0.1:${server.address().port}`, server };
}

/** Launch options per browser: autoplay without a gesture, and the given extra Chromium flags. */
export function launch(name, { headed = false, chromiumArgs = [] } = {}) {
  const bt = playwright[name];
  if (name === "chromium") return bt.launch({ headless: !headed, args: ["--autoplay-policy=no-user-gesture-required", ...chromiumArgs] });
  if (name === "firefox") return bt.launch({ headless: !headed, firefoxUserPrefs: { "media.autoplay.default": 0, "media.autoplay.block-webaudio": false } });
  return bt.launch({ headless: !headed });
}

export const pct = (xs, p) => {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
export const summary = (xs) => ({ n: xs.length, min: pct(xs, 0), p50: pct(xs, 50), p90: pct(xs, 90), max: pct(xs, 100) });
export const round = (o) => JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === "number" ? Math.round(v * 100) / 100 : v)));

/** Init script for a client page: a scriptable gamepad (window.__pad) and DOM event times. */
export function fakePad() {
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

/** Collects error console lines and page errors (all lines with VERBOSE). */
export function collectLogs(pages) {
  const logs = [];
  for (const [who, p] of pages) {
    p.on("console", (m) => {
      if (m.type() === "error" || process.env.VERBOSE) logs.push(`[${who}] ${m.text()}`);
    });
    p.on("pageerror", (e) => logs.push(`[${who}] pageerror ${e.message}`));
  }
  return logs;
}
