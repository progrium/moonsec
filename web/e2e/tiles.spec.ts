// Lossless tiles in the web client, without a host that sends them (the hosts the media
// tests stream from replay an encoded fixture: no captured pixels to make tiles of):
//
//   - the core in wasm (zig-out/web/moonsec-client.wasm, `zig build web-wasm`) asks for
//     tiles in its hello only when told to, and `tilePresent` reads back its update;
//   - the worker's tile layer (src/media/tiles.ts), in the browser, composites ops over a
//     drawn frame pixel exact at 1:1, clears them, hides with the update and starts over
//     at a new size.
//
// The ops the core produces from a host's tiles (RGBA, rectangles, pixels) are covered by
// app/web_tiles.zig's tests (`zig build test-app`).

import { expect, test } from "@playwright/test";
import { build } from "esbuild";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { CoreSession } from "../src/core";

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wasm = path.resolve(web, "../zig-out/web/moonsec-client.wasm");

/** The hello's tile caps (control_fast kind 32: envelope 8 bytes, caps at body 24). */
async function helloTiles(tiles: boolean): Promise<{ caps: number; update: unknown }> {
  let caps = -1;
  const core = await CoreSession.create(await readFile(wasm), { codecs: 1, channels: 0, tiles }, (dg) => {
    if (dg.length === 8 + 28 && dg[2] === 32) caps = new DataView(dg.buffer, dg.byteOffset).getUint32(8 + 24, true);
  });
  core.step(performance.now() * 1000);
  const update = core.tilePresent(1);
  core.free();
  return { caps, update };
}

test("the core asks for tiles only when the page composites them", async () => {
  const on = await helloTiles(true);
  expect(on.caps).toBe(1); // refine.wire.caps_qoi
  // No stream config yet: a layer with nothing on it, hidden.
  expect(on.update).toEqual({ width: 0, height: 0, visible: false, ops: [] });
  const off = await helloTiles(false);
  expect(off.caps).toBe(0);
  expect(off.update).toBeNull();
});

test("the tile layer composites over the frame pixel exact, clears, hides and resizes", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium" && browserName !== "firefox", "OffscreenCanvas 2D checked in Chromium and Firefox");
  const bundle = await build({ entryPoints: [path.join(web, "src/media/tiles.ts")], bundle: true, format: "iife", globalName: "tiles", write: false, target: "es2022" });
  await page.setContent("<!doctype html><title>tiles</title>");
  await page.addScriptTag({ content: bundle.outputFiles[0].text });
  const r = await page.evaluate(() => {
    const { TileLayer } = (window as any).tiles;
    const W = 160;
    const H = 96;
    const frame = new OffscreenCanvas(W, H);
    const ctx = frame.getContext("2d", { alpha: false }) as OffscreenCanvasRenderingContext2D;
    // A "decoded frame": smooth gray, so any blending or smoothing of a tile shows.
    const video = () => {
      ctx.imageSmoothingEnabled = true;
      ctx.fillStyle = "rgb(128,128,128)";
      ctx.fillRect(0, 0, W, H);
    };
    // A 64x32 tile of a one-pixel checkerboard with odd colors.
    const tw = 64;
    const th = 32;
    const px = new Uint8ClampedArray(tw * th * 4);
    for (let y = 0; y < th; y++)
      for (let x = 0; x < tw; x++) {
        const i = (y * tw + x) * 4;
        const on = (x + y) & 1;
        px.set(on ? [250, 3, 77, 255] : [1, 200, 13, 255], i);
      }
    const at = { x: 64, y: 64 };
    const layer = new TileLayer();
    const present = (u: unknown) => {
      layer.apply(u);
      video();
      layer.drawOver(ctx, W, H);
    };
    const tileExact = () => {
      const got = ctx.getImageData(at.x, at.y, tw, th).data;
      for (let i = 0; i < got.length; i++) if (got[i] !== px[i]) return `differs at byte ${i}: ${got[i]} != ${px[i]}`;
      return "exact";
    };
    const gray = (x: number, y: number, w: number, h: number) => ctx.getImageData(x, y, w, h).data.every((v, i) => (i % 4 === 3 ? v === 255 : v === 128));
    const out: Record<string, unknown> = {};
    present({ width: W, height: H, visible: true, ops: [{ kind: 0, x: 0, y: 0, w: W, h: H, pixels: null }, { kind: 2, ...at, w: tw, h: th, pixels: px }] });
    out.put = tileExact();
    out.aroundPut = gray(0, 0, W, 64) && gray(0, 64, 64, 32);
    // A later frame with no ops: the tile stays.
    present({ width: W, height: H, visible: true, ops: [] });
    out.kept = tileExact();
    // Hidden (a damage gap): the frame alone, the tile still on the layer.
    present({ width: W, height: H, visible: false, ops: [] });
    out.hidden = gray(0, 0, W, H);
    present({ width: W, height: H, visible: true, ops: [] });
    out.shownAgain = tileExact();
    // Damage cleared half the tile's cell.
    present({ width: W, height: H, visible: true, ops: [{ kind: 1, x: 64, y: 64, w: 32, h: 32, pixels: null }] });
    out.clearedHalf = gray(64, 64, 32, 32) && ctx.getImageData(96, 64, 1, 1).data[0] === px[32 * 4];
    // A new stream config: clear_all at another size; a layer of another size than the
    // frame is not drawn.
    present({ width: 320, height: 180, visible: true, ops: [{ kind: 0, x: 0, y: 0, w: 320, h: 180, pixels: null }, { kind: 2, x: 0, y: 0, w: tw, h: th, pixels: px }] });
    out.resized = [layer.canvas.width, layer.canvas.height];
    out.otherSize = gray(0, 0, W, H);
    out.puts = layer.puts;
    return out;
  });
  expect(r).toEqual({ put: "exact", aroundPut: true, kept: "exact", hidden: true, shownAgain: "exact", clearedHalf: true, resized: [320, 180], otherSize: true, puts: 2 });
});
