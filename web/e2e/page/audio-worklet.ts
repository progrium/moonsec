// PCM player: a small jitter buffer (play once 20 ms is queued, spec/audio-v0.md), then
// one 128-sample render quantum at a time. Reports what it played and underruns.

const target = 960; // 20 ms at 48 kHz

class PcmPlayer extends AudioWorkletProcessor {
  private queue: Float32Array[] = [];
  private offset = 0;
  private queued = 0;
  private started = false;
  private played = 0;
  private underruns = 0;
  private peak = 0;

  constructor() {
    super();
    this.port.onmessage = (e: MessageEvent) => {
      if (e.data === "stats") {
        this.port.postMessage({ played: this.played, underruns: this.underruns, queued: this.queued, peak: this.peak });
        return;
      }
      const pcm = e.data as Float32Array;
      this.queue.push(pcm);
      this.queued += pcm.length;
    };
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const out = outputs[0][0];
    if (!this.started && this.queued >= target) this.started = true;
    if (!this.started) return true;
    let i = 0;
    while (i < out.length && this.queue.length > 0) {
      const head = this.queue[0];
      const n = Math.min(out.length - i, head.length - this.offset);
      out.set(head.subarray(this.offset, this.offset + n), i);
      for (let k = 0; k < n; k++) this.peak = Math.max(this.peak, Math.abs(out[i + k]));
      i += n;
      this.offset += n;
      this.queued -= n;
      if (this.offset === head.length) {
        this.queue.shift();
        this.offset = 0;
      }
    }
    this.played += i;
    if (i < out.length) {
      this.underruns++;
      this.started = false; // refill the jitter buffer
    }
    for (let c = 1; c < outputs[0].length; c++) outputs[0][c].set(out);
    return true;
  }
}

registerProcessor("pcm-player", PcmPlayer);
