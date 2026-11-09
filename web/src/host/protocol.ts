// Messages between the host page (host.ts), the host worker (worker.ts) and the audio tap
// worklet (tap-worklet.ts).

import type { Action, HostStats, InputPolicy, MultiStats } from "./core";

/** A device on the host's allowlist (spec/pairing-v0.md, "Paired-device lists"). */
export interface PairedDevice {
  /** Endpoint ID, 64 hex digits. */
  id: string;
  name: string;
  /** Unix seconds. */
  paired: number;
  /** Its input applies (else it only watches and listens). Default true. */
  input?: boolean;
}

export interface HostStartMsg {
  type: "start";
  wasmUrl: string;
  /** Where shim-web's pkg/ is served (iroh_web.js, iroh_web_bg.wasm). */
  pkgUrl: string;
  relayUrls: string[];
  /** 32-byte endpoint key: the host's identity, which paired clients know it by. */
  secretKey: Uint8Array | null;
  /** The host's name, shown to clients when they pair. */
  name: string;
  /** Devices that may start sessions. */
  allowlist: PairedDevice[];
  policy: InputPolicy;
  maxMembers: number;
  width: number;
  height: number;
  fps: number;
  bitrateBps: number;
  /** Video codec preference, first supported wins: "h264", "av1", "hevc" (the client decodes H.264, HEVC, AV1). */
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

/** The page injected actions; `times` are their client capture times, `from` their members, `at` absolute µs. */
export interface InjectedMsg {
  type: "injected";
  times: number[];
  from: number[];
  at: number;
}

export interface InviteOptions {
  /** How long the window stays open (default 120 s). */
  seconds?: number;
  /** Devices that may pair in it (default 1). */
  pairings?: number;
  /** Wrong guesses before it locks (default 5). */
  attempts?: number;
  /** Offer the QR/link secret (default true) and a PIN (default true). */
  secret?: boolean;
  pin?: boolean;
}

export type ToHostWorker =
  | HostStartMsg
  | FrameMsg
  | InjectedMsg
  | { type: "close" }
  | ({ type: "invite" } & InviteOptions)
  | { type: "invite-close" }
  | { type: "allowlist"; allowlist: PairedDevice[] }
  | { type: "kick"; id: string };

/** An open pairing window. */
export interface Invite {
  /** `MOONSEC1:` QR ticket with the window's one-time secret (null if only a PIN is offered). */
  ticket: string | null;
  /** Six digits, or null. */
  pin: string | null;
  /** Unix ms. */
  expiresAt: number;
  pairingsLeft: number;
  paired: number;
  attemptsLeft: number;
  /** The QR code of `ticket`: size modules per side, row-major, 1 = dark. */
  qr: { size: number; modules: Uint8Array } | null;
}

export interface MemberReport {
  /** Roster id (what actions' `from` say). */
  id: number;
  /** Endpoint ID (hex). */
  endpointId: string;
  name: string;
  input: boolean;
  state: "waiting" | "streaming" | "ended";
  end: string;
  stats: HostStats;
  transport: Record<string, number | boolean> | null;
}

export interface HostReport {
  type: "stats";
  /** starting; waiting (no member); streaming (at least one member streams). */
  state: "starting" | "waiting" | "streaming";
  /** Address ticket (`MOONSEC1:`, no secret): pair with it and the PIN, or reconnect once paired. */
  ticket: string;
  endpointId: string;
  /** Members admitted so far, in all. */
  sessions: number;
  codec: string;
  ltr: boolean;
  invite: Invite | null;
  members: MemberReport[];
  /** Members that left, latest last (at most 8). */
  left: { id: number; endpointId: string; name: string; end: string; stats: HostStats }[];
  /** Pairing and admission outcomes. */
  pairing: { paired: number; failed: number; admitted: number; refused: number; full: number; lastFailure: string };
  multi: MultiStats | null;
  encoder: { ltrMarks: number; ltrRefreshes: number; configured: number; frames: number; busyDrops: number; timeouts: number; lateDiscards: number; errors: string[]; encodeMs: number[]; queueMax: number };
  audio: { encoder: string; frames: number; packets: number; dropped: number; peak: number; errors: string[] };
}

export type FromHostWorker =
  | HostReport
  | { type: "actions"; actions: Action[] }
  | { type: "paired"; device: PairedDevice }
  | { type: "left"; id: number }
  | { type: "error"; message: string };

/** Tap worklet -> worker: 128-frame quanta of interleaved stereo f32 at the context's rate. */
export interface TapMsg {
  pcm: Float32Array;
  sampleRate: number;
}
