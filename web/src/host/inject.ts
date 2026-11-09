// Remote input into the hosted page as synthetic DOM events (and virtual gamepads through
// patch.ts). Games read input from window/document key events, pointer/mouse events on
// their canvas, wheel events and navigator.getGamepads(); all of those are covered. What a
// synthetic event cannot do: it has isTrusted false, so it cannot start Pointer Lock,
// fullscreen, audio playback or a popup (the browser wants a real user gesture for those).

import { codeForUsage } from "../input/hid";
import { Button } from "../input/gamepad";
import type { Action } from "./core";
import type { VirtualPad } from "./patch";

/** core button (1 left, 2 right, 3 middle, 4 back, 5 forward) to MouseEvent.button. */
const domButton: Record<number, number> = { 1: 0, 2: 2, 3: 1, 4: 3, 5: 4 };
/** MouseEvent.button to its MouseEvent.buttons bit. */
const buttonsBit = [1, 4, 2, 8, 16];

/** Standard-mapping button index to core.input.Gamepad button bit (gamepad.ts, reversed). */
const standardBits: number[] = [
  Button.a, Button.b, Button.x, Button.y, Button.leftShoulder, Button.rightShoulder, 0, 0,
  Button.back, Button.start, Button.leftThumb, Button.rightThumb,
  Button.dpadUp, Button.dpadDown, Button.dpadLeft, Button.dpadRight, Button.guide,
];

const legacyKeyCodes: Record<string, number> = {
  Backspace: 8, Tab: 9, Enter: 13, ShiftLeft: 16, ShiftRight: 16, ControlLeft: 17, ControlRight: 17,
  AltLeft: 18, AltRight: 18, Pause: 19, CapsLock: 20, Escape: 27, Space: 32, PageUp: 33, PageDown: 34,
  End: 35, Home: 36, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Insert: 45, Delete: 46,
  MetaLeft: 91, MetaRight: 92, ContextMenu: 93, Semicolon: 186, Equal: 187, Comma: 188, Minus: 189,
  Period: 190, Slash: 191, Backquote: 192, BracketLeft: 219, Backslash: 220, BracketRight: 221, Quote: 222,
};
const namedKeys: Record<string, string> = {
  Space: " ", ShiftLeft: "Shift", ShiftRight: "Shift", ControlLeft: "Control", ControlRight: "Control",
  AltLeft: "Alt", AltRight: "Alt", MetaLeft: "Meta", MetaRight: "Meta", NumpadEnter: "Enter",
  Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Backslash: "\\", Semicolon: ";",
  Quote: "'", Backquote: "`", Comma: ",", Period: ".", Slash: "/",
};
const shifted: Record<string, string> = {
  "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
  "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": '"', "`": "~", ",": "<", ".": ">", "/": "?",
};

function keyFor(code: string, shift: boolean): { key: string; keyCode: number } {
  if (code.startsWith("Key")) {
    const c = code.slice(3);
    return { key: shift ? c : c.toLowerCase(), keyCode: c.charCodeAt(0) };
  }
  if (code.startsWith("Digit")) {
    const d = code.slice(5);
    return { key: shift ? shifted[d] : d, keyCode: d.charCodeAt(0) };
  }
  if (code.startsWith("Numpad") && /\d$/.test(code)) return { key: code.slice(6), keyCode: 96 + Number(code.slice(6)) };
  if (/^F\d+$/.test(code)) return { key: code, keyCode: 111 + Number(code.slice(1)) };
  const named = namedKeys[code];
  const key = named !== undefined ? (shift && shifted[named] ? shifted[named] : named) : code;
  return { key, keyCode: legacyKeyCodes[code] ?? 0 };
}

export interface InjectorStats {
  keys: number;
  buttons: number;
  moves: number;
  scrolls: number;
  pads: number;
  unknownKeys: number;
}

export class Injector {
  /** Pointer position in client coordinates. */
  x = 0;
  y = 0;
  private held = new Set<string>();
  private buttons = 0;
  private downTarget: Element | null = null;
  stats: InjectorStats = { keys: 0, buttons: 0, moves: 0, scrolls: 0, pads: 0, unknownKeys: 0 };

  constructor(private canvas: HTMLCanvasElement) {
    const r = canvas.getBoundingClientRect();
    this.x = r.left + r.width / 2;
    this.y = r.top + r.height / 2;
  }

  apply(a: Action): void {
    switch (a.kind) {
      case "key":
        return this.key(a.code, a.down);
      case "button":
        return this.button(a.code, a.down);
      case "scroll":
        return this.wheel(a.dx, a.dy);
      case "motion":
        return this.move(this.x + a.dx, this.y + a.dy, a.dx, a.dy);
      case "abs": {
        const r = this.canvas.getBoundingClientRect();
        const x = r.left + (a.x / 65535) * r.width;
        const y = r.top + (a.y / 65535) * r.height;
        return this.move(x, y, x - this.x, y - this.y);
      }
      case "pad":
        return this.pad(a);
    }
  }

  private mods() {
    const h = this.held;
    return {
      shiftKey: h.has("ShiftLeft") || h.has("ShiftRight"),
      ctrlKey: h.has("ControlLeft") || h.has("ControlRight"),
      altKey: h.has("AltLeft") || h.has("AltRight"),
      metaKey: h.has("MetaLeft") || h.has("MetaRight"),
    };
  }

  private key(usage: number, down: boolean) {
    const code = codeForUsage(usage);
    if (!code) {
      this.stats.unknownKeys++;
      return;
    }
    const repeat = down && this.held.has(code);
    if (down) this.held.add(code);
    else if (!this.held.delete(code)) return;
    const { key, keyCode } = keyFor(code, this.mods().shiftKey);
    const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : document.body;
    const fire = (type: string, kc: number) => {
      const ev = new KeyboardEvent(type, { key, code, repeat, bubbles: true, cancelable: true, composed: true, ...this.mods() });
      // Older games (and GameMaker's HTML5 runner) read the legacy codes.
      Object.defineProperty(ev, "keyCode", { get: () => kc });
      Object.defineProperty(ev, "which", { get: () => kc });
      if (type === "keypress") Object.defineProperty(ev, "charCode", { get: () => kc });
      return target.dispatchEvent(ev);
    };
    const notCancelled = fire(down ? "keydown" : "keyup", keyCode);
    if (down && notCancelled && key.length === 1) fire("keypress", key.charCodeAt(0));
    this.stats.keys++;
  }

  private target(): Element {
    return document.elementFromPoint(this.x, this.y) ?? this.canvas;
  }

  private mouseInit(button: number, dx = 0, dy = 0): PointerEventInit {
    return {
      bubbles: true,
      cancelable: true,
      composed: true,
      clientX: this.x,
      clientY: this.y,
      screenX: this.x + window.screenX,
      screenY: this.y + window.screenY,
      movementX: dx,
      movementY: dy,
      button,
      buttons: this.buttons,
      pointerId: 1,
      pointerType: "mouse",
      isPrimary: true,
      view: window,
      ...this.mods(),
    };
  }

  private move(x: number, y: number, dx: number, dy: number) {
    const r = this.canvas.getBoundingClientRect();
    this.x = Math.min(r.right - 0.5, Math.max(r.left, x));
    this.y = Math.min(r.bottom - 0.5, Math.max(r.top, y));
    const t = this.downTarget ?? this.target();
    const init = this.mouseInit(-1, Math.round(dx), Math.round(dy));
    t.dispatchEvent(new PointerEvent("pointermove", init));
    t.dispatchEvent(new MouseEvent("mousemove", { ...init, button: 0 }));
    this.stats.moves++;
  }

  private button(code: number, down: boolean) {
    const b = domButton[code];
    if (b === undefined) return;
    const bit = buttonsBit[b];
    if (down === ((this.buttons & bit) !== 0)) return;
    const t = down ? this.target() : (this.downTarget ?? this.target());
    if (down) {
      this.buttons |= bit;
      this.downTarget = t;
    } else this.buttons &= ~bit;
    const init = this.mouseInit(b);
    t.dispatchEvent(new PointerEvent(down ? "pointerdown" : "pointerup", init));
    t.dispatchEvent(new MouseEvent(down ? "mousedown" : "mouseup", init));
    if (!down) {
      if (b === 0) t.dispatchEvent(new MouseEvent("click", init));
      if (b === 2) t.dispatchEvent(new MouseEvent("contextmenu", init));
      if (this.buttons === 0) this.downTarget = null;
    }
    this.stats.buttons++;
  }

  private wheel(dx: number, dy: number) {
    // 120 per notch to Chromium's ~100 px per notch (capture.ts does the reverse).
    const init = this.mouseInit(0);
    this.target().dispatchEvent(new WheelEvent("wheel", { ...init, deltaX: (dx * 100) / 120, deltaY: (dy * 100) / 120, deltaMode: 0 }));
    this.stats.scrolls++;
  }

  private pad(a: Extract<Action, { kind: "pad" }>) {
    const hooks = window.__moonsecHost;
    if (!hooks || a.index >= hooks.pads.length) return;
    this.stats.pads++;
    if (!a.connected) return hooks.setPad(a.index, null);
    const prev = hooks.pads[a.index];
    const axis = (v: number) => (v < 0 ? v / 32768 : v / 32767);
    const trig = (v: number) => v / 65535;
    const buttons = standardBits.map((bit, i) => {
      const value = i === 6 ? trig(a.lt) : i === 7 ? trig(a.rt) : bit !== 0 && (a.buttons & bit) !== 0 ? 1 : 0;
      return { pressed: value > 0.5 || (i >= 6 && i <= 7 && value > 0.12), touched: value > 0, value };
    });
    const pad: VirtualPad = {
      id: "moonsec remote pad (STANDARD GAMEPAD Vendor: 045e Product: 028e)",
      index: a.index,
      connected: true,
      mapping: "standard",
      timestamp: performance.now(),
      // DOM axes grow down; the core's Y is up-positive.
      axes: [axis(a.lx), -axis(a.ly), axis(a.rx), -axis(a.ry)],
      buttons,
      vibrationActuator: null,
      hapticActuators: [],
    };
    // A fresh object each update, like Chromium's snapshots; keep the slot's index.
    if (prev) pad.index = prev.index;
    hooks.setPad(a.index, pad);
  }

  /** Release everything held (the client left). */
  releaseAll() {
    for (const code of [...this.held]) {
      const usage = [...Array(0xe8).keys()].find((u) => codeForUsage(u) === code);
      if (usage !== undefined) this.key(usage, false);
    }
    for (const c of [1, 2, 3, 4, 5]) if (this.buttons & buttonsBit[domButton[c]]) this.button(c, false);
    const hooks = window.__moonsecHost;
    if (hooks) for (let i = 0; i < hooks.pads.length; i++) if (hooks.pads[i]) hooks.setPad(i, null);
  }
}
