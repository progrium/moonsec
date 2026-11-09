// The browser host on the page: captures the game's canvas and audio, runs the host worker
// (core, iroh, encoders), and injects remote input back into the page.
//
//   <script src="dist/host-patch.js"></script>            first in <head>, before the game
//   <script type="module">
//     import { BrowserHost } from "./dist/host.js";
//     const host = await BrowserHost.start({ canvas, relayUrls: ["https://relay.example"] });
//     host.onReport = (r) => console.log(r.ticket);       // give the ticket to the client
//   </script>

import type { Action } from "./core";
import { Injector } from "./inject";
import type { FromHostWorker, HostReport, HostStartMsg, ToHostWorker } from "./protocol";

export interface BrowserHostOptions {
  canvas: HTMLCanvasElement;
  relayUrls: string[];
  /** Where host-worker.js, host-tap.js and moonsec-host.wasm are served (default: this module's directory). */
  base?: string;
  /** shim-web's pkg/ (default: ../pkg/ next to base). */
  pkgUrl?: string;
  secretKey?: Uint8Array;
  fps?: number;
  bitrateBps?: number;
  codecs?: string[];
  audio?: boolean;
  audioEncoder?: "wasm" | "webcodecs";
  /** "raf": a frame right after each animation frame the game draws (patch.ts); "stream": canvas.captureStream. */
  capture?: "raf" | "stream";
  rateControl?: boolean;
  /** Long-term references (needs Chromium's WebCodecsVideoEncoderBuffers feature; off without it). */
  ltr?: boolean;
  /** Test only: drop this share of host-to-client datagrams. */
  loss?: number;
  /** Test only: drop every host-to-client datagram for this many ms every 3 s. */
  outageMs?: number;
  onReport?: (r: HostReport) => void;
  onError?: (message: string) => void;
}

const absUs = () => (performance.timeOrigin + performance.now()) * 1000;

export class BrowserHost {
  readonly worker: Worker;
  readonly injector: Injector;
  report: HostReport | null = null;
  captured = 0;
  skipped = 0;
  onReport: ((r: HostReport) => void) | null = null;
  private tapPort: MessagePort | null = null;
  private lastCapture = 0;
  private interval: number;

  private constructor(private o: BrowserHostOptions, worker: Worker) {
    this.worker = worker;
    this.injector = new Injector(o.canvas);
    this.interval = 1000 / (o.fps ?? 60);
  }

  static async start(o: BrowserHostOptions): Promise<BrowserHost> {
    const hooks = window.__moonsecHost;
    if (!hooks) throw new Error("host-patch.js must load before the game (first script in <head>)");
    const base = o.base ?? new URL(".", import.meta.url).href;
    const worker = new Worker(new URL("host-worker.js", base), { type: "module" });
    const h = new BrowserHost(o, worker);
    h.onReport = o.onReport ?? null;
    worker.onmessage = (ev: MessageEvent<FromHostWorker>) => h.onMessage(ev.data);
    worker.onerror = (e) => o.onError?.(e.message);

    let audioPort: MessagePort | null = null;
    if (o.audio !== false) {
      const ch = new MessageChannel();
      audioPort = ch.port2;
      h.tapPort = ch.port1;
      // The first AudioContext the game makes is the one streamed (often created on a click).
      const tap = (ctx: AudioContext) => void h.attachTap(ctx, base);
      if (hooks.contexts.length > 0) tap(hooks.contexts[0]);
      else hooks.onContext = (ctx) => {
        hooks.onContext = null;
        tap(ctx);
      };
    }
    const c = o.canvas;
    const start: HostStartMsg = {
      type: "start",
      wasmUrl: new URL("moonsec-host.wasm", base).href,
      pkgUrl: o.pkgUrl ?? new URL("../pkg/", base).href,
      relayUrls: o.relayUrls,
      secretKey: o.secretKey ?? null,
      width: c.width,
      height: c.height,
      fps: o.fps ?? 60,
      bitrateBps: o.bitrateBps ?? 6_000_000,
      codecs: o.codecs ?? ["h264", "av1"],
      audio: audioPort,
      audioEncoder: o.audioEncoder ?? "wasm",
      rateControl: o.rateControl ?? false,
      ltr: o.ltr ?? true,
      loss: o.loss ?? 0,
      outageMs: o.outageMs ?? 0,
    };
    worker.postMessage(start, audioPort ? [audioPort] : []);
    if ((o.capture ?? "raf") === "raf") h.captureOnFrames();
    else void h.captureStream();
    return h;
  }

  private async attachTap(ctx: AudioContext, base: string) {
    const hooks = window.__moonsecHost;
    const bus = hooks.busOf(ctx);
    if (!bus || !this.tapPort) return;
    await ctx.audioWorklet.addModule(new URL("host-tap.js", base));
    const node = new AudioWorkletNode(ctx, "moonsec-tap", { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [2], channelCount: 2, channelCountMode: "explicit" });
    hooks.nativeConnect(bus, node);
    // The tap outputs silence; connecting it keeps it pulled by the graph.
    hooks.nativeConnect(node, ctx.destination);
    node.port.postMessage({ port: this.tapPort }, [this.tapPort]);
    this.tapPort = null;
  }

  // --- video -----------------------------------------------------------------------------

  private captureOnFrames() {
    const hooks = window.__moonsecHost;
    hooks.onFrame = () => this.capture();
    // Games that draw from timers, or a page whose rAF is throttled: capture on a timer
    // when no animation frame has come for a while.
    setInterval(() => {
      if (performance.now() - hooks.lastFrameAt > 100) this.capture();
    }, this.interval);
  }

  private capture() {
    const now = performance.now();
    // At most `fps`: a 120 Hz display runs rAF twice per encoded frame.
    if (now - this.lastCapture < this.interval * 0.75) {
      this.skipped++;
      return;
    }
    this.lastCapture = now;
    const t0 = absUs();
    let frame: VideoFrame;
    try {
      frame = new VideoFrame(this.o.canvas, { timestamp: t0 });
    } catch {
      return; // a canvas with nothing drawn yet
    }
    this.captured++;
    this.worker.postMessage({ type: "frame", frame, captureStartUs: t0, capturedUs: absUs() } satisfies ToHostWorker, [frame]);
  }

  private async captureStream() {
    const track = this.o.canvas.captureStream(this.o.fps ?? 60).getVideoTracks()[0];
    const Proc = (window as unknown as { MediaStreamTrackProcessor?: new (o: { track: MediaStreamTrack }) => { readable: ReadableStream<VideoFrame> } }).MediaStreamTrackProcessor;
    if (!Proc) throw new Error("no MediaStreamTrackProcessor: use capture: \"raf\"");
    const reader = new Proc({ track }).readable.getReader();
    for (;;) {
      const { value: frame, done } = await reader.read();
      if (done || !frame) return;
      const t = absUs();
      this.captured++;
      this.worker.postMessage({ type: "frame", frame, captureStartUs: t, capturedUs: t } satisfies ToHostWorker, [frame]);
    }
  }

  // --- worker --------------------------------------------------------------------------------

  private onMessage(m: FromHostWorker) {
    if (m.type === "error") return this.o.onError?.(m.message);
    if (m.type === "actions") return this.inject(m.actions);
    if (this.report?.state === "streaming" && m.state !== "streaming") this.injector.releaseAll();
    this.report = m;
    this.onReport?.(m);
  }

  private inject(actions: Action[]) {
    const times: number[] = [];
    for (const a of actions) {
      this.injector.apply(a);
      times.push(a.time);
    }
    this.worker.postMessage({ type: "injected", times, at: absUs() } satisfies ToHostWorker);
  }

  close() {
    this.worker.postMessage({ type: "close" } satisfies ToHostWorker);
  }
}
