// Messages between the host page (host.ts), the host worker (worker.ts) and the audio tap
// worklet (tap-worklet.ts).

import type { Action, HostStats } from "./core";

export interface HostStartMsg {
  type: "start";
  wasmUrl: string;
  /** Where shim-web's pkg/ is served (iroh_web.js, iroh_web_bg.wasm). */
  pkgUrl: string;
  relayUrls: string[];
  /** 32-byte endpoint key to keep the same ticket across reloads (optional). */
  secretKey: Uint8Array | null;
  width: number;
  height: number;
  fps: number;
  bitrateBps: number;
  /** Video codec preference, first supported wins: "h264", "av1", "vp9"-less (the client decodes H.264, HEVC, AV1). */
  codecs: string[];
  /** Port from the audio tap worklet, or null for no audio. */
  audio: MessagePort | null;
  /** "wasm": libopus in the core; "webcodecs": WebCodecs AudioEncoder (Opus). */
  audioEncoder: "wasm" | "webcodecs";
  rateControl: boolean;
  /** Long-term references through WebCodecs' manual reference buffers (Chromium, behind
   *  --enable-blink-features=WebCodecsVideoEncoderBuffers). Falls back to off without them. */
  ltr: boolean;
  /** Test only: drop this share of host-to-client datagrams. */
  loss: number;
  /** Test only: drop every host-to-client datagram for this many ms every 3 s. */
  outageMs: number;
}

/** A captured frame. Times are absolute µs (performance.timeOrigin + now). */
export interface FrameMsg {
  type: "frame";
  frame: VideoFrame;
  captureStartUs: number;
  capturedUs: number;
}

/** The page injected actions; `times` are their client capture times, `at` absolute µs. */
export interface InjectedMsg {
  type: "injected";
  times: number[];
  at: number;
}

export type ToHostWorker = HostStartMsg | FrameMsg | InjectedMsg | { type: "close" };

export interface HostReport {
  type: "stats";
  state: "starting" | "waiting" | "streaming" | "ended";
  end: string;
  ticket: string;
  endpointId: string;
  sessions: number;
  client: string;
  codec: string;
  ltr: boolean;
  encoder: { ltrMarks: number; ltrRefreshes: number; configured: number; frames: number; busyDrops: number; timeouts: number; lateDiscards: number; errors: string[]; encodeMs: number[]; queueMax: number };
  audio: { encoder: string; frames: number; packets: number; dropped: number; peak: number; errors: string[] };
  stats: HostStats | null;
  /** shim-web's connection counters (Connection.stats()). */
  transport: Record<string, number | boolean> | null;
}

export type FromHostWorker = HostReport | { type: "actions"; actions: Action[] } | { type: "error"; message: string };

/** Tap worklet -> worker: 128-frame quanta of interleaved stereo f32 at the context's rate. */
export interface TapMsg {
  pcm: Float32Array;
  sampleRate: number;
}
