#!/usr/bin/env node
// The browser host with pairing and more than one viewer, end to end through a local
// iroh-relay: a host tab (host.html) and client tabs (client.html) in separate browser
// contexts, so each client is its own device with its own key.
//
//   node web/e2e/browser-host-multi.mjs [--host chromium] [--client chromium|firefox|webkit]
//                                       [--json out.json] [--headed]
//
// Steps and checks:
//  1. Two clients pair through the invite link (the window's one-time secret, 2 pairings)
//     and both stream: frames drawn, audio heard.
//  2. Both play at once ("everyone" policy): A's keys move the player right, B's down; each
//     client's gamepad is its own pad in the game's getGamepads().
//  3. A leaves: B keeps streaming, A's pad goes away. A comes back with the plain address
//     link: admitted as a paired device, no pairing.
//  4. A stranger with the address link and a guessed PIN while no window is open is refused
//     and never streams.
//  5. The host opens a PIN-only window; the stranger pairs with the right PIN and streams.
//  6. The host forgets A: A's session ends at once, and A is refused when it comes back.
import { writeFileSync } from "node:fs";
import { args, collectLogs, fakePad, launch, round, sleep, startLab, waitFor } from "./host-lab.mjs";

const hostBrowser = args.host ?? "chromium";
const clientBrowser = args.client ?? "chromium";
const { base, server } = await startLab();
const r = { host: hostBrowser, client: clientBrowser, steps: {}, failures: [] };
const check = (cond, what) => {
  if (!cond) r.failures.push(what);
};
const hb = await launch(hostBrowser, { headed: !!args.headed });
// Each client its own browser process, like separate devices. (Two WebKit pages of one
// process on Linux get audio for neither.)
const clientBrowsers = [];
r.versions = { host: hb.version() };

const hostCtx = await hb.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1000, height: 900 } });
const host = await hostCtx.newPage();
const pages = [["host", host]];
const logs = collectLogs(pages);
const hostReport = () => host.evaluate(() => window.moonsecHost.report);

async function newClient(name) {
  const cb = await launch(clientBrowser, { headed: !!args.headed });
  clientBrowsers.push(cb);
  r.versions.client = cb.version();
  const ctx = await cb.newContext({ ignoreHTTPSErrors: true, viewport: { width: 800, height: 500 } });
  const page = await ctx.newPage();
  await page.addInitScript(fakePad);
  page.on("console", (m) => {
    if (m.type() === "error" || process.env.VERBOSE) logs.push(`[${name}] ${m.text()}`);
  });
  page.on("pageerror", (e) => logs.push(`[${name}] pageerror ${e.message}`));
  return { ctx, page, name };
}
const stats = (c) => c.page.evaluate(() => window.moonsec?.stats ?? null);
const streaming = (c, minDrawn = 1) => waitFor(`${c.name} streaming`, async () => {
  const s = await stats(c);
  return s?.state === "streaming" && s.video.drawn >= minDrawn;
}, 30000);
const open = async (c, url) => {
  await c.page.goto(`${url}&autostart&mouse=absolute&name=${c.name}`);
};
const game = () => host.evaluate(() => ({ x: window.game.x, y: window.game.y, pads: window.game.pads }));
async function hold(c, key, ms) {
  const box = await (await c.page.$("#video")).boundingBox();
  await c.page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await c.page.keyboard.down(key);
  await sleep(ms);
  await c.page.keyboard.up(key);
}

try {
  await host.goto(`${base}/host.html?autostart&invite=2&relay=${encodeURIComponent("https://127.0.0.1:3443")}`);
  const invite = await waitFor("host invite", () => host.evaluate(() => window.moonsecHost.inviteUrl), 30000);
  const address = await host.evaluate(() => window.moonsecHost.clientUrl);
  const inv0 = (await hostReport()).invite;
  check(inv0?.qr?.size >= 21 && inv0.pin?.length === 6, `invite has no QR code or PIN: ${JSON.stringify({ qr: inv0?.qr?.size, pin: inv0?.pin })}`);

  // 1. two devices pair with the invite and stream
  const A = await newClient("alice");
  const B = await newClient("bob");
  await open(A, invite);
  await open(B, invite);
  await streaming(A, 30);
  await streaming(B, 30);
  await sleep(2000);
  let hs = await hostReport();
  const [sa, sb] = [await stats(A), await stats(B)];
  r.steps.pair = { pairing: hs.pairing, members: hs.members.map((m) => [m.name, m.state]), drawn: [sa.video.drawn, sb.video.drawn], loud: [sa.audio.loud, sb.audio.loud], audio: [sa.audio, sb.audio], audioStats: [sa.stats.audio_decoded, sb.stats.audio_decoded], keyframes: hs.multi.keyframes };
  check(hs.pairing.paired === 2 && hs.members.length === 2, `two members: ${JSON.stringify(r.steps.pair)}`);
  check(sa.video.drawn > 60 && sb.video.drawn > 60 && sa.video.nonBlank && sb.video.nonBlank, `both draw: ${sa.video.drawn}, ${sb.video.drawn}`);
  check(sa.audio.loud > 0 && sb.audio.loud > 0, `both hear audio: ${sa.audio.loud}, ${sb.audio.loud}`);
  check(hs.invite === null, "the window should close after its 2 pairings");

  // 2. both play at once
  const g0 = await game();
  await hold(A, "ArrowRight", 400);
  await hold(B, "ArrowDown", 400);
  await A.page.evaluate(() => window.__pad.set(1, true));
  await B.page.evaluate(() => window.__pad.set(1, true));
  await sleep(500);
  const g1 = await game();
  r.steps.input = { before: g0, after: g1 };
  check(g1.x > g0.x + 20, `alice's ArrowRight did not move the player (${g0.x} -> ${g1.x})`);
  check(g1.y > g0.y + 20, `bob's ArrowDown did not move the player (${g0.y} -> ${g1.y})`);
  check(g1.pads === 2, `the game sees ${g1.pads} pads, want 2`);

  // 3. A leaves and comes back with the address link
  await A.page.evaluate(() => window.moonsec.client.close());
  await waitFor("alice gone", async () => (await hostReport()).members.length === 1, 10000).catch(() => r.failures.push("alice still a member after leaving"));
  const bBefore = (await stats(B)).video.drawn;
  await sleep(1500);
  const bAfter = (await stats(B)).video.drawn;
  const g2 = await game();
  check(bAfter - bBefore > 45, `bob stalled after alice left (${bBefore} -> ${bAfter})`);
  check(g2.pads === 1, `the game sees ${g2.pads} pads after alice left, want 1`);
  await open(A, address);
  await streaming(A, 10);
  hs = await hostReport();
  r.steps.rejoin = { pairing: hs.pairing, members: hs.members.length, bobDrawn: [bBefore, bAfter] };
  check(hs.pairing.paired === 2 && hs.pairing.admitted === 3, `alice rejoined without pairing: ${JSON.stringify(hs.pairing)}`);

  // 4. a stranger with the address and a guess, no window open
  const C = await newClient("carol");
  await open(C, `${address}&pin=123456`);
  await sleep(4000);
  const sc = await stats(C);
  const cErrors = await C.page.evaluate(() => window.moonsec.errors);
  hs = await hostReport();
  r.steps.stranger = { state: sc?.state ?? null, errors: cErrors, pairing: hs.pairing };
  check(!sc || sc.state !== "streaming", "a stranger streams without pairing");
  check(cErrors.some((e) => /not pairing/.test(e)), `the stranger was not told the host is not pairing: ${cErrors.join("; ")}`);

  // 5. a PIN-only window; the stranger pairs with the right PIN
  await host.evaluate(() => window.moonsecHost.host.invite({ secret: false, pin: true }));
  const pin = await waitFor("PIN", async () => (await hostReport()).invite?.pin, 5000);
  await C.page.goto("about:blank");
  await open(C, `${address}&pin=${pin}`);
  await streaming(C, 10);
  hs = await hostReport();
  r.steps.pin = { pairing: hs.pairing, members: hs.members.map((m) => m.name) };
  check(hs.members.length === 3, `three members after PIN pairing: ${JSON.stringify(r.steps.pin)}`);

  // 6. the host forgets A
  const aId = hs.members.find((m) => m.name === "alice")?.endpointId;
  await host.evaluate((id) => window.moonsecHost.host.forget(id), aId);
  await waitFor("alice removed", async () => !(await hostReport()).members.some((m) => m.name === "alice"), 10000).catch(() => r.failures.push("alice still a member after being forgotten"));
  await A.page.goto("about:blank");
  await open(A, address);
  await sleep(4000);
  const sa2 = await stats(A);
  const aErrors = await A.page.evaluate(() => window.moonsec.errors);
  hs = await hostReport();
  r.steps.forget = { aliceState: sa2?.state ?? null, errors: aErrors, pairing: hs.pairing };
  check(!sa2 || sa2.state !== "streaming", "a forgotten device streams");
  check(aErrors.some((e) => /not paired/.test(e)), `alice was not told she is not paired: ${aErrors.join("; ")}`);
  check(hs.members.length === 2, `bob and carol still members: ${hs.members.map((m) => m.name)}`);
} catch (e) {
  r.failures.push(String(e?.stack ?? e));
}
r.logs = logs.slice(0, 40);
const hostErrors = await host.evaluate(() => window.moonsecHost.errors).catch(() => []);
if (hostErrors.length) r.hostErrors = hostErrors;
await hb.close();
for (const b of clientBrowsers) await b.close();
server.close();
const out = round(r);
if (args.json) writeFileSync(args.json, JSON.stringify(out, null, 2));
process.stderr.write(`host ${hostBrowser} ${r.versions.host}, clients ${clientBrowser} ${r.versions.client}\n`);
for (const [k, v] of Object.entries(out.steps)) process.stderr.write(`  ${k}: ${JSON.stringify(v)}\n`);
for (const f of out.failures) process.stderr.write(`  FAIL ${f}\n`);
for (const l of out.logs) process.stderr.write(`  log ${l}\n`);
process.exit(out.failures.length > 0 ? 1 : 0);
