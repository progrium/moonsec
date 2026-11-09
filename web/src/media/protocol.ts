// Messages between the page (client.ts), the media worker (worker.ts) and the audio
// worklet (audio-worklet.ts).

import type { Overlay, Stats, StreamConfig } from "../core";
import type { PadState } from "../input/gamepad";

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
  /** Dial a host over iroh (shim-web) instead of the WebSocket test transport. */
  iroh?: { ticket: string; relayUrls: string[]; pkgUrl: string } | null;
  /** Watch the pixel at (x, y) of each drawn frame and report when it turns light or dark (latency tests). */
  probe?: { x: number; y: number } | null;
}

/** A probe pixel change: when the frame showing it was drawn (absolute µs) and its new state. */
export interface ProbeEvent {
  at: number;
  light: boolean;
  frameId: number;
}

/**
 * One input call from the page's InputCapture (src/input), forwarded to the core's
 * session. `t` is absolute (performance.timeOrigin + now, in µs) because the page's and
 * the worker's performance.now() have different origins.
 */
export type InputOp =
  | { op: "key" | "button"; code: number; down: boolean; t: number }
  | { op: "scroll"; dx: number; dy: number; t: number }
  | { op: "rel" | "abs"; x: number; y: number; t: number }
  | { op: "pad"; index: number; state: PadState | null; t: number };

export type ToWorker = StartMsg | { type: "close" } | { type: "input"; ops: InputOp[] };

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
  /** Requests answered empty because rendering had run ahead of the clock. */
  paced: number;
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
  /** shim-web's connection counters when the transport is iroh. */
  transport?: Record<string, number | boolean> | null;
  /** Probe changes since the last report. */
  probe: ProbeEvent[];
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
