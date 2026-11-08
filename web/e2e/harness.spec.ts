// Phase 6 gate harness (stub stage): the web client's input path, WebCodecs decode and
// AudioWorklet playback in each browser, against web/e2e/stub-host.mjs. Each test
// writes what it measured to test-results/web/<browser>.json (CI uploads it).

import { expect, Page, test } from "@playwright/test";
import { mkdir, readFile, writeFile } from "node:fs/promises";

type HostState = {
  keysDown: number[];
  keyLog: [number, boolean][];
  buttonsDown: number[];
  buttonLog: [number, boolean][];
  scroll: { x: number; y: number };
  motion: { x: number; y: number };
  abs: { x: number; y: number } | null;
  pads: ({ buttons: number; lx: number; ly: number; rx: number; ry: number; lt: number; rt: number } | null)[];
  datagrams: number;
  dropped: number;
  bad: number;
  receiver: Record<string, number>;
};

async function record(browser: string, key: string, value: unknown) {
  const dir = "test-results/web";
  await mkdir(dir, { recursive: true });
  const file = `${dir}/${browser}.json`;
  let all: Record<string, unknown> = {};
  try {
    all = JSON.parse(await readFile(file, "utf8"));
  } catch {
    // first entry
  }
  all[key] = value;
  await writeFile(file, JSON.stringify(all, null, 2));
}

async function open(page: Page, query = "") {
  await page.goto(`/harness.html${query}`);
  await page.waitForFunction(() => (window as any).harness?.ready === true);
  await record(test.info().project.name, "userAgent", await page.evaluate(() => (window as any).harness.userAgent));
}

async function hostState(page: Page): Promise<HostState> {
  const r = await page.request.get("/state");
  return r.json();
}

/** Wait until the host has applied everything the page sent (nothing unacked). */
async function settled(page: Page) {
  await expect.poll(() => page.evaluate(() => (window as any).harness.stats().unacked), { timeout: 10_000 }).toBe(0);
}

const HID = { a: 0x04, b: 0x05, c: 0x06, shiftLeft: 0xe1, enter: 0x28 };

test("keyboard, mouse and wheel input reach the host", async ({ page }, info) => {
  await open(page);
  const caps = await page.evaluate(() => (window as any).harness.caps());

  const box = (await page.locator("#stream").boundingBox())!;
  // Absolute position first: hover the centre without clicking.
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await expect.poll(async () => (await hostState(page)).abs).not.toBeNull();
  const abs = (await hostState(page)).abs!;
  expect(Math.abs(abs.x - 32768)).toBeLessThan(400);
  expect(Math.abs(abs.y - 32768)).toBeLessThan(400);

  // A click (left) locks the pointer where supported and lands on the host.
  await page.mouse.click(box.x + box.width / 4, box.y + box.height / 4);
  await page.mouse.click(box.x + box.width / 4, box.y + box.height / 4, { button: "right" });

  await page.keyboard.down("Shift");
  await page.keyboard.press("KeyA");
  await page.keyboard.up("Shift");
  await page.keyboard.press("KeyB");
  await page.keyboard.press("Enter");

  await page.mouse.wheel(0, 100);
  await page.mouse.wheel(0, 100);

  const stats0 = await page.evaluate(() => (window as any).harness.stats());
  // Relative motion while locked, absolute otherwise.
  await page.mouse.move(box.x + box.width / 4 + 30, box.y + box.height / 4 + 20, { steps: 5 });
  if (stats0.pointerLocked) {
    // Headless browsers emulate the lock and may report zero movement for driven mouse
    // events, so also feed deltas the way a locked pointer delivers them.
    await page.evaluate(() => {
      for (let i = 0; i < 5; i++) {
        document.getElementById("stream")!.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, movementX: 6, movementY: -4 }));
      }
    });
  }
  await settled(page);

  const s = await hostState(page);
  const stats = await page.evaluate(() => (window as any).harness.stats());
  await record(info.project.name, "input", { caps: { ...caps, ...(await page.evaluate(() => (window as any).harness.caps())) }, stats, host: { datagrams: s.datagrams, receiver: s.receiver } });

  const downs = s.keyLog.filter(([, d]) => d).map(([k]) => k);
  expect(downs).toEqual([HID.shiftLeft, HID.a, HID.b, HID.enter]);
  expect(s.keysDown).toEqual([]);
  expect(s.buttonLog.map(([b, d]) => `${b}${d ? "+" : "-"}`)).toEqual(["1+", "1-", "2+", "2-"]);
  expect(s.buttonsDown).toEqual([]);
  expect(s.scroll.y).toBeGreaterThan(0);
  if (stats0.pointerLocked) {
    // The host applies exactly the relative motion the page saw.
    expect(stats.relX !== 0 || stats.relY !== 0).toBe(true);
    expect(s.motion).toEqual({ x: stats.relX, y: stats.relY });
  } else {
    expect(s.abs!.x).toBeGreaterThan(65535 / 4);
  }
  expect(s.bad).toBe(0);
});

test("fullscreen and Keyboard Lock (Chromium only)", async ({ page }, info) => {
  await open(page, "?mouse=absolute");
  await page.locator("#stream").dblclick();
  await expect.poll(() => page.evaluate(() => (window as any).harness.fullscreen())).not.toBeNull();
  const r = await page.evaluate(() => (window as any).harness.fullscreen());
  await record(info.project.name, "fullscreen", r);
  if (info.project.name === "chromium") expect(r).toEqual({ fullscreen: true, keyboardLocked: true });
});

test("input survives 30% datagram loss with no stuck keys", async ({ page }, info) => {
  await open(page, "?loss=0.3&seed=7&mouse=absolute");
  const keys = ["KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ"];
  for (let round = 0; round < 3; round++) for (const k of keys) await page.keyboard.press(k);
  await page.keyboard.down("KeyZ");
  await page.keyboard.up("KeyZ");
  await settled(page);
  const s = await hostState(page);
  await record(info.project.name, "inputLoss", { datagrams: s.datagrams, dropped: s.dropped, receiver: s.receiver });
  expect(s.dropped).toBeGreaterThan(0);
  const presses = s.keyLog.filter(([, d]) => d).map(([k]) => k);
  const expected = [...Array(3)].flatMap(() => keys.map((k) => 0x04 + k.charCodeAt(3) - 65)).concat([0x1d]);
  expect(presses).toEqual(expected);
  expect(s.keysDown).toEqual([]);
  expect(s.receiver.lostEvents).toBe(0);
});

test("gamepad snapshots reach the host", async ({ page }, info) => {
  await open(page, "?fakepad=1");
  const buttons = Array(17).fill(false);
  buttons[0] = true; // A
  buttons[12] = true; // dpad up
  await page.evaluate(
    (b) => (window as any).harness.setPad(0, { buttons: b, values: [], axes: [1, -1, -0.5, 0] }),
    buttons,
  );
  await expect.poll(async () => (await hostState(page)).pads[0]).not.toBeNull();
  let pad = (await hostState(page)).pads[0]!;
  expect(pad.buttons).toBe(0x1000 | 0x0001);
  expect(pad.lx).toBe(32767);
  expect(pad.ly).toBe(32767); // DOM down is negative up: -1 (up) -> +32767
  expect(pad.rx).toBe(-16384);

  // Analog trigger, then disconnect.
  const b2 = Array(17).fill(false);
  b2[7] = true;
  const values = Array(17).fill(0);
  values[7] = 0.5;
  await page.evaluate(([b, v]) => (window as any).harness.setPad(0, { buttons: b, values: v, axes: [0, 0, 0, 0] }), [b2, values]);
  await expect.poll(async () => (await hostState(page)).pads[0]?.rt).toBe(32768);
  pad = (await hostState(page)).pads[0]!;
  expect(pad.buttons).toBe(0);
  await page.evaluate(() => (window as any).harness.setPad(0, null));
  await expect.poll(async () => (await hostState(page)).pads[0]).toBeNull();
  await record(info.project.name, "gamepad", { ok: true, gamepadApi: (await page.evaluate(() => (window as any).harness.caps())).gamepad });
});

test("video frames arrive and decode (WebCodecs)", async ({ page }, info) => {
  await open(page);
  const r = await page.evaluate(() => (window as any).harness.videoProbe());
  await record(info.project.name, "video", r);
  console.log(`${info.project.name} video:`, JSON.stringify({ supported: r.supported, where: r.report?.where, codec: r.report?.codec, workerFallback: r.workerFallback, summary: r.summary, errors: r.report?.errors }));
  expect(r.report, `no WebCodecs decoder for H.264 or VP8 (supported: ${JSON.stringify(r.supported)})`).not.toBeNull();
  expect(r.report.errors).toEqual([]);
  expect(r.report.decoded).toBe(60);
  expect(r.report.drawn).toBe(60);
  expect(r.report.nonBlank).toBe(true);
});

test("audio plays through an AudioWorklet", async ({ page }, info) => {
  await open(page);
  const r = await page.evaluate(() => (window as any).harness.audioProbe(1000));
  await record(info.project.name, "audio", r);
  console.log(`${info.project.name} audio:`, JSON.stringify(r));
  expect(r.ok, r.error).toBe(true);
  expect(r.played).toBeGreaterThan(48000 * 0.5);
  expect(r.rms).toBeGreaterThan(0.2);
  expect(Math.abs(r.hz - 440)).toBeLessThan(40);
});
