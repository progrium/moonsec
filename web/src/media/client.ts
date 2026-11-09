// The web client on the page: starts the media worker with an OffscreenCanvas, the audio
// worklet, and the overlay. Everything else (core, transport, decode, draw) runs in the
// worker; see worker.ts.

import type { FromWorker, InputOp, IrohDial, PairedHost, StatsMsg, ToWorker } from "./protocol";
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
  /** Dial a browser or native host over iroh instead of `wsUrl` (pairing first if needed). */
  iroh?: IrohDial;
  /** Pairing with an address ticket needs the host's PIN: resolve with what the person typed. */
  onPin?: (info: { hostId: string; error: string; attemptsLeft: number }) => Promise<string>;
  /** This device paired with a host: keep it (and the device's key) for later sessions. */
  onPaired?: (host: PairedHost) => void;
  /** "pairing", "connecting". */
  onStatus?: (text: string) => void;
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
      // WebKit can start a context "interrupted" (its audio session was not granted yet) or
      // interrupt it later; it does not come back by itself. Resume it, and again on the
      // next gesture.
      const revive = () => {
        const st = ctx.state as string;
        if (st === "interrupted" || st === "suspended") ctx.resume().catch(() => {});
      };
      let tries = 0;
      const poll = setInterval(() => {
        if ((ctx.state as string) === "closed" || ++tries > 50) return clearInterval(poll);
        revive();
      }, 200);
      for (const t of ["pointerdown", "keydown"]) addEventListener(t, revive, { capture: true });
      c.audioContext = ctx;
    }
    worker.onmessage = (ev: MessageEvent<FromWorker>) => {
      const m = ev.data;
      if (m.type === "error") return o.onError?.(m.message);
      if (m.type === "paired-host") return o.onPaired?.(m.host);
      if (m.type === "status") return o.onStatus?.(m.text);
      if (m.type === "pin-needed") {
        const { type: _t, ...info } = m;
        if (!o.onPin) return o.onError?.("this host needs its PIN to pair (an address ticket)");
        void o.onPin(info).then((pin) => worker.postMessage({ type: "pin", pin } satisfies ToWorker));
        return;
      }
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
