// The web client on the page: starts the media worker with an OffscreenCanvas, the audio
// worklet, and the overlay. Everything else (core, transport, decode, draw) runs in the
// worker; see worker.ts.

import type { FromWorker, InputOp, StatsMsg, ToWorker } from "./protocol";
import { InputCapture, type InputSink, type MouseMode } from "../input/index";
import type { PadState } from "../input/gamepad";
import { renderOverlay } from "./overlay";

export interface ClientOptions {
  /** Where the bundles and wasm are served from (media-worker.js, media-worklet.js, moonsec-client.wasm). */
  base: string;
  wsUrl: string;
  canvas: HTMLCanvasElement;
  overlay?: HTMLElement;
  audio?: boolean;
  relayed?: boolean;
  seconds?: number;
  onStats?: (s: StatsMsg) => void;
  /** Capture input on this element (default: the canvas); false for view-only. */
  input?: HTMLElement | false;
  mouseMode?: MouseMode;
  onError?: (message: string) => void;
  /** Dial a browser or native host over iroh instead of `wsUrl`. */
  iroh?: { ticket: string; relayUrls: string[]; pkgUrl: string };
  probe?: { x: number; y: number };
}

/**
 * InputCapture's sink on the page: batches calls and posts them to the worker, whose
 * core session sequences them with every other datagram it sends (one envelope counter,
 * acks handled by the session).
 */
export class WorkerInputSink implements InputSink {
  private ops: InputOp[] = [];
  constructor(private worker: Worker) {}

  private static abs(t: number): number {
    return performance.timeOrigin * 1000 + t;
  }
  private static now(): number {
    return WorkerInputSink.abs(performance.now() * 1000);
  }

  key(code: number, down: boolean, t: number) {
    this.ops.push({ op: "key", code, down, t: WorkerInputSink.abs(t) });
  }
  button(code: number, down: boolean, t: number) {
    this.ops.push({ op: "button", code, down, t: WorkerInputSink.abs(t) });
  }
  scroll(dx: number, dy: number, t: number) {
    this.ops.push({ op: "scroll", dx, dy, t: WorkerInputSink.abs(t) });
  }
  moveRel(x: number, y: number) {
    this.ops.push({ op: "rel", x, y, t: WorkerInputSink.now() });
  }
  moveAbs(x: number, y: number) {
    // Latest wins: replace a queued absolute move instead of piling them up.
    const last = this.ops[this.ops.length - 1];
    if (last?.op === "abs") this.ops.pop();
    this.ops.push({ op: "abs", x, y, t: WorkerInputSink.now() });
  }
  pad(index: number, state: PadState | null) {
    this.ops.push({ op: "pad", index, state, t: WorkerInputSink.now() });
  }
  poke() {
    if (this.ops.length === 0) return;
    this.worker.postMessage({ type: "input", ops: this.ops } satisfies ToWorker);
    this.ops = [];
  }
}

export class WebClient {
  readonly worker: Worker;
  audioContext: AudioContext | null = null;
  input: InputCapture | null = null;
  last: StatsMsg | null = null;

  private constructor(worker: Worker) {
    this.worker = worker;
  }

  static async start(o: ClientOptions): Promise<WebClient> {
    const worker = new Worker(new URL("media-worker.js", o.base), { type: "module" });
    const c = new WebClient(worker);
    let audioPort: MessagePort | null = null;
    if (o.audio !== false && typeof AudioWorkletNode !== "undefined") {
      // Must be created (or resumed) from a user gesture outside test browsers.
      const ctx = new AudioContext({ sampleRate: 48000, latencyHint: "interactive" });
      await ctx.audioWorklet.addModule(new URL("media-worklet.js", o.base));
      const node = new AudioWorkletNode(ctx, "moonsec-audio", { numberOfInputs: 0, outputChannelCount: [2] });
      node.connect(ctx.destination);
      const ch = new MessageChannel();
      node.port.postMessage({ port: ch.port1 }, [ch.port1]);
      audioPort = ch.port2;
      // Firefox without an audio device never finishes resuming; closing then rejects this.
      ctx.resume().catch(() => {});
      c.audioContext = ctx;
    }
    worker.onmessage = (ev: MessageEvent<FromWorker>) => {
      const m = ev.data;
      if (m.type === "error") return o.onError?.(m.message);
      c.last = m;
      if (o.overlay) renderOverlay(o.overlay, m);
      o.onStats?.(m);
      if (m.state === "ended" && c.audioContext?.state !== "closed") void c.audioContext?.close().catch(() => {});
    };
    worker.onerror = (e) => o.onError?.(e.message);
    const canvas = o.canvas.transferControlToOffscreen();
    const start: ToWorker = {
      type: "start",
      wasmUrl: new URL("moonsec-client.wasm", o.base).href,
      wsUrl: o.wsUrl,
      canvas,
      audio: audioPort,
      relayed: o.relayed ?? true,
      seconds: o.seconds ?? 0,
      iroh: o.iroh ?? null,
      probe: o.probe ?? null,
    };
    worker.postMessage(start, audioPort ? [canvas, audioPort] : [canvas]);
    if (o.input !== false) {
      const el = o.input ?? o.canvas;
      c.input = new InputCapture(el, new WorkerInputSink(worker), { mode: o.mouseMode ?? "auto", contentRect: () => o.canvas.getBoundingClientRect() });
      c.input.attach();
    }
    return c;
  }

  close(): void {
    this.input?.detach();
    this.input = null;
    this.worker.postMessage({ type: "close" } satisfies ToWorker);
  }
}
