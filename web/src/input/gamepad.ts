// Gamepad API to core.input.Gamepad: button bits in XInput's wButtons order plus guide
// (core.input.Gamepad.Button), sticks -32768..32767 right/up positive, triggers 0..65535.

export const Button = {
  dpadUp: 0x0001,
  dpadDown: 0x0002,
  dpadLeft: 0x0004,
  dpadRight: 0x0008,
  start: 0x0010,
  back: 0x0020,
  leftThumb: 0x0040,
  rightThumb: 0x0080,
  leftShoulder: 0x0100,
  rightShoulder: 0x0200,
  guide: 0x0400,
  a: 0x1000,
  b: 0x2000,
  x: 0x4000,
  y: 0x8000,
} as const;

export const maxPads = 4;

export interface PadState {
  buttons: number;
  lx: number;
  ly: number;
  rx: number;
  ry: number;
  lt: number;
  rt: number;
}

/** Standard Gamepad mapping (https://w3c.github.io/gamepad/#remapping) button index to bit. */
const standardButtons: readonly number[] = [
  Button.a, // 0 bottom face
  Button.b, // 1 right face
  Button.x, // 2 left face
  Button.y, // 3 top face
  Button.leftShoulder, // 4
  Button.rightShoulder, // 5
  0, // 6 left trigger (analog, below)
  0, // 7 right trigger
  Button.back, // 8
  Button.start, // 9
  Button.leftThumb, // 10
  Button.rightThumb, // 11
  Button.dpadUp, // 12
  Button.dpadDown, // 13
  Button.dpadLeft, // 14
  Button.dpadRight, // 15
  Button.guide, // 16
];

/** A float stick in -1..1 to -32768..32767, as the native clients scale it. */
export function stick(v: number): number {
  if (!Number.isFinite(v)) return 0;
  const c = Math.min(1, Math.max(-1, v));
  return Math.round(c < 0 ? c * 32768 : c * 32767);
}

/** A float trigger in 0..1 to 0..65535. */
export function trigger(v: number): number {
  if (!Number.isFinite(v)) return 0;
  return Math.round(Math.min(1, Math.max(0, v)) * 65535);
}

/**
 * Map one Gamepad to a snapshot. Pads without the standard mapping are read as if they
 * had it (most report the same layout); the Y axes flip because DOM axes grow down.
 */
export function readPad(gp: Gamepad): PadState {
  let buttons = 0;
  const n = Math.min(gp.buttons.length, standardButtons.length);
  for (let i = 0; i < n; i++) if (gp.buttons[i].pressed) buttons |= standardButtons[i];
  const axis = (i: number) => (i < gp.axes.length ? gp.axes[i] : 0);
  const trig = (i: number) => {
    const b = gp.buttons[i];
    if (!b) return 0;
    return trigger(b.value || (b.pressed ? 1 : 0));
  };
  return {
    buttons,
    lx: stick(axis(0)),
    ly: stick(-axis(1)),
    rx: stick(axis(2)),
    ry: stick(-axis(3)),
    lt: trig(6),
    rt: trig(7),
  };
}

export function samePad(a: PadState, b: PadState): boolean {
  return a.buttons === b.buttons && a.lx === b.lx && a.ly === b.ly && a.rx === b.rx && a.ry === b.ry && a.lt === b.lt && a.rt === b.rt;
}

/**
 * Gives each browser gamepad (by Gamepad.index, which can exceed 3) one of the core's
 * four slots for as long as it stays connected, like platform/client/gamepad's Slots.
 */
export class PadSlots {
  private ids: (number | null)[] = new Array(maxPads).fill(null);

  slotOf(index: number): number {
    return this.ids.indexOf(index);
  }

  /** The slot for a connected pad (taking the lowest free one), or -1 when all are taken. */
  claim(index: number): number {
    const at = this.slotOf(index);
    if (at >= 0) return at;
    const free = this.ids.indexOf(null);
    if (free >= 0) this.ids[free] = index;
    return free;
  }

  /** Free a pad's slot; returns it, or -1 if it had none. */
  release(index: number): number {
    const at = this.slotOf(index);
    if (at >= 0) this.ids[at] = null;
    return at;
  }

  /** The pad index holding a slot, or null. */
  idAt(slot: number): number | null {
    return this.ids[slot] ?? null;
  }

  claimed(): number[] {
    return this.ids.flatMap((id, slot) => (id === null ? [] : [slot]));
  }
}
