#!/usr/bin/env node
// shim-web end to end: headless browsers (Playwright) <-> local iroh-relay <-> native moonsec.
//
//   node shim-web/test/run.mjs [--browsers chromium,firefox,webkit] [--json out.json] [--rates 2000,10000,25000,50000]
//
// Needs, from the repo root: shim-web/pkg (shim-web/build.sh), zig-out/web/moonsec-pair.wasm
// (`zig build web-pair`), zig-out/bin/{shim-echo,moonsec} (`zig build install install-moonsec`),
// iroh-relay 1.4.1 on PATH (or IROH_RELAY=path), openssl, and Playwright with its browsers.
//
// What it runs, per browser:
//   echo     datagram echo (RTT) and a stream echo with `shim-echo serve`
//   rate     datagram throughput both ways at each offered rate
//   pair-qr  `moonsec pair host --qr-only`: the browser pairs with the QR ticket's secret
//   pair-pin `moonsec pair host --pin-only`: a wrong PIN is refused, the right one pairs
//   admit    `moonsec peer iroh host --state-dir`: an unpaired key is refused, the paired one admitted
// The relay is relay/lab.toml with a lab CA; browsers ignore its certificate errors (the CA is
// not in their trust store), native endpoints trust it through --relay-ca.
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, existsSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith("--") ? [...a, [v.slice(2), all[i + 1]]] : a), []));
const browsers = (args.browsers ?? "chromium").split(",").filter(Boolean);
const rates = (args.rates ?? "2000,10000,25000,50000").split(",").map(Number);
const relayUrl = "https://127.0.0.1:3443";
const bin = (n) => join(root, "zig-out/bin", n);

function playwright() {
  try {
    return createRequire(import.meta.url)("playwright");
  } catch {
    return createRequire(join(execFileSync("npm", ["root", "-g"]).toString().trim(), "x.js"))("playwright");
  }
}

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
  p.exited = new Promise((r) => p.on("exit", (code) => r(code)));
  procs.push(p);
  return p;
}
function cleanup() {
  for (const p of procs) if (p.exitCode === null) p.kill("SIGKILL");
}
process.on("exit", cleanup);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(what, fn, ms = 20000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await sleep(100);
  }
  throw new Error(`timed out waiting for ${what}`);
}
const readIf = (f) => (existsSync(f) && statSync(f).size > 0 ? readFileSync(f, "utf8").trim() : null);

// --- relay ------------------------------------------------------------------------------
const lab = mkdtempSync(join(tmpdir(), "shim-web-"));
execFileSync(join(root, "relay/lab-cert.sh"), [lab], { stdio: "ignore" });
const ca = join(lab, "ca.crt");
start("relay", process.env.IROH_RELAY ?? "iroh-relay", ["--config-path", join(root, "relay/lab.toml")], { cwd: lab });
await waitFor("relay", () => {
  try {
    execFileSync("curl", ["-sf", "--cacert", ca, `${relayUrl}/ping`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
});

// --- static server for the page, the bindings and the pairing module ---------------------
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".json": "application/json" };
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = path === "/pkg/moonsec-pair.wasm" ? join(root, "zig-out/web/moonsec-pair.wasm") : join(root, "shim-web", path);
  if (!file.startsWith(join(root, "shim-web")) && !file.endsWith("moonsec-pair.wasm")) return res.writeHead(403).end();
  try {
    const body = readFileSync(file);
    res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pageUrl = `http://127.0.0.1:${server.address().port}/test/index.html`;

// --- native echo peer ----------------------------------------------------------------------
const echoTicketFile = join(lab, "echo.ticket");
start("echo", bin("shim-echo"), ["serve", echoTicketFile, "--relay-url", relayUrl, "--relay-ca", ca]);
const echoTicket = await waitFor("shim-echo ticket", () => readIf(echoTicketFile));

const relayNative = ["--relay-url", relayUrl, "--relay-ca", ca];
const results = { relayUrl, browsers: {} };
const failures = [];
const check = (b, cond, what) => {
  if (!cond) failures.push(`${b}: ${what}`);
};

const pw = playwright();
for (const b of browsers) {
  const r = (results.browsers[b] = {});
  let browser;
  try {
    browser = await pw[b].launch();
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    const consoleLines = [];
    page.on("console", (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
    page.on("pageerror", (e) => consoleLines.push(`pageerror: ${e.message}`));
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.shimWeb, null, { timeout: 30000 }).catch((e) => {
      throw new Error(`page did not load: ${e.message}\n${consoleLines.join("\n")}`);
    });
    r.version = browser.version();
    const run = (name, o) => page.evaluate(([n, opts]) => window.shimWeb.tests[n](opts), [name, o]);

    // echo
    r.echo = await run("echo", { relayUrl, ticket: echoTicket, count: 200 });
    check(b, r.echo.datagrams.ok === r.echo.datagrams.count && r.echo.datagrams.mismatches === 0, `datagram echo ${r.echo.datagrams.ok}/${r.echo.datagrams.count}, ${r.echo.datagrams.mismatches} mismatched`);
    check(b, r.echo.stream.intact, "stream echo not intact");
    check(b, r.echo.transport.got === r.echo.transport.sent, `IrohTransport echo ${r.echo.transport.got}/${r.echo.transport.sent}`);
    check(b, r.echo.paths.every((p) => p.isRelay), "a non-relay path in the browser");

    // rate
    r.rate = await run("rate", { relayUrl, ticket: echoTicket, ratesKbps: rates, ms: 2000 });

    // pairing with the QR ticket's secret
    const state = join(lab, `state-${b}`);
    const qrFile = join(lab, `${b}.qr`);
    const host = start(`pair-qr-${b}`, bin("moonsec"), ["pair", "host", "--state-dir", state, "--name", "lab host", "--qr-only", "--seconds", "60", "--ticket-file", qrFile, ...relayNative]);
    const qr = await waitFor("pairing ticket", () => readIf(qrFile));
    r.pairQr = await run("pairWithHost", { relayUrl, ticket: qr, name: `${b} (headless)` });
    const qrExit = await host.exited;
    check(b, !r.pairQr.error && qrExit === 0 && /paired with/.test(host.log), `QR pairing: ${r.pairQr.error ?? `host exit ${qrExit}`}`);
    check(b, r.pairQr.id === r.pairQr.idFromCore, "shim-web and core/pair derive different IDs from one key");

    // PIN pairing: a wrong PIN first (refused, attempts left drop), then the right one
    const pinFile = join(lab, `${b}.pin`);
    const tFile = join(lab, `${b}.t`);
    const host2 = start(`pair-pin-${b}`, bin("moonsec"), ["pair", "host", "--state-dir", state, "--name", "lab host", "--pin-only", "--seconds", "60", "--ticket-file", tFile, "--pin-file", pinFile, ...relayNative]);
    const pin = await waitFor("PIN", () => readIf(pinFile));
    const addrTicket = await waitFor("address ticket", () => readIf(`${tFile}.addr`));
    const wrong = String((Number(pin) + 1) % 1000000).padStart(6, "0");
    r.pairPinWrong = await run("pairWithHost", { relayUrl, ticket: addrTicket, pin: wrong });
    r.pairPin = await run("pairWithHost", { relayUrl, ticket: addrTicket, pin: `${pin.slice(0, 3)} ${pin.slice(3)}` });
    const pinExit = await host2.exited;
    check(b, r.pairPinWrong.reason === 3 && r.pairPinWrong.attemptsLeft === 4, `wrong PIN: ${JSON.stringify(r.pairPinWrong)}`);
    check(b, !r.pairPin.error && pinExit === 0, `PIN pairing: ${r.pairPin.error ?? `host exit ${pinExit}`}`);

    // admission
    r.paired = execFileSync(bin("moonsec"), ["paired", "--state-dir", state]).toString();
    check(b, r.paired.includes(r.pairQr.id) && r.paired.includes(r.pairPin.id), "browser keys missing from the host's allowlist");
    const sessFile = join(lab, `${b}.session`);
    const peer = start(`peer-${b}`, bin("moonsec"), ["peer", "iroh", "host", "--state-dir", state, "--ticket-file", sessFile, "--seconds", "3", ...relayNative]);
    const sessTicket = await waitFor("session ticket", () => readIf(sessFile));
    r.admitUnpaired = await run("admit", { relayUrl, ticket: sessTicket });
    r.admitPaired = await run("admit", { relayUrl, ticket: sessTicket, secretKey: r.pairQr.secretKey });
    peer.kill("SIGKILL");
    check(b, r.admitUnpaired.admitted === false && r.admitUnpaired.reason === 9, `unpaired key: ${JSON.stringify(r.admitUnpaired)}`);
    check(b, r.admitPaired.admitted === true, `paired key not admitted: ${JSON.stringify(r.admitPaired)}`);
    r.console = consoleLines.slice(-20);
  } catch (e) {
    r.error = String(e.stack ?? e);
    failures.push(`${b}: ${e.message}`);
  } finally {
    await browser?.close();
  }
}

server.close();
cleanup();

// --- report -------------------------------------------------------------------------------
const f1 = (x) => (x === undefined || x === null ? "-" : Number(x).toFixed(1));
const lines = ["## shim-web through a local iroh-relay", ""];
for (const [b, r] of Object.entries(results.browsers)) {
  lines.push(`### ${b} ${r.version ?? ""}`, "");
  if (r.error) lines.push("```", r.error, "```", "");
  if (r.echo) {
    const d = r.echo.datagrams;
    lines.push(
      `- online ${f1(r.echo.onlineMs)} ms, connect ${f1(r.echo.connectMs)} ms, max datagram ${r.echo.maxDatagramSize} B`,
      `- datagram echo: ${d.ok}/${d.count} x ${d.size} B, RTT min ${f1(d.rttMs.min)} / p50 ${f1(d.rttMs.p50)} / p90 ${f1(d.rttMs.p90)} / p99 ${f1(d.rttMs.p99)} / max ${f1(d.rttMs.max)} ms`,
      `- IrohTransport burst: ${r.echo.transport.got}/${r.echo.transport.sent} echoed`,
      `- stream echo: ${r.echo.stream.echoed} / ${r.echo.stream.bytes} B ${r.echo.stream.intact ? "intact" : "CORRUPT"} in ${f1(r.echo.stream.ms)} ms`,
      `- paths: ${r.echo.paths.map((p) => `${p.pathId} ${p.remoteAddr} relay=${p.isRelay} rtt=${(p.rttUs / 1000).toFixed(1)} ms`).join("; ")}`,
    );
  }
  if (r.rate) {
    lines.push("", `| offered | down got/sent | down loss | down kbit/s | up got/sent | up loss | up kbit/s |`, "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    for (const x of r.rate.rows) lines.push(`| ${x.offeredKbps} | ${x.down.got}/${x.down.sent} | ${f1(x.down.lossPct)}% | ${x.down.kbps} | ${x.up.got}/${x.up.sent} | ${f1(x.up.lossPct)}% | ${x.up.kbps} |`);
    lines.push("", `(${r.rate.size} B datagrams, ${r.rate.ms} ms per rate and direction)`);
  }
  if (r.pairQr) lines.push(`- pairing (QR): ${r.pairQr.error ?? `paired with "${r.pairQr.host?.hostName}" in ${f1(r.pairQr.ms)} ms`}`);
  if (r.pairPinWrong) lines.push(`- pairing (wrong PIN): ${r.pairPinWrong.error ?? "paired?!"} (${r.pairPinWrong.attemptsLeft} attempts left)`);
  if (r.pairPin) lines.push(`- pairing (PIN): ${r.pairPin.error ?? `paired in ${f1(r.pairPin.ms)} ms`}`);
  if (r.admitUnpaired) lines.push(`- admission, unpaired key: ${r.admitUnpaired.admitted ? "ADMITTED" : r.admitUnpaired.error}`);
  if (r.admitPaired) lines.push(`- admission, paired key: ${r.admitPaired.admitted ? `admitted; ${r.admitPaired.datagramsAfterAdmit} datagrams in the next second` : r.admitPaired.error}`);
  lines.push("");
}
lines.push(failures.length ? `**FAIL** (${failures.length})\n\n${failures.map((f) => `- ${f}`).join("\n")}` : "**PASS**");
const md = lines.join("\n");
console.log(md);
if (args.json) writeFileSync(args.json, JSON.stringify(results, null, 2));
if (args.md) writeFileSync(args.md, md + "\n");
if (process.env.GITHUB_STEP_SUMMARY) writeFileSync(process.env.GITHUB_STEP_SUMMARY, md + "\n", { flag: "a" });
process.exit(failures.length ? 1 : 0);
