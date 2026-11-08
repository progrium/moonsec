// Real Safari through safaridriver (W3C WebDriver), the same checks as harness.spec.ts
// minus what WebDriver can't drive. Playwright's WebKit is not Safari (different media
// stack, no VideoToolbox), so the macOS CI job runs this as well.
//
// Needs `sudo safaridriver --enable` once (and "Allow Remote Automation" in Safari's
// Develop menu on a desktop Mac). Writes test-results/web/safari.json; exits 1 if a
// required check fails.
//
// Usage: node e2e/safari.mjs [--port 8788] [--driver-port 4444]

import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, def) => (args.includes(name) ? Number(args[args.indexOf(name) + 1]) : def);
const port = opt("--port", 8788);
const driverPort = opt("--driver-port", 4444);
const base = `http://127.0.0.1:${port}`;
const wd = `http://127.0.0.1:${driverPort}`;
const ELEMENT = "element-6066-11e4-a52e-4f735466cecf";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(url, ms = 20_000) {
  const end = Date.now() + ms;
  for (;;) {
    try {
      const r = await fetch(url);
      if (r.status < 500) return;
    } catch {
      // not up yet
    }
    if (Date.now() > end) throw new Error(`timed out waiting for ${url}`);
    await sleep(200);
  }
}

async function call(method, p, body) {
  const r = await fetch(wd + p, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`${method} ${p}: ${JSON.stringify(j.value ?? j)}`);
  return j.value;
}

const children = [];
const stub = spawn(process.execPath, [path.join(here, "stub-host.mjs"), "--port", String(port)], { stdio: "inherit" });
children.push(stub);
const driver = spawn("safaridriver", ["-p", String(driverPort)], { stdio: "inherit" });
children.push(driver);
const cleanup = () => children.forEach((c) => c.kill());
process.on("exit", cleanup);

const results = { checks: {} };
const check = (name, ok, detail) => {
  results.checks[name] = { ok, ...(detail === undefined ? {} : { detail }) };
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail === undefined ? "" : " " + JSON.stringify(detail)}`);
};

let session;
try {
  await waitFor(`${base}/harness.html`);
  await waitFor(`${wd}/status`);
  session = (await call("POST", "/session", { capabilities: { alwaysMatch: { browserName: "safari" } } })).sessionId;
  const s = `/session/${session}`;
  const exec = (script, a = []) => call("POST", `${s}/execute/sync`, { script, args: a });
  const execAsync = (body, a = []) =>
    call("POST", `${s}/execute/async`, {
      script: `const done = arguments[arguments.length - 1]; (async () => { ${body} })().then(done, (e) => done({ error: String(e) }));`,
      args: a,
    });
  const state = async () => (await fetch(`${base}/state`)).json();

  await call("POST", `${s}/url`, { url: `${base}/harness.html?fakepad=1` });
  for (let i = 0; i < 100 && !(await exec("return window.harness && window.harness.ready === true")); i++) await sleep(100);
  results.userAgent = await exec("return navigator.userAgent");
  results.caps = await exec("return window.harness.caps()");
  console.log(results.userAgent, results.caps);

  // Input: a click and keys through WebDriver actions (trusted events in Safari).
  const el = (await call("POST", `${s}/element`, { using: "css selector", value: "#stream" }))[ELEMENT];
  await call("POST", `${s}/actions`, {
    actions: [
      {
        type: "pointer",
        id: "mouse",
        parameters: { pointerType: "mouse" },
        actions: [
          { type: "pointerMove", origin: { [ELEMENT]: el }, x: 0, y: 0, duration: 0 },
          { type: "pointerDown", button: 0 },
          { type: "pointerUp", button: 0 },
        ],
      },
    ],
  });
  await call("POST", `${s}/actions`, {
    actions: [
      {
        type: "key",
        id: "kb",
        actions: ["a", "b", "c"].flatMap((k) => [
          { type: "keyDown", value: k },
          { type: "keyUp", value: k },
        ]),
      },
    ],
  });
  await call("DELETE", `${s}/actions`);
  for (let i = 0; i < 50 && (await exec("return window.harness.stats().unacked")) !== 0; i++) await sleep(100);
  let host = await state();
  results.input = { stats: await exec("return window.harness.stats()"), host: { keyLog: host.keyLog, buttonLog: host.buttonLog, abs: host.abs, receiver: host.receiver } };
  const presses = host.keyLog.filter(([, d]) => d).map(([k]) => k);
  check("keys reach the host", JSON.stringify(presses) === JSON.stringify([0x04, 0x05, 0x06]) && host.keysDown.length === 0, presses);
  check("click reaches the host", host.buttonLog.some(([b, d]) => b === 1 && d) && host.buttonsDown.length === 0, host.buttonLog);

  // Gamepad (scripted pad; the real Gamepad API path is a hardware check).
  const buttons = Array(17).fill(false);
  buttons[0] = true;
  await exec("window.harness.setPad(0, { buttons: arguments[0], values: [], axes: [1, 0, 0, 0] })", [buttons]);
  for (let i = 0; i < 50 && !(await state()).pads[0]; i++) await sleep(100);
  host = await state();
  check("gamepad reaches the host", host.pads[0]?.buttons === 0x1000 && host.pads[0]?.lx === 32767, host.pads[0]);

  // Video and audio.
  results.video = await execAsync("return await window.harness.videoProbe();");
  const v = results.video;
  check("video decodes (WebCodecs)", !!v.report && v.report.decoded === 60 && v.report.nonBlank && v.report.errors.length === 0, {
    supported: v.supported,
    where: v.report?.where,
    codec: v.report?.codec,
    summary: v.summary,
    errors: v.report?.errors,
  });
  results.audio = await execAsync("return await window.harness.audioProbe(1000);");
  // Safari may keep an AudioContext suspended without a user gesture: recorded, not required.
  console.log("audio", JSON.stringify(results.audio));
} catch (e) {
  check("session", false, String(e));
} finally {
  if (session) await call("DELETE", `/session/${session}`).catch(() => {});
  await mkdir("test-results/web", { recursive: true });
  await writeFile("test-results/web/safari.json", JSON.stringify(results, null, 2));
  cleanup();
}
process.exit(Object.values(results.checks).every((c) => c.ok) ? 0 : 1);
