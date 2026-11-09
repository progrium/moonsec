// The browser host's core in WebAssembly (app/web_host.zig, moonsec-host.wasm): the host
// session and the host end of the Opus audio stage. Struct layouts below must match the
// extern structs in app/web_host.zig (ABI version 1).

import { wasiImports } from "../core";

export const HOST_ABI_VERSION = 1;

export const enum HostState {
  waiting = 0,
  streaming = 1,
  ended = 2,
}
export const hostEndNames = ["none", "client_bye", "peer_timeout", "pipe_closed", "closed", "failed"];
export const hostStageNames = ["capture", "encode", "input"] as const;

/** One input action to inject (ActionOut). */
export type Action =
  | { kind: "key"; code: number; down: boolean; time: number }
  | { kind: "button"; code: number; down: boolean; time: number }
  | { kind: "scroll"; dx: number; dy: number; time: number }
  | { kind: "motion"; dx: number; dy: number; time: number }
  | { kind: "abs"; x: number; y: number; time: number }
  | { kind: "pad"; index: number; connected: boolean; buttons: number; lx: number; ly: number; rx: number; ry: number; lt: number; rt: number; time: number };

/** StatsOut field order (before the stages). */
export const hostStatNames = [
  "frames",
  "keyframes",
  "refreshes",
  "encode_drops",
  "bytes",
  "shards",
  "nacks",
  "retransmits",
  "feedback",
  "frame_acks",
  "recovery_requests",
  "pings",
  "inputs_applied",
  "hellos",
  "malformed",
  "pacing_bps",
  "rtt_us",
  "bitrate_bps",
  "audio_frames",
  "audio_datagrams",
  "audio_errors",
  "rx_drops",
] as const;
export type HostStats = Record<(typeof hostStatNames)[number], number> & {
  stages: Record<(typeof hostStageNames)[number], { count: number; last: number; p50: number; p99: number }>;
};

interface Exports {
  memory: WebAssembly.Memory;
  _initialize(): void;
  mh_abi_version(): number;
  mh_host_new(ctx: number, codec: number, w: number, h: number, fps: number, bitrate: number, channels: number, ltr: number, rateControl: number): number;
  mh_host_free(w: number): void;
  mh_rx_slot(w: number): number;
  mh_rx_slot_cap(): number;
  mh_rx_commit(w: number, len: number, recvUs: number): void;
  mh_set_path(w: number, rttUs: number, relayed: number, pathEpoch: number, connEpoch: number, connected: number): void;
  mh_pipe_closed(w: number): void;
  mh_step(w: number, nowUs: number): void;
  mh_next_wake(w: number, nowUs: number): number;
  mh_state(w: number): number;
  mh_end(w: number): number;
  mh_streaming(w: number): number;
  mh_close(w: number, nowUs: number): void;
  mh_encode_begin(w: number): number;
  mh_encode_bitrate(w: number): number;
  mh_encode_acked_n(w: number): number;
  mh_encode_acked(w: number): number;
  mh_au_buf(w: number, len: number): number;
  mh_encode_done(w: number, len: number, key: number, ltrToken: number, ltrRefresh: number, captureStart: number, captured: number, encodeStart: number, encoded: number, width: number, height: number, now: number): void;
  mh_encode_dropped(w: number): void;
  mh_next_action(w: number): number;
  mh_on_injected(w: number, clientTime: number, now: number): void;
  mh_audio_pcm(w: number): number;
  mh_audio_pkt(w: number): number;
  mh_audio_pkt_cap(): number;
  mh_audio_encode(w: number, captureUs: number, now: number): number;
  mh_audio_packet(w: number, len: number, samples: number, captureUs: number, now: number): number;
  mh_stats(w: number): number;
}

export interface HostOptions {
  codec: number;
  width: number;
  height: number;
  fps: number;
  bitrateBps: number;
  channels: number;
  rateControl?: boolean;
  /** The encoder keeps long-term references (WebCodecs manual reference buffers). */
  ltr?: boolean;
}

/** The compiled module, instantiated once per session (each session gets fresh memory). */
export class HostModule {
  constructor(readonly module: WebAssembly.Module) {}
  static async load(url: string): Promise<HostModule> {
    return new HostModule(await WebAssembly.compileStreaming(fetch(url)));
  }
}

/** One host session in the core. */
export class HostCore {
  private x: Exports;
  private w: number;
  private slotCap: number;
  readonly channels: number;

  private constructor(x: Exports, w: number, channels: number) {
    this.x = x;
    this.w = w;
    this.channels = channels;
    this.slotCap = x.mh_rx_slot_cap();
  }

  /** `send` gets every outgoing datagram as a view into wasm memory: copy it before returning. */
  static async create(m: HostModule, o: HostOptions, send: (dg: Uint8Array) => void): Promise<HostCore> {
    let memory: WebAssembly.Memory | undefined;
    const getMemory = () => memory!;
    const instance = await WebAssembly.instantiate(m.module, {
      wasi_snapshot_preview1: wasiImports(getMemory, m.module),
      env: { ms_send: (_ctx: number, ptr: number, len: number) => send(new Uint8Array(getMemory().buffer, ptr, len)) },
    });
    const x = instance.exports as unknown as Exports;
    memory = x.memory;
    x._initialize();
    if (x.mh_abi_version() !== HOST_ABI_VERSION) throw new Error(`moonsec host ABI ${x.mh_abi_version()}, want ${HOST_ABI_VERSION}`);
    const w = x.mh_host_new(0, o.codec, o.width, o.height, o.fps, o.bitrateBps, o.channels, o.ltr ? 1 : 0, o.rateControl ? 1 : 0);
    if (w === 0) throw new Error("mh_host_new failed");
    return new HostCore(x, w, o.channels);
  }

  free(): void {
    this.x.mh_host_free(this.w);
  }

  /** Copy one arriving datagram into the receive ring. False when it was dropped. */
  push(dg: Uint8Array, recvUs: number): boolean {
    if (dg.length > this.slotCap) return false;
    const p = this.x.mh_rx_slot(this.w);
    if (p === 0) return false;
    new Uint8Array(this.x.memory.buffer, p, dg.length).set(dg);
    this.x.mh_rx_commit(this.w, dg.length, recvUs);
    return true;
  }

  setPath(rttUs: number, relayed: boolean, connected = true): void {
    this.x.mh_set_path(this.w, rttUs, relayed ? 1 : 0, 0, 0, connected ? 1 : 0);
  }
  pipeClosed(): void {
    this.x.mh_pipe_closed(this.w);
  }
  step(nowUs: number): void {
    this.x.mh_step(this.w, nowUs);
  }
  nextWake(nowUs: number): number {
    return this.x.mh_next_wake(this.w, nowUs);
  }
  get state(): HostState {
    return this.x.mh_state(this.w);
  }
  get end(): string {
    return hostEndNames[this.x.mh_end(this.w)] ?? "unknown";
  }
  get streaming(): boolean {
    return this.x.mh_streaming(this.w) !== 0;
  }
  close(nowUs: number): void {
    this.x.mh_close(this.w, nowUs);
  }

  /** Start one encode: 0 normal, 1 LTR refresh, 2 keyframe; plus a new bitrate (0: unchanged). */
  encodeBegin(): { force: number; bitrateBps: number; ackedTokens: number[] } {
    const force = this.x.mh_encode_begin(this.w);
    const n = this.x.mh_encode_acked_n(this.w);
    const ackedTokens = n === 0 ? [] : Array.from(new Float64Array(this.x.memory.buffer, this.x.mh_encode_acked(this.w), n));
    return { force, bitrateBps: this.x.mh_encode_bitrate(this.w), ackedTokens };
  }
  encodeDone(chunk: EncodedVideoChunk, ltr: { token: number; refresh: boolean }, t: { captureStartUs: number; capturedUs: number; encodeStartUs: number; encodedUs: number; width: number; height: number }, nowUs: number): void {
    const p = this.x.mh_au_buf(this.w, chunk.byteLength);
    if (p === 0) return this.x.mh_encode_dropped(this.w);
    chunk.copyTo(new Uint8Array(this.x.memory.buffer, p, chunk.byteLength));
    this.x.mh_encode_done(this.w, chunk.byteLength, chunk.type === "key" ? 1 : 0, ltr.token, ltr.refresh ? 1 : 0, t.captureStartUs, t.capturedUs, t.encodeStartUs, t.encodedUs, t.width, t.height, nowUs);
  }
  encodeDropped(): void {
    this.x.mh_encode_dropped(this.w);
  }

  /** Every input action the session has queued, in order. */
  takeActions(): Action[] {
    const out: Action[] = [];
    for (;;) {
      const p = this.x.mh_next_action(this.w);
      if (p === 0) return out;
      const dv = new DataView(this.x.memory.buffer, p, 56);
      const u = (i: number) => dv.getUint32(i * 4, true);
      const s = (i: number) => dv.getInt32(i * 4, true);
      const time = dv.getFloat64(48, true);
      switch (u(0)) {
        case 1:
          out.push({ kind: "key", code: u(1), down: u(2) !== 0, time });
          break;
        case 2:
          out.push({ kind: "button", code: u(1), down: u(2) !== 0, time });
          break;
        case 3:
          out.push({ kind: "scroll", dx: s(4), dy: s(5), time });
          break;
        case 4:
          out.push({ kind: "motion", dx: s(4), dy: s(5), time });
          break;
        case 5:
          out.push({ kind: "abs", x: s(4), y: s(5), time });
          break;
        case 6:
          out.push({ kind: "pad", index: u(1), connected: u(2) !== 0, buttons: u(3), lx: s(6), ly: s(7), rx: s(8), ry: s(9), lt: s(10), rt: s(11), time });
          break;
      }
    }
  }
  onInjected(clientTime: number, nowUs: number): void {
    this.x.mh_on_injected(this.w, clientTime, nowUs);
  }

  /** Encode 480 frames of interleaved PCM with the core's libopus and send them. */
  audioEncode(pcm: Float32Array, captureUs: number, nowUs: number): number {
    new Float32Array(this.x.memory.buffer, this.x.mh_audio_pcm(this.w), pcm.length).set(pcm);
    return this.x.mh_audio_encode(this.w, captureUs, nowUs);
  }
  /** Send one Opus packet encoded elsewhere (WebCodecs AudioEncoder). */
  audioPacket(chunk: EncodedAudioChunk, samples: number, captureUs: number, nowUs: number): number {
    if (chunk.byteLength > this.x.mh_audio_pkt_cap()) return 0;
    chunk.copyTo(new Uint8Array(this.x.memory.buffer, this.x.mh_audio_pkt(this.w), chunk.byteLength));
    return this.x.mh_audio_packet(this.w, chunk.byteLength, samples, captureUs, nowUs);
  }

  stats(): HostStats {
    const p = this.x.mh_stats(this.w);
    const f = new Float64Array(this.x.memory.buffer, p, hostStatNames.length + 12);
    const out = {} as HostStats;
    hostStatNames.forEach((n, i) => (out[n] = f[i]));
    out.stages = {} as HostStats["stages"];
    hostStageNames.forEach((n, i) => {
      const b = hostStatNames.length + i * 4;
      out.stages[n] = { count: f[b], last: f[b + 1], p50: f[b + 2], p99: f[b + 3] };
    });
    return out;
  }
}
