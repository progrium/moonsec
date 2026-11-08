#!/usr/bin/env node
// What this Chromium's WebCodecs offers a browser host (web/host/README.md): encoders and
// scalability modes per codec, Opus in AudioEncoder, MediaStreamTrackProcessor, and the
// manual reference buffers long-term references need (VideoEncoder.getAllFrameBuffers,
// behind --enable-blink-features=WebCodecsVideoEncoderBuffers).
//
//   node web/e2e/webcodecs-caps.mjs [--buffers]     --buffers: launch with the feature on
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const { chromium } = createRequire(join(web, "package.json"))("playwright");
const buffers = process.argv.includes("--buffers");
const browser = await chromium.launch({ args: buffers ? ["--enable-blink-features=WebCodecsVideoEncoderBuffers"] : [] });
// WebCodecs needs a secure context: serve a blank page from 127.0.0.1.
const srv = createServer((_q, res) => res.writeHead(200, { "content-type": "text/html" }).end("<!doctype html>")).listen(0, "127.0.0.1");
await new Promise((r) => srv.on("listening", r));
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${srv.address().port}/`);

const codecs = ["avc1.42E028", "av01.0.08M.08", "vp09.00.10.08", "vp8", "hvc1.1.6.L120.B0"];
const caps = await page.evaluate(async (codecs) => {
  const out = { getAllFrameBuffers: typeof VideoEncoder.prototype.getAllFrameBuffers === "function", codecs: {} };
  const ok = async (cfg) => {
    try {
      return (await VideoEncoder.isConfigSupported(cfg)).supported;
    } catch (e) {
      return String(e);
    }
  };
  const base = { width: 1280, height: 720, bitrate: 6e6, framerate: 60, latencyMode: "realtime" };
  for (const codec of codecs) {
    out.codecs[codec] = {
      software: await ok({ ...base, codec }),
      hardware: await ok({ ...base, codec, hardwareAcceleration: "prefer-hardware" }),
      L1T3: await ok({ ...base, codec, scalabilityMode: "L1T3" }),
      manual: await ok({ ...base, codec, scalabilityMode: "manual" }),
    };
  }
  out.opus10ms = await AudioEncoder.isConfigSupported({ codec: "opus", sampleRate: 48000, numberOfChannels: 2, opus: { frameDuration: 10000, useinbandfec: true } }).then((r) => r.supported, (e) => String(e));
  out.mediaStreamTrackProcessor = typeof MediaStreamTrackProcessor === "function";
  return out;
}, codecs);

// With the buffers: a keyframe into buffer 0, then deltas that reference only buffer 0
// (the shape of an LTR refresh). Reports how many buffers each codec gets and whether it encodes.
if (caps.getAllFrameBuffers) {
  caps.manualRefs = {};
  for (const codec of codecs) {
    caps.manualRefs[codec] = await page
      .evaluate(async (codec) => {
        const types = [];
        const enc = new VideoEncoder({ output: (c) => types.push(c.type), error: (e) => types.push(`error ${e.message}`) });
        enc.configure({ codec, width: 640, height: 360, bitrate: 2e6, latencyMode: "realtime", scalabilityMode: "manual" });
        const bufs = enc.getAllFrameBuffers();
        if (bufs.length < 2) return { buffers: bufs.length };
        const cv = new OffscreenCanvas(640, 360);
        const g = cv.getContext("2d");
        for (let i = 0; i < 6; i++) {
          g.fillStyle = `hsl(${i * 40} 80% 50%)`;
          g.fillRect(0, 0, 640, 360);
          const f = new VideoFrame(cv, { timestamp: i * 16666 });
          enc.encode(f, i === 0 ? { keyFrame: true, updateBuffer: bufs[0] } : { referenceBuffers: [bufs[0]], updateBuffer: bufs[1] });
          f.close();
        }
        await enc.flush();
        return { buffers: bufs.length, chunks: types };
      }, codec)
      .catch((e) => String(e).split("\n")[0]);
  }
}
caps.browser = `chromium ${browser.version()}${buffers ? " --enable-blink-features=WebCodecsVideoEncoderBuffers" : ""}`;
console.log(JSON.stringify(caps, null, 2));
await browser.close();
srv.close();
