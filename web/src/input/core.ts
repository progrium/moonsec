// The input half of the Zig core's wasm ABI (core/input/wasm.zig): sequencing,
// redundancy, motion totals and gamepad snapshots, exactly as on native clients.

import type { PadState } from "./gamepad.js";

interface InputExports {
  memory: WebAssembly.Memory;
  moonsec_input_reset(): void;
  moonsec_input_key(code: number, down: number, now: number): void;
  moonsec_input_button(code: number, down: number, now: number): void;
  moonsec_input_scroll(dx: number, dy: number, now: number): void;
  moonsec_input_move_rel(dx: number, dy: number): void;
  moonsec_input_move_abs(x: number, y: number): void;
  moonsec_input_pad(index: number, connected: number, buttons: number, lx: number, ly: number, rx: number, ry: number, lt: number, rt: number): void;
  moonsec_input_should_send(now: number): number;
  moonsec_input_next_send(now: number): number;
  moonsec_input_build(now: number, seq: number): number;
  moonsec_input_out_ptr(): number;
  moonsec_input_in_ptr(): number;
  moonsec_input_in_cap(): number;
  moonsec_input_on_datagram(len: number): number;
  moonsec_input_unacked(): number;
}

/** Where input calls go: the wasm core in the client, a recorder in unit tests. */
export interface InputSink {
  key(code: number, down: boolean, nowUs: number): void;
  button(code: number, down: boolean, nowUs: number): void;
  scroll(dx: number, dy: number, nowUs: number): void;
  moveRel(dx: number, dy: number): void;
  moveAbs(x: number, y: number): void;
  /** null: disconnected. */
  pad(index: number, state: PadState | null): void;
  /** New input arrived; send now if due. */
  poke(): void;
}

/** Microseconds on the page's monotonic clock (the clock DOM event timeStamps use). */
export function nowUs(): number {
  return performance.now() * 1000;
}

export class InputCore implements InputSink {
  readonly x: InputExports;
  /** Datagram out: the caller stamps nothing, the envelope is already in it. */
  sendDatagram: ((d: Uint8Array) => void) | null = null;
  /** Supplies the transport-wide envelope sequence number for each datagram. */
  nextSeq: () => number = () => 0;
  packetsSent = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(instance: WebAssembly.Instance) {
    this.x = instance.exports as unknown as InputExports;
    this.x.moonsec_input_reset();
  }

  static async load(wasm: BufferSource | Response | Promise<Response>): Promise<InputCore> {
    const src = await wasm;
    const { instance } =
      src instanceof Response ? await WebAssembly.instantiate(await src.arrayBuffer(), {}) : await WebAssembly.instantiate(src, {});
    return new InputCore(instance);
  }

  key(code: number, down: boolean, t: number) {
    this.x.moonsec_input_key(code, down ? 1 : 0, t);
  }
  button(code: number, down: boolean, t: number) {
    this.x.moonsec_input_button(code, down ? 1 : 0, t);
  }
  scroll(dx: number, dy: number, t: number) {
    this.x.moonsec_input_scroll(dx | 0, dy | 0, t);
  }
  moveRel(dx: number, dy: number) {
    this.x.moonsec_input_move_rel(dx | 0, dy | 0);
  }
  moveAbs(x: number, y: number) {
    this.x.moonsec_input_move_abs(x | 0, y | 0);
  }
  pad(index: number, s: PadState | null) {
    if (s === null) this.x.moonsec_input_pad(index, 0, 0, 0, 0, 0, 0, 0, 0);
    else this.x.moonsec_input_pad(index, 1, s.buttons, s.lx, s.ly, s.rx, s.ry, s.lt, s.rt);
  }

  unacked(): number {
    return this.x.moonsec_input_unacked();
  }

  /** Offer a received datagram; returns true if it was an input ack. */
  onDatagram(d: Uint8Array): boolean {
    if (d.length > this.x.moonsec_input_in_cap()) return false;
    new Uint8Array(this.x.memory.buffer, this.x.moonsec_input_in_ptr(), d.length).set(d);
    const r = this.x.moonsec_input_on_datagram(d.length) === 1;
    if (r) this.schedule();
    return r;
  }

  /** Send whatever is due, then arm a timer for the next repeat or keepalive. */
  poke(): void {
    const now = nowUs();
    if (this.x.moonsec_input_should_send(now) && this.sendDatagram) {
      const len = this.x.moonsec_input_build(now, this.nextSeq());
      // Copy out: the buffer is reused and wasm memory may grow.
      this.sendDatagram(new Uint8Array(this.x.memory.buffer, this.x.moonsec_input_out_ptr(), len).slice());
      this.packetsSent++;
    }
    this.schedule();
  }

  private schedule(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    const now = nowUs();
    const next = this.x.moonsec_input_next_send(now);
    if (next < 0) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.poke();
    }, Math.max(0, (next - now) / 1000));
  }

  stop(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }
}
