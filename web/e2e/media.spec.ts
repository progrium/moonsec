// The web client's media pipeline (src/media) against a real moonsec host replaying the
// H.264 fixture (e2e/media-host.mjs): the Zig core in wasm reassembles, NACKs, acks and
// syncs clocks; WebCodecs decodes in a Worker onto an OffscreenCanvas; Opus plays
// through the AudioWorklet. Writes what it measured to test-results/web/media-<browser>.json.

import { expect, Page, test } from "@playwright/test";
import { mkdir, writeFile } from "node:fs/promises";

const mediaPort = Number(process.env.MEDIA_PORT ?? 8788);
const base = `http://127.0.0.1:${mediaPort}`;

type Stats = any;

async function run(page: Page, query: string, seconds: number): Promise<Stats> {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${base}/client.html?autostart&seconds=${seconds}&${query}`);
  await expect
    .poll(async () => page.evaluate(() => window.moonsec.stats?.state ?? (window.moonsec.errors.length ? "error" : "none")), {
      timeout: (seconds + 15) * 1000,
      intervals: [500],
    })
    .toMatch(/ended|error/);
  const m = await page.evaluate(() => ({ stats: window.moonsec.stats, errors: window.moonsec.errors, overlay: document.getElementById("overlay")!.textContent }));
  expect(m.errors.concat(errors)).toEqual([]);
  return m;
}

function percentile(xs: number[], p: number) {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}

async function save(name: string, key: string, m: any, hostReport: unknown) {
  const dir = "test-results/web";
  await mkdir(dir, { recursive: true });
  const st = m.stats;
  const out = {
    userAgent: await test.info().project.name,
    codec: st.video.codec,
    hardware: st.video.hardware,
    stages: st.overlay.stages,
    video: { ...st.video, decodeMs: undefined, drawMs: undefined },
    audio: st.audio,
    session: st.stats,
    overlay: m.overlay,
    host: hostReport,
  };
  await writeFile(`${dir}/media-${name}-${key}.json`, JSON.stringify(out, null, 2));
}

async function hostReport(page: Page) {
  // The host prints its report when the session ends (on our bye).
  await expect.poll(async () => (await (await page.request.get(`${base}/reports`)).json()).length, { timeout: 10_000 }).toBeGreaterThan(0);
  const all = await (await page.request.get(`${base}/reports`)).json();
  return all[all.length - 1];
}

test.beforeEach(async ({ page }) => {
  await page.goto(`${base}/client.html`);
  const ok = await page.evaluate(async () => {
    if (typeof VideoDecoder === "undefined" || typeof OffscreenCanvas === "undefined") return false;
    for (const codec of ["avc1.42C01F", "avc1.42E01F"]) {
      try {
        if ((await VideoDecoder.isConfigSupported({ codec, optimizeForLatency: true })).supported) return true;
      } catch {}
    }
    return false;
  });
  test.skip(!ok, "no WebCodecs H.264 decoder in this browser build");
});

test("plays video and audio from a real host", async ({ page }, info) => {
  const seconds = 5;
  const m = await run(page, "", seconds);
  const st = m.stats;
  const host = await hostReport(page);
  await save(info.project.name, "clean", m, host);

  expect(st.end).toBe("closed");
  expect(st.video.errors).toEqual([]);
  expect(st.stats.decode_errors).toBe(0);
  // Wall clock on shared runners: most frames, as the native peers' bar (80%).
  expect(st.stats.frames_presented).toBeGreaterThan(seconds * 60 * 0.8);
  expect(st.video.nonBlank).toBe(true);
  expect(st.video.codec).toMatch(/^avc1\./);
  // Clock sync worked, so cross-clock stages have samples.
  expect(st.overlay.clockSynced).toBe(true);
  expect(st.overlay.stages.total.count).toBeGreaterThan(0);
  expect(st.overlay.relayed).toBe(true);
  expect(m.overlay).toContain("RELAY");
  // Audio: the jitter buffer decoded most 10 ms frames and the worklet played the tone.
  expect(st.stats.audio_decoded).toBeGreaterThan(seconds * 100 * 0.8);
  expect(st.audio.played).toBeGreaterThan(seconds * 48000 * 0.7);
  expect(st.audio.loud * 2).toBeGreaterThan(st.audio.played);
  // The host saw a clean session end.
  expect(host.code).toBe(0);
  expect(host.report).toContain("client_bye");

  info.annotations.push({
    type: "timings",
    description: JSON.stringify({ codec: st.video.codec, hw: st.video.hardware, decodeP50: st.overlay.stages.decode.p50, presentP50: st.overlay.stages.present.p50, totalP50: st.overlay.stages.total.p50, totalP99: st.overlay.stages.total.p99 }),
  });
});

test("recovers from loss and an outage without decoder errors", async ({ page }, info) => {
  const seconds = 6;
  // 3% random loss on everything the host sends, and 400 ms of nothing at 2.5 s.
  const m = await run(page, "loss=0.03&outage=2500:400&seed=7", seconds);
  const st = m.stats;
  const host = await hostReport(page);
  await save(info.project.name, "lossy", m, host);

  expect(st.end).toBe("closed");
  // The core held frames back after the gap until the keyframe: the decoder never saw a
  // frame it could not decode.
  expect(st.video.errors).toEqual([]);
  expect(st.stats.decode_errors).toBe(0);
  expect(st.stats.nacks).toBeGreaterThan(0);
  expect(st.stats.recovery_requests).toBeGreaterThan(0);
  expect(host.report).toMatch(/[1-9]\d* skipped for recovery|recovery requests [1-9]/);
  // ...and the picture came back after the outage.
  expect(st.stats.frames_presented).toBeGreaterThan(seconds * 60 * 0.5);
  expect(st.audio.played).toBeGreaterThan(seconds * 48000 * 0.6);
});

test("input from the page reaches the host through the session", async ({ page }, info) => {
  const seconds = 4;
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${base}/client.html?autostart&seconds=${seconds}`);
  await expect.poll(() => page.evaluate(() => window.moonsec.stats?.state ?? "none"), { timeout: 15_000 }).toBe("streaming");

  const box = (await page.locator("#video").boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  for (const k of ["KeyA", "KeyB", "KeyC", "Enter"]) await page.keyboard.press(k);
  await page.mouse.wheel(0, 100);

  await expect.poll(() => page.evaluate(() => window.moonsec.stats?.state ?? "none"), { timeout: (seconds + 15) * 1000 }).toBe("ended");
  const st = await page.evaluate(() => window.moonsec.stats!);
  const host = await hostReport(page);
  await save(info.project.name, "input", { stats: st, overlay: "" }, host);
  expect(errors).toEqual([]);
  // 4 keys down and up, a click (down, up), a scroll, plus the moves.
  expect(st.stats.input_events).toBeGreaterThanOrEqual(11);
  expect(st.stats.input_packets).toBeGreaterThan(0);
  // The host applied them: its report counts injected input actions.
  const applied = Number(/inputs (\d+)/.exec(host.report)?.[1] ?? 0);
  expect(applied).toBeGreaterThanOrEqual(11);
});
