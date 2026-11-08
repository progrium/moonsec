// The harness page: the web client's input path wired to the stub host, plus probes
// for video decode and audio playback. Tests drive it through `window.harness`.
//
// Query parameters: loss (input datagram loss at the stub host, 0..1), seed, mouse
// (auto | relative | absolute), fakepad (install a scriptable fake gamepad).

import { InputCapture, InputCore, MouseMode } from "../../src/input/index.js";
import { EnvelopeSeq, WebSocketTransport } from "../../src/transport.js";
import { DecodeReport, DecodeSink, pickConfig, ProbeFrame } from "./decode.js";

const params = new URLSearchParams(location.search);
const log = (s: string) => {
  const el = document.getElementById("log");
  if (el) el.textContent += s + "\n";
};

// --- fake gamepad -----------------------------------------------------------

interface FakePad {
  buttons: boolean[];
  values: number[];
  axes: number[];
}
const fakePads: (FakePad | null)[] = [];

function installFakePads(): void {
  const make = (i: number, p: FakePad) => ({
    id: "moonsec fake pad (STANDARD GAMEPAD)",
    index: i,
    connected: true,
    mapping: "standard",
    timestamp: performance.now(),
    axes: p.axes.slice(),
    buttons: p.buttons.map((pressed, k) => ({ pressed, touched: pressed, value: p.values[k] ?? (pressed ? 1 : 0) })),
    vibrationActuator: null,
  });
  Object.defineProperty(navigator, "getGamepads", {
    configurable: true,
    value: () => fakePads.map((p, i) => (p ? make(i, p) : null)),
  });
}

if (params.has("fakepad")) installFakePads();

// --- input path -----------------------------------------------------------

const core = await InputCore.load(fetch("/wasm/moonsec-core.wasm"));
const wsUrl = `ws://${location.host}/ws?loss=${params.get("loss") ?? 0}&seed=${params.get("seed") ?? 1}`;
const transport = await WebSocketTransport.connect(wsUrl);
const seq = new EnvelopeSeq();
core.nextSeq = () => seq.take();
core.sendDatagram = (d) => transport.send(d);
transport.onDatagram = (d) => void core.onDatagram(d);

const stream = document.getElementById("stream") as HTMLElement;
const capture = new InputCapture(stream, core, { mode: (params.get("mouse") as MouseMode) ?? "auto" });
capture.attach();
stream.focus();
log(`caps ${JSON.stringify(capture.caps)}`);
let lastFullscreen: { fullscreen: boolean; keyboardLocked: boolean } | null = null;
// Double-click: fullscreen plus Keyboard Lock where the browser has it.
stream.addEventListener("dblclick", async () => {
  lastFullscreen = await capture.enterFullscreen();
  log(`fullscreen ${JSON.stringify(lastFullscreen)}`);
});

// --- video probe ----------------------------------------------------------

function percentile(xs: number[], p: number): number | null {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return +s[Math.min(s.length - 1, Math.floor(p * s.length))].toFixed(2);
}

export interface VideoResult {
  supported: Record<string, string | null>;
  report: DecodeReport | null;
  workerFallback: string | null;
  summary: Record<string, number | null> | null;
}

async function videoProbe(prefer: string[] = ["h264", "vp8"]): Promise<VideoResult> {
  const supported: Record<string, string | null> = {};
  for (const c of ["h264", "vp8"]) {
    const cfg = await pickConfig(c);
    supported[c] = cfg ? (cfg.hardwareAcceleration ?? "no-preference") : null;
  }
  const codec = prefer.find((c) => supported[c]);
  if (!codec) return { supported, report: null, workerFallback: null, summary: null };

  // Worker + OffscreenCanvas first; main thread if the worker can't decode.
  const canvas = document.getElementById("video") as HTMLCanvasElement;
  let push: (f: ProbeFrame) => void;
  let finish: () => Promise<DecodeReport | null>;
  let workerFallback: string | null = null;
  const worker = "transferControlToOffscreen" in canvas ? new Worker("/dist/decode-worker.js", { type: "module" }) : null;
  const workerReady = worker
    ? await new Promise<string | true>((resolve) => {
        const off = canvas.transferControlToOffscreen();
        worker.onmessage = (ev) => resolve(ev.data.type === "ready" ? true : (ev.data.why as string));
        worker.onerror = (ev) => resolve(`worker error: ${ev.message}`);
        worker.postMessage({ type: "init", codec, canvas: off }, [off]);
      })
    : "no OffscreenCanvas";
  if (worker && workerReady === true) {
    push = (f) => worker.postMessage({ type: "frame", frame: f }, [f.data]);
    finish = () =>
      new Promise((resolve) => {
        worker.onmessage = (ev) => ev.data.type === "report" && resolve(ev.data.report);
        worker.postMessage({ type: "finish" });
      });
  } else {
    workerFallback = workerReady === true ? null : workerReady;
    worker?.terminate();
    // The original canvas may have been transferred: draw to a fresh one.
    const c2 = document.createElement("canvas");
    c2.width = 320;
    c2.height = 180;
    stream.replaceChildren(c2);
    const sink = new DecodeSink(c2, codec, (await pickConfig(codec))!, "main");
    push = (f) => sink.push(f);
    finish = () => sink.finish();
  }

  await new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(`ws://${location.host}/media`);
    ws.binaryType = "arraybuffer";
    ws.onopen = () => ws.send(JSON.stringify({ video: codec, fps: 30 }));
    ws.onerror = () => reject(new Error("media socket failed"));
    ws.onmessage = (ev) => {
      if (typeof ev.data === "string") return reject(new Error(ev.data));
      const b = new Uint8Array(ev.data as ArrayBuffer);
      if (b[0] === 255) {
        ws.close();
        return resolve();
      }
      const dv = new DataView(b.buffer);
      push({ key: b[1] === 1, index: dv.getUint32(2, true), data: b.slice(10).buffer, arrivedAt: performance.timeOrigin + performance.now() });
    };
  });
  const report = await finish();
  worker?.terminate();
  const summary = report
    ? {
        decodeP50: percentile(report.decodeMs, 0.5),
        decodeP95: percentile(report.decodeMs, 0.95),
        arrivalToDrawP50: percentile(report.arrivalToDrawMs, 0.5),
        arrivalToDrawP95: percentile(report.arrivalToDrawMs, 0.95),
        drawP50: percentile(report.drawMs, 0.5),
        drawP95: percentile(report.drawMs, 0.95),
      }
    : null;
  return { supported, report, workerFallback, summary };
}

// --- audio probe ----------------------------------------------------------

export interface AudioResult {
  ok: boolean;
  error?: string;
  state?: string;
  sampleRate?: number;
  baseLatencyMs?: number | null;
  outputLatencyMs?: number | null;
  played?: number;
  underruns?: number;
  peak?: number;
  /** RMS seen by an AnalyserNode after the worklet (0.35 for the stub's 0.5 sine). */
  rms?: number;
  /** Frequency estimated from zero crossings (440 expected). */
  hz?: number;
}

/** Reject after `ms` naming the stage, so a stalled audio stack reports where it stalled. */
function within<T>(p: Promise<T>, ms: number, stage: string): Promise<T> {
  return Promise.race([p, new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`${stage} timed out after ${ms} ms`)), ms))]);
}

async function audioProbe(ms = 1000): Promise<AudioResult> {
  if (typeof AudioContext === "undefined") return { ok: false, error: "no AudioContext" };
  const ctx = new AudioContext({ sampleRate: 48000, latencyHint: "interactive" });
  try {
    if (!ctx.audioWorklet) return { ok: false, error: "no AudioWorklet" };
    await within(ctx.audioWorklet.addModule("/dist/audio-worklet.js"), 10_000, "audioWorklet.addModule");
    const node = new AudioWorkletNode(ctx, "pcm-player", { numberOfInputs: 0, outputChannelCount: [1] });
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 2048;
    node.connect(analyser);
    analyser.connect(ctx.destination);
    await within(ctx.resume(), 10_000, "AudioContext.resume");
    let rms = 0;
    let hz = 0;
    await within(new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(`ws://${location.host}/media`);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => ws.send(JSON.stringify({ audio: true, ms }));
      ws.onerror = () => reject(new Error("media socket failed"));
      let chunks = 0;
      ws.onmessage = (ev) => {
        const b = new Uint8Array(ev.data as ArrayBuffer);
        if (b[0] === 255) {
          ws.close();
          return resolve();
        }
        const pcm = new Float32Array(b.slice(1).buffer);
        node.port.postMessage(pcm, [pcm.buffer]);
        // Measure mid-stream, once the jitter buffer is running.
        if (++chunks === Math.floor(ms / 40)) {
          const buf = new Float32Array(analyser.fftSize);
          analyser.getFloatTimeDomainData(buf);
          let sq = 0;
          let crossings = 0;
          for (let i = 0; i < buf.length; i++) {
            sq += buf[i] * buf[i];
            if (i > 0 && buf[i - 1] < 0 && buf[i] >= 0) crossings++;
          }
          rms = Math.sqrt(sq / buf.length);
          hz = (crossings * ctx.sampleRate) / buf.length;
        }
      };
    }), ms + 10_000, "tone stream");
    const stats = await within(new Promise<{ played: number; underruns: number; peak: number }>((resolve) => {
      node.port.onmessage = (e) => resolve(e.data);
      node.port.postMessage("stats");
    }), 5_000, "worklet stats");
    return {
      ok: true,
      state: ctx.state,
      sampleRate: ctx.sampleRate,
      baseLatencyMs: ctx.baseLatency != null ? +(ctx.baseLatency * 1000).toFixed(2) : null,
      outputLatencyMs: "outputLatency" in ctx && ctx.outputLatency ? +(ctx.outputLatency * 1000).toFixed(2) : null,
      ...stats,
      rms: +rms.toFixed(3),
      hz: Math.round(hz),
    };
  } catch (e) {
    return { ok: false, error: String(e), state: ctx.state };
  } finally {
    void ctx.close().catch(() => {});
  }
}

// --- test API ---------------------------------------------------------------

declare global {
  interface Window {
    harness: unknown;
  }
}

window.harness = {
  ready: true,
  userAgent: navigator.userAgent,
  caps: () => ({ ...capture.caps }),
  stats: () => ({ ...capture.stats, pointerLocked: capture.pointerLocked, mouseMode: capture.mouseMode, unacked: core.unacked(), packetsSent: core.packetsSent }),
  lockPointer: () => capture.lockPointer(),
  fullscreen: () => lastFullscreen,
  setPad: (i: number, p: FakePad | null) => {
    fakePads[i] = p;
    capture.pollPads();
  },
  videoProbe,
  audioProbe,
};
log("ready");
