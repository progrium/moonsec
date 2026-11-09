// The browser host's core in WebAssembly (app/web_host.zig, moonsec-host.wasm): the
// multi-user host (one encode to every member), the host end of the Opus audio stage, and
// the host side of pairing and admission. Struct layouts below must match the extern
// structs in app/web_host.zig (ABI version 2).

import { wasiImports } from "../core";

export const HOST_ABI_VERSION = 2;

export const enum PeerState {
  waiting = 0,
  streaming = 1,
  ended = 2,
}
export const hostEndNames = ["none", "client_bye", "peer_timeout", "pipe_closed", "closed", "failed"];
export const hostStageNames = ["capture", "encode", "input"] as const;
/** Input policies (spec/multi-user-v0.md). */
export const inputPolicies = { owner: 0, everyone: 1, view: 2 } as const;
export type InputPolicy = keyof typeof inputPolicies;

/** One input action to inject (ActionOut). `from` is the member's roster id; 0 is the host (a release on handoff). */
export type Action = { from: number; time: number } & (
  | { kind: "key"; code: number; down: boolean }
  | { kind: "button"; code: number; down: boolean }
  | { kind: "scroll"; dx: number; dy: number }
  | { kind: "motion"; dx: number; dy: number }
  | { kind: "abs"; x: number; y: number }
  | { kind: "pad"; index: number; connected: boolean; buttons: number; lx: number; ly: number; rx: number; ry: number; lt: number; rt: number }
);

/** StatsOut field order (before the stages): one member's session. */
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

/** MultiStatsOut field order: the encode, roster and audio, one of each. */
export const multiStatNames = [
  "frames",
  "keyframes",
  "refreshes",
  "encode_drops",
  "joins",
  "leaves",
  "inputs_dropped",
  "inputs_applied",
  "releases",
  "format_refusals",
  "members",
  "owner",
  "bitrate_bps",
  "audio_frames",
  "audio_datagrams",
  "audio_errors",
] as const;
export type MultiStats = Record<(typeof multiStatNames)[number], number>;

interface Exports {
  memory: WebAssembly.Memory;
  _initialize(): void;
  mh_abi_version(): number;
  mh_host_new(codec: number, w: number, h: number, fps: number, bitrate: number, channels: number, ltr: number, rateControl: number, policy: number, maxMembers: number): number;
  mh_host_free(w: number): void;
  mh_peer_add(w: number, ctx: number, nameLen: number, mayControl: number): number;
  mh_peer_id(p: number): number;
  mh_rx_slot(p: number): number;
  mh_rx_slot_cap(): number;
  mh_rx_commit(p: number, len: number, recvUs: number): void;
  mh_set_path(p: number, rttUs: number, relayed: number, pathEpoch: number, connEpoch: number, connected: number): void;
  mh_pipe_closed(p: number): void;
  mh_peer_state(p: number): number;
  mh_peer_end(p: number): number;
  mh_peer_close(p: number, nowUs: number): void;
  mh_peer_stats(p: number): number;
  mh_step(w: number, nowUs: number): void;
  mh_next_wake(w: number, nowUs: number): number;
  mh_members(w: number): number;
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
  mh_on_injected(w: number, from: number, clientTime: number, now: number): void;
  mh_audio_pcm(w: number): number;
  mh_audio_pkt(w: number): number;
  mh_audio_pkt_cap(): number;
  mh_audio_encode(w: number, captureUs: number, now: number): number;
  mh_audio_packet(w: number, len: number, samples: number, captureUs: number, now: number): number;
  mh_multi_stats(w: number): number;
  mh_io(w: number): number;
  mh_io_len(): number;
  mh_pair_identity(w: number, nameLen: number): void;
  mh_window_open(w: number, methods: number, deadlineUs: number, pairings: number, attempts: number): number;
  mh_window_close(w: number): void;
  mh_window_state(w: number, nowUs: number): number;
  mh_window_attempts_left(w: number): number;
  mh_window_paired(w: number): number;
  mh_ticket(w: number, addrLen: number, withSecret: number, expires: number): number;
  mh_qr(w: number, len: number): number;
  mh_qr_modules(w: number): number;
  mh_conn_new(w: number): number;
  mh_conn_free(c: number): void;
  mh_conn_push(c: number, len: number): number;
  mh_conn_step(c: number, nowUs: number): number;
  mh_conn_reply(c: number): number;
  mh_conn_reason(c: number): number;
  mh_conn_paired(c: number): number;
  mh_conn_admit(c: number, allowed: number): number;
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
  policy?: InputPolicy;
  maxMembers?: number;
}

/** The compiled module; each HostCore is its own instance (and memory). */
export class HostModule {
  constructor(readonly module: WebAssembly.Module) {}
  static async load(url: string): Promise<HostModule> {
    return new HostModule(await WebAssembly.compileStreaming(fetch(url)));
  }
}

const hexToBytes = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (x) => parseInt(x, 16));
const bytesToHex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const enc = new TextEncoder();
const dec = new TextDecoder();

/** The multi-user host in the core, or (with channels 0 and no members) just its pairing side. */
export class HostCore {
  private x: Exports;
  private w: number;
  private slotCap: number;
  private ioLen: number;
  readonly channels: number;

  private constructor(x: Exports, w: number, channels: number) {
    this.x = x;
    this.w = w;
    this.channels = channels;
    this.slotCap = x.mh_rx_slot_cap();
    this.ioLen = x.mh_io_len();
  }

  /** `send(ctx, dg)` gets every outgoing datagram for the member at `ctx` as a view into wasm memory: copy it before returning. */
  static async create(m: HostModule, o: HostOptions, send: (ctx: number, dg: Uint8Array) => void): Promise<HostCore> {
    let memory: WebAssembly.Memory | undefined;
    const getMemory = () => memory!;
    const instance = await WebAssembly.instantiate(m.module, {
      wasi_snapshot_preview1: wasiImports(getMemory, m.module),
      env: { ms_send: (ctx: number, ptr: number, len: number) => send(ctx, new Uint8Array(getMemory().buffer, ptr, len)) },
    });
    const x = instance.exports as unknown as Exports;
    memory = x.memory;
    x._initialize();
    if (x.mh_abi_version() !== HOST_ABI_VERSION) throw new Error(`moonsec host ABI ${x.mh_abi_version()}, want ${HOST_ABI_VERSION}`);
    const w = x.mh_host_new(o.codec, o.width, o.height, o.fps, o.bitrateBps, o.channels, o.ltr ? 1 : 0, o.rateControl ? 1 : 0, inputPolicies[o.policy ?? "everyone"], o.maxMembers ?? 8);
    if (w === 0) throw new Error("mh_host_new failed");
    return new HostCore(x, w, o.channels);
  }

  free(): void {
    this.x.mh_host_free(this.w);
  }

  private io(n = this.ioLen): Uint8Array {
    return new Uint8Array(this.x.memory.buffer, this.x.mh_io(this.w), n);
  }

  // --- members ------------------------------------------------------------------------

  /** An admitted client joins; null when the session is full. */
  addPeer(ctx: number, name: string, mayControl: boolean): HostPeer | null {
    const nb = enc.encode(name).subarray(0, 64);
    this.io().set(nb);
    const p = this.x.mh_peer_add(this.w, ctx, nb.length, mayControl ? 1 : 0);
    return p === 0 ? null : new HostPeer(this.x, p, this.slotCap);
  }

  step(nowUs: number): void {
    this.x.mh_step(this.w, nowUs);
  }
  nextWake(nowUs: number): number {
    return this.x.mh_next_wake(this.w, nowUs);
  }
  get members(): number {
    return this.x.mh_members(this.w);
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

  /** Every input action the host has queued, in order. */
  takeActions(): Action[] {
    const out: Action[] = [];
    for (;;) {
      const p = this.x.mh_next_action(this.w);
      if (p === 0) return out;
      const dv = new DataView(this.x.memory.buffer, p, 64);
      const u = (i: number) => dv.getUint32(i * 4, true);
      const s = (i: number) => dv.getInt32(i * 4, true);
      const time = dv.getFloat64(48, true);
      const from = dv.getUint32(56, true);
      switch (u(0)) {
        case 1:
          out.push({ kind: "key", code: u(1), down: u(2) !== 0, time, from });
          break;
        case 2:
          out.push({ kind: "button", code: u(1), down: u(2) !== 0, time, from });
          break;
        case 3:
          out.push({ kind: "scroll", dx: s(4), dy: s(5), time, from });
          break;
        case 4:
          out.push({ kind: "motion", dx: s(4), dy: s(5), time, from });
          break;
        case 5:
          out.push({ kind: "abs", x: s(4), y: s(5), time, from });
          break;
        case 6:
          out.push({ kind: "pad", index: u(1), connected: u(2) !== 0, buttons: u(3), lx: s(6), ly: s(7), rx: s(8), ry: s(9), lt: s(10), rt: s(11), time, from });
          break;
      }
    }
  }
  onInjected(from: number, clientTime: number, nowUs: number): void {
    this.x.mh_on_injected(this.w, from, clientTime, nowUs);
  }

  /** Encode 480 frames of interleaved PCM with the core's libopus and send them to every member. */
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

  multiStats(): MultiStats {
    const f = new Float64Array(this.x.memory.buffer, this.x.mh_multi_stats(this.w), multiStatNames.length);
    const out = {} as MultiStats;
    multiStatNames.forEach((n, i) => (out[n] = f[i]));
    return out;
  }

  // --- pairing (spec/pairing-v0.md); the window's clock is wall-clock µs ---------------

  setIdentity(idHex: string, name: string): void {
    const nb = enc.encode(name).subarray(0, 64);
    const io = this.io();
    io.set(hexToBytes(idHex));
    io.set(nb, 32);
    this.x.mh_pair_identity(this.w, nb.length);
  }

  /** Opens a pairing window (replacing any). Returns the PIN when one is offered. */
  openWindow(o: { secret: boolean; pin: boolean; deadlineUs: number; pairings: number; attempts: number }): { pin: string | null } {
    for (let i = 0; i < 8; i++) {
      crypto.getRandomValues(this.io(32));
      const r = this.x.mh_window_open(this.w, (o.secret ? 1 : 0) | (o.pin ? 2 : 0), o.deadlineUs, o.pairings, o.attempts);
      if (r === 0) return { pin: o.pin ? dec.decode(this.io(6).slice()) : null };
      if (!o.secret && !o.pin) break;
    }
    throw new Error("cannot open a pairing window");
  }
  closeWindow(): void {
    this.x.mh_window_close(this.w);
  }
  /** -1 none, 0 closed, 1 open. */
  windowState(nowUs: number): number {
    return this.x.mh_window_state(this.w, nowUs);
  }
  get windowAttemptsLeft(): number {
    return this.x.mh_window_attempts_left(this.w);
  }
  get windowPaired(): number {
    return this.x.mh_window_paired(this.w);
  }

  /** A `MOONSEC1:` ticket for this host at `addr` (its endpoint ticket): with the window's secret (QR ticket) or without (address ticket, pair by PIN). */
  ticket(addr: string, withSecret: boolean, expiresUnixS = 0): string {
    const a = enc.encode(addr);
    if (a.length > 1024) throw new Error("endpoint address too long for a ticket");
    this.io().set(a);
    const n = this.x.mh_ticket(this.w, a.length, withSecret ? 1 : 0, expiresUnixS);
    if (n < 0) throw new Error("cannot make a ticket (no window with a secret?)");
    return dec.decode(this.io(n).slice());
  }

  /** `text` as a QR code: size modules per side, row-major, 1 = dark. */
  qr(text: string): { size: number; modules: Uint8Array } | null {
    const t = enc.encode(text);
    if (t.length > this.ioLen) return null;
    this.io().set(t);
    const size = this.x.mh_qr(this.w, t.length);
    if (size < 0) return null;
    return { size, modules: new Uint8Array(this.x.memory.buffer, this.x.mh_qr_modules(this.w), size * size).slice() };
  }

  /** The first stream of a connection from `peerIdHex`: admission or a pairing exchange. */
  newConn(peerIdHex: string): PairConn {
    const io = this.io();
    io.set(hexToBytes(peerIdHex), 0);
    crypto.getRandomValues(io.subarray(32, 80));
    const c = this.x.mh_conn_new(this.w);
    if (c === 0) throw new Error("mh_conn_new failed");
    return new PairConn(this.x, this.w, c, this.ioLen);
  }
}

/** One member: its pipe and session. */
export class HostPeer {
  readonly id: number;
  constructor(
    private x: Exports,
    private p: number,
    private slotCap: number,
  ) {
    this.id = x.mh_peer_id(p);
  }

  /** Copy one arriving datagram into the member's receive ring. False when it was dropped. */
  push(dg: Uint8Array, recvUs: number): boolean {
    if (dg.length > this.slotCap) return false;
    const s = this.x.mh_rx_slot(this.p);
    if (s === 0) return false;
    new Uint8Array(this.x.memory.buffer, s, dg.length).set(dg);
    this.x.mh_rx_commit(this.p, dg.length, recvUs);
    return true;
  }
  setPath(rttUs: number, relayed: boolean, connected = true): void {
    this.x.mh_set_path(this.p, rttUs, relayed ? 1 : 0, 0, 0, connected ? 1 : 0);
  }
  pipeClosed(): void {
    this.x.mh_pipe_closed(this.p);
  }
  get state(): PeerState {
    return this.x.mh_peer_state(this.p);
  }
  get end(): string {
    return hostEndNames[this.x.mh_peer_end(this.p)] ?? "unknown";
  }
  close(nowUs: number): void {
    this.x.mh_peer_close(this.p, nowUs);
  }
  stats(): HostStats {
    const f = new Float64Array(this.x.memory.buffer, this.x.mh_peer_stats(this.p), hostStatNames.length + 12);
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

export const enum ConnStep {
  malformed = -1,
  more = 0,
  reply = 1,
  paired = 2,
  failed = 3,
  admit = 4,
}

/** Pairing or admission on one connection's first stream (`mh_conn_*`). */
export class PairConn {
  constructor(
    private x: Exports,
    private w: number,
    private c: number,
    private ioLen: number,
  ) {}
  private io(n: number): Uint8Array {
    return new Uint8Array(this.x.memory.buffer, this.x.mh_io(this.w), n);
  }
  /** Feeds stream bytes; returns how many were taken (step, then push the rest). */
  push(bytes: Uint8Array): number {
    const n = Math.min(bytes.length, this.ioLen);
    this.io(n).set(bytes.subarray(0, n));
    return this.x.mh_conn_push(this.c, n);
  }
  step(nowUs: number): ConnStep {
    return this.x.mh_conn_step(this.c, nowUs);
  }
  /** The reply to write after a step (may be empty). */
  reply(): Uint8Array {
    return this.io(this.x.mh_conn_reply(this.c)).slice();
  }
  get reason(): number {
    return this.x.mh_conn_reason(this.c);
  }
  paired(): { id: string; name: string; byPin: boolean } {
    const r = this.x.mh_conn_paired(this.c);
    const n = r & 0xff;
    const io = this.io(32 + n).slice();
    return { id: bytesToHex(io.subarray(0, 32)), name: dec.decode(io.subarray(32)), byPin: (r & 0x100) !== 0 };
  }
  admitReply(allowed: boolean): Uint8Array {
    return this.io(this.x.mh_conn_admit(this.c, allowed ? 1 : 0)).slice();
  }
  free(): void {
    this.x.mh_conn_free(this.c);
  }
}
