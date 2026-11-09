// AudioWorklet tap for the browser host: copies the page's mix (everything the game
// connected to its AudioContext's destination, routed through patch.ts's bus) to the host
// worker, one render quantum at a time as interleaved stereo f32. Its output is silence.

import type { TapMsg } from "./protocol";

declare const sampleRate: number;
declare function registerProcessor(name: string, ctor: unknown): void;
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}

const silence = new Float32Array(128);

class MoonsecTap extends AudioWorkletProcessor {
  private worker: MessagePort | null = null;

  constructor() {
    super();
    this.port.onmessage = (ev: MessageEvent<{ port: MessagePort }>) => {
      this.worker = ev.data.port;
    };
  }

  process(inputs: Float32Array[][]): boolean {
    const w = this.worker;
    const input = inputs[0];
    if (!w) return true;
    // No input connected: keep the stream going with silence.
    const l = input?.[0] ?? silence;
    const r = input?.[1] ?? l;
    const pcm = new Float32Array(l.length * 2);
    for (let i = 0; i < l.length; i++) {
      pcm[2 * i] = l[i];
      pcm[2 * i + 1] = r[i];
    }
    w.postMessage({ pcm, sampleRate } satisfies TapMsg, [pcm.buffer]);
    return true;
  }
}

registerProcessor("moonsec-tap", MoonsecTap);
