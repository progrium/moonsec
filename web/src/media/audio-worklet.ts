// AudioWorklet sink for the core's audio stage. It keeps a small ring of 48 kHz PCM and
// asks the media worker (over a MessagePort) for the next frame whenever the ring runs
// below `lowWater`, the way native sinks pull from the jitter buffer (app/apps.zig,
// ClientAudio). The jitter buffer itself (20 ms, spec/audio-v0.md) is in the core; this
// ring only covers the hop between threads. If the context runs at another rate than
// 48 kHz, frames are resampled linearly.

import type { NeedMsg, PcmMsg } from "./protocol";

declare const sampleRate: number;
declare function registerProcessor(name: string, ctor: unknown): void;
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}

/** Samples (per channel, at 48 kHz) kept ahead: one 10 ms frame plus three render quanta. */
const lowWater = 480 + 384;
const cap = 48000;

class MoonsecAudio extends AudioWorkletProcessor {
  private ring = new Float32Array(cap * 2);
  private pos = 0;
  private frac = 0;
  private len = 0;
  private write = 0;
  private outstanding = 0;
  private worker: MessagePort | null = null;
  private played = 0;
  private loud = 0;
  private underruns = 0;
  private started = false;
  private step = 48000 / sampleRate;

  constructor() {
    super();
    this.port.onmessage = (ev: MessageEvent<{ port: MessagePort }>) => {
      this.worker = ev.data.port;
      this.worker.onmessage = (e: MessageEvent<PcmMsg>) => this.onPcm(e.data);
    };
  }

  private onPcm(m: PcmMsg) {
    this.outstanding = Math.max(0, this.outstanding - 1);
    if (!m.pcm) return;
    const n = m.pcm.length / m.channels;
    for (let i = 0; i < n && this.len < cap; i++) {
      const l = m.pcm[i * m.channels];
      const r = m.channels > 1 ? m.pcm[i * m.channels + 1] : l;
      this.ring[this.write * 2] = l;
      this.ring[this.write * 2 + 1] = r;
      this.write = (this.write + 1) % cap;
      this.len++;
    }
    this.started = true;
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const out = outputs[0];
    const L = out[0];
    const R = out[1] ?? out[0];
    for (let i = 0; i < L.length; i++) {
      if (this.len < 2) {
        L[i] = R[i] = 0;
        if (this.started) this.underruns++;
        continue;
      }
      const i1 = (this.pos + 1) % cap;
      const t = this.frac;
      const l = this.ring[this.pos * 2] * (1 - t) + this.ring[i1 * 2] * t;
      const r = this.ring[this.pos * 2 + 1] * (1 - t) + this.ring[i1 * 2 + 1] * t;
      L[i] = l;
      R[i] = r;
      if (Math.abs(l) > 0.01) this.loud++;
      this.played++;
      this.frac += this.step;
      while (this.frac >= 1) {
        this.frac -= 1;
        this.pos = (this.pos + 1) % cap;
        this.len--;
      }
    }
    if (this.worker && this.len + this.outstanding * 480 < lowWater) {
      this.outstanding++;
      const m: NeedMsg = { need: true, played: this.played, loud: this.loud, underruns: this.underruns, queued: this.len, sampleRate };
      this.worker.postMessage(m);
    }
    return true;
  }
}

registerProcessor("moonsec-audio", MoonsecAudio);
