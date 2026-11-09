// The Zig core in WebAssembly (app/web.zig): the client session and the Opus audio
// stage behind a C ABI. This file loads the module and wraps the ABI; the struct
// layouts below must match the extern structs in app/web.zig (ABI version 1).

import type { PadState } from "./input/gamepad.js";

export const ABI_VERSION = 1;

/// api.Codec values.
export const Codec = { h264: 1, hevc: 2, av1: 3, passthrough: 250 } as const;
/// api.CodecSet bits.
export const CodecBit = { h264: 1, hevc: 2, av1: 4 } as const;

export const enum State {
  connecting = 0,
  streaming = 1,
  ended = 2,
}
export const endNames = ['none', 'host_bye', 'peer_timeout', 'connect_timeout', 'pipe_closed', 'closed', 'failed'];
export const stageNames = ['capture', 'encode', 'network', 'decode', 'present', 'total', 'input'] as const;
export type StageName = (typeof stageNames)[number];

export interface StreamConfig {
  codec: number;
  slices: number;
  fps: number;
  width: number;
  height: number;
  bitrateBps: number;
}

export interface Frame {
  /// A view into wasm memory, valid until the next `nextFrame`.
  data: Uint8Array;
  frameId: number;
  keyframe: boolean;
  codec: number;
  captureUs: number;
  receivedUs: number;
}

export interface StageTimes {
  count: number;
  /// Microseconds; -1 when there is no sample (e.g. cross-clock stages before clock sync).
  last: number;
  p50: number;
  p99: number;
}

export interface Overlay {
  bitrateBps: number;
  pacingBps: number;
  rttUs: number;
  loss: number;
  relayed: boolean;
  freezes: number;
  clockSynced: boolean;
  frames: number;
  stages: Record<StageName, StageTimes>;
}

/// StatsOut field order.
export const statNames = [
  'frames_received',
  'frames_lost',
  'frames_dropped',
  'frames_stale',
  'frames_decoded',
  'decode_errors',
  'frames_presented',
  'queue_overflows',
  'shards',
  'nacks',
  'feedback',
  'frame_acks',
  'pongs',
  'input_events',
  'input_packets',
  'malformed',
  'recovery_requests',
  'freezes',
  'audio_decoded',
  'audio_fec',
  'audio_rs_recovered',
  'audio_concealed',
  'audio_late',
  'audio_silence',
  'audio_delay_us',
  'rx_drops',
] as const;
export type Stats = Record<(typeof statNames)[number], number>;

interface Exports {
  memory: WebAssembly.Memory;
  _initialize(): void;
  ms_abi_version(): number;
  ms_client_new(ctx: number, codecs: number, nonce: number, maxW: number, maxH: number, channels: number): number;
  ms_client_free(w: number): void;
  ms_rx_slot(w: number): number;
  ms_rx_slot_cap(): number;
  ms_rx_commit(w: number, len: number, recvUs: number): void;
  ms_set_path(w: number, rttUs: number, relayed: number, pathEpoch: number, connEpoch: number, connected: number): void;
  ms_pipe_closed(w: number): void;
  ms_step(w: number, nowUs: number): void;
  ms_next_wake(w: number, nowUs: number): number;
  ms_state(w: number): number;
  ms_end(w: number): number;
  ms_close(w: number, nowUs: number): void;
  ms_config(w: number): number;
  ms_next_frame(w: number): number;
  ms_on_decoded(w: number, id: number, ok: number, t: number): void;
  ms_on_presented(w: number, id: number, t: number): void;
  ms_audio_render(w: number, nowUs: number): number;
  ms_audio_buf(w: number): number;
  ms_audio_channels(w: number): number;
  ms_overlay(w: number, nowUs: number): number;
  ms_stats(w: number): number;
  ms_input_key(w: number, code: number, down: number, t: number): void;
  ms_input_button(w: number, code: number, down: number, t: number): void;
  ms_input_scroll(w: number, dx: number, dy: number, t: number): void;
  ms_input_move_rel(w: number, dx: number, dy: number, t: number): void;
  ms_input_move_abs(w: number, x: number, y: number, t: number): void;
  ms_input_pad(w: number, index: number, connected: number, buttons: number, lx: number, ly: number, rx: number, ry: number, lt: number, rt: number, t: number): void;
}

/// The module's WASI imports. The core does no I/O: everything but stderr (panic
/// messages), the clock, randomness and exit answers ENOSYS.
function wasiImports(getMemory: () => WebAssembly.Memory, module: WebAssembly.Module): Record<string, Function> {
  const ENOSYS = 52;
  const imports: Record<string, Function> = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module === 'wasi_snapshot_preview1' && imp.kind === 'function') imports[imp.name] = () => ENOSYS;
  }
  // No preopened directories: wasi-libc's start-up scan stops at the first EBADF.
  imports.fd_prestat_get = () => 8;
  let line = '';
  imports.fd_write = (fd: number, iovs: number, n: number, nwritten: number) => {
    const dv = new DataView(getMemory().buffer);
    let total = 0;
    for (let i = 0; i < n; i++) {
      const ptr = dv.getUint32(iovs + i * 8, true);
      const len = dv.getUint32(iovs + i * 8 + 4, true);
      line += new TextDecoder().decode(new Uint8Array(getMemory().buffer, ptr, len));
      total += len;
    }
    const parts = line.split('\n');
    line = parts.pop() ?? '';
    for (const p of parts) (fd === 2 ? console.error : console.log)('[moonsec core]', p);
    dv.setUint32(nwritten, total, true);
    return 0;
  };
  imports.clock_time_get = (_id: number, _prec: bigint, out: number) => {
    new DataView(getMemory().buffer).setBigUint64(out, BigInt(Math.round(performance.now() * 1e6)), true);
    return 0;
  };
  imports.random_get = (ptr: number, len: number) => {
    crypto.getRandomValues(new Uint8Array(getMemory().buffer, ptr, len));
    return 0;
  };
  imports.proc_exit = (code: number) => {
    throw new Error(`moonsec core exited with ${code}`);
  };
  return imports;
}

/// One client session in the core.
export class CoreSession {
  private x: Exports;
  private w: number;
  private slotCap: number;

  private constructor(x: Exports, w: number) {
    this.x = x;
    this.w = w;
    this.slotCap = x.ms_rx_slot_cap();
  }

  /// Instantiates the module and creates a session. `send` gets every outgoing datagram
  /// as a view into wasm memory: copy it before returning.
  static async create(
    source: BufferSource | Response | Promise<Response>,
    opts: { codecs: number; nonce?: number; maxWidth?: number; maxHeight?: number; channels?: number },
    send: (dg: Uint8Array) => void,
  ): Promise<CoreSession> {
    const module =
      source instanceof Response || source instanceof Promise
        ? await WebAssembly.compileStreaming(source)
        : await WebAssembly.compile(source);
    let memory: WebAssembly.Memory | undefined;
    const getMemory = () => memory!;
    const instance = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: wasiImports(getMemory, module),
      env: {
        ms_send: (_ctx: number, ptr: number, len: number) => send(new Uint8Array(getMemory().buffer, ptr, len)),
      },
    });
    const x = instance.exports as unknown as Exports;
    memory = x.memory;
    x._initialize();
    if (x.ms_abi_version() !== ABI_VERSION) throw new Error(`moonsec core ABI ${x.ms_abi_version()}, want ${ABI_VERSION}`);
    const nonce = opts.nonce ?? ((Math.random() * 0xffffffff) >>> 0 || 1);
    const w = x.ms_client_new(0, opts.codecs, nonce, opts.maxWidth ?? 0, opts.maxHeight ?? 0, opts.channels ?? 2);
    if (w === 0) throw new Error('moonsec core: could not create the session');
    return new CoreSession(x, w);
  }

  private get dv(): DataView {
    return new DataView(this.x.memory.buffer);
  }

  /// Hands an arriving datagram to the session (call `step` soon after). False when the
  /// receive ring is full or the datagram is too large; it is dropped.
  push(dg: Uint8Array, recvUs: number): boolean {
    if (dg.length > this.slotCap) return false;
    const slot = this.x.ms_rx_slot(this.w);
    if (slot === 0) return false;
    new Uint8Array(this.x.memory.buffer, slot, dg.length).set(dg);
    this.x.ms_rx_commit(this.w, dg.length, recvUs);
    return true;
  }

  setPath(p: { rttUs: number; relayed: boolean; pathEpoch: number; connEpoch: number; connected: boolean }): void {
    this.x.ms_set_path(this.w, p.rttUs, p.relayed ? 1 : 0, p.pathEpoch, p.connEpoch, p.connected ? 1 : 0);
  }

  pipeClosed(): void {
    this.x.ms_pipe_closed(this.w);
  }

  step(nowUs: number): void {
    this.x.ms_step(this.w, nowUs);
  }

  nextWake(nowUs: number): number {
    return this.x.ms_next_wake(this.w, nowUs);
  }

  get state(): State {
    return this.x.ms_state(this.w);
  }

  get end(): string {
    return endNames[this.x.ms_end(this.w)] ?? 'unknown';
  }

  close(nowUs: number): void {
    this.x.ms_close(this.w, nowUs);
  }

  config(): StreamConfig | null {
    const p = this.x.ms_config(this.w);
    const dv = this.dv;
    const c = {
      codec: dv.getUint32(p, true),
      slices: dv.getUint32(p + 4, true),
      fps: dv.getUint32(p + 8, true),
      width: dv.getUint32(p + 12, true),
      height: dv.getUint32(p + 16, true),
      bitrateBps: dv.getFloat64(p + 24, true),
    };
    return c.fps === 0 ? null : c;
  }

  nextFrame(): Frame | null {
    const p = this.x.ms_next_frame(this.w);
    if (p === 0) return null;
    const dv = this.dv;
    return {
      data: new Uint8Array(this.x.memory.buffer, dv.getUint32(p, true), dv.getUint32(p + 4, true)),
      frameId: dv.getUint32(p + 8, true),
      keyframe: dv.getUint32(p + 12, true) !== 0,
      codec: dv.getUint32(p + 16, true),
      captureUs: dv.getFloat64(p + 24, true),
      receivedUs: dv.getFloat64(p + 32, true),
    };
  }

  onDecoded(id: number, ok: boolean, t: number): void {
    this.x.ms_on_decoded(this.w, id, ok ? 1 : 0, t);
  }

  onPresented(id: number, t: number): void {
    this.x.ms_on_presented(this.w, id, t);
  }

  get audioChannels(): number {
    return this.x.ms_audio_channels(this.w);
  }

  /// The next 10 ms (or so) of interleaved PCM from the jitter buffer, copied out; null
  /// before the stream starts or with audio off.
  renderAudio(nowUs: number): Float32Array | null {
    const n = this.x.ms_audio_render(this.w, nowUs);
    if (n === 0) return null;
    const ch = this.audioChannels;
    return new Float32Array(this.x.memory.buffer, this.x.ms_audio_buf(this.w), n * ch).slice();
  }

  overlay(nowUs: number): Overlay {
    const p = this.x.ms_overlay(this.w, nowUs);
    const dv = this.dv;
    const g = (i: number) => dv.getFloat64(p + i * 8, true);
    const stages = {} as Record<StageName, StageTimes>;
    stageNames.forEach((n, i) => {
      const b = 8 + i * 4;
      stages[n] = { count: g(b), last: g(b + 1), p50: g(b + 2), p99: g(b + 3) };
    });
    return {
      bitrateBps: g(0),
      pacingBps: g(1),
      rttUs: g(2),
      loss: g(3),
      relayed: g(4) !== 0,
      freezes: g(5),
      clockSynced: g(6) !== 0,
      frames: g(7),
      stages,
    };
  }

  stats(): Stats {
    const p = this.x.ms_stats(this.w);
    const dv = this.dv;
    const s = {} as Stats;
    statNames.forEach((n, i) => (s[n] = dv.getFloat64(p + i * 8, true)));
    return s;
  }

  key(code: number, down: boolean, t: number): void {
    this.x.ms_input_key(this.w, code, down ? 1 : 0, t);
  }
  button(code: number, down: boolean, t: number): void {
    this.x.ms_input_button(this.w, code, down ? 1 : 0, t);
  }
  scroll(dx: number, dy: number, t: number): void {
    this.x.ms_input_scroll(this.w, dx, dy, t);
  }
  moveRel(dx: number, dy: number, t: number): void {
    this.x.ms_input_move_rel(this.w, dx, dy, t);
  }
  moveAbs(x: number, y: number, t: number): void {
    this.x.ms_input_move_abs(this.w, x, y, t);
  }
  /** null: disconnected. */
  pad(index: number, s: PadState | null, t: number): void {
    if (s === null) this.x.ms_input_pad(this.w, index, 0, 0, 0, 0, 0, 0, 0, 0, t);
    else this.x.ms_input_pad(this.w, index, 1, s.buttons, s.lx, s.ly, s.rx, s.ry, s.lt, s.rt, t);
  }

  free(): void {
    this.x.ms_client_free(this.w);
    this.w = 0;
  }
}
