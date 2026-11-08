// Messages between the page (client.ts), the media worker (worker.ts) and the audio
// worklet (audio-worklet.ts).

import type { Overlay, Stats, StreamConfig } from "../core";

export interface StartMsg {
  type: "start";
  wasmUrl: string;
  /** WebSocket URL of the test transport (until shim-web's iroh transport lands). */
  wsUrl: string;
  canvas: OffscreenCanvas;
  /** MessagePort to the audio worklet, or null for no audio. */
  audio: MessagePort | null;
  /** Report the path as relayed (browsers always are; the overlay shows the badge). */
  relayed: boolean;
  /** Stop after this long streaming (0: never). */
  seconds: number;
}

export type ToWorker = StartMsg | { type: "close" };

export interface VideoReport {
  codec: string | null;
  hardware: string;
  configured: number;
  submitted: number;
  decoded: number;
  drawn: number;
  /** Frames failed to the core: decoder errors, or delta frames with no decoder state. */
  failed: number;
  errors: string[];
  /** Per-frame ms over the last report window: decode() to output, output to drawn. */
  decodeMs: number[];
  drawMs: number[];
  nonBlank: boolean;
}

export interface AudioReport {
  /** Frames the worker rendered from the jitter buffer and sent to the worklet. */
  rendered: number;
  /** From the worklet. */
  played: number;
  loud: number;
  underruns: number;
  queued: number;
  sampleRate: number;
}

export interface StatsMsg {
  type: "stats";
  state: "connecting" | "streaming" | "ended";
  end: string;
  config: StreamConfig | null;
  overlay: Overlay;
  stats: Stats;
  video: VideoReport;
  audio: AudioReport;
  relayed: boolean;
}

export type FromWorker = StatsMsg | { type: "error"; message: string };

/** Worklet -> worker. */
export interface NeedMsg {
  need: true;
  played: number;
  loud: number;
  underruns: number;
  queued: number;
  sampleRate: number;
}
/** Worker -> worklet: one frame of interleaved stereo at 48 kHz, or null when none was ready. */
export interface PcmMsg {
  pcm: Float32Array | null;
  channels: number;
}
