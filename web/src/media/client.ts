// The web client on the page: starts the media worker with an OffscreenCanvas, the audio
// worklet, and the overlay. Everything else (core, transport, decode, draw) runs in the
// worker; see worker.ts.

import type { FromWorker, StatsMsg, ToWorker } from "./protocol";
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
  onError?: (message: string) => void;
}

export class WebClient {
  readonly worker: Worker;
  audioContext: AudioContext | null = null;
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
      void ctx.resume();
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
    };
    worker.postMessage(start, audioPort ? [canvas, audioPort] : [canvas]);
    return c;
  }

  close(): void {
    this.worker.postMessage({ type: "close" } satisfies ToWorker);
  }
}
