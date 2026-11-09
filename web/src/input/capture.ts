// Browser input capture: DOM keyboard, mouse and wheel events, Pointer Lock, Keyboard
// Lock and Gamepad API polling, turned into calls on an InputSink (the wasm core).
//
// What each browser gives us, and the fallback when it doesn't:
//
// - Pointer Lock with `unadjustedMovement` (raw, unaccelerated deltas): Chromium on
//   Windows, macOS and ChromeOS. Elsewhere `requestPointerLock` rejects with
//   NotSupportedError (or ignores the option), and we lock without it: deltas then carry
//   OS acceleration. Firefox and Safari lock without the option.
// - No Pointer Lock at all, or the user declined it, or `mode: "absolute"`: absolute
//   positions mapped onto the video (0..65535), which suits desktop use anyway.
// - Keyboard Lock (`navigator.keyboard.lock()`): Chromium, only in fullscreen. It lets
//   Esc, Alt+Tab, Cmd/Win and browser shortcuts reach the host. Without it the browser
//   keeps those keys; everything else is still captured.
// - Gamepad API: everywhere, but Firefox and Safari only expose a pad after a button
//   press, and only Chromium reliably fires `gamepadconnected` for pads already plugged
//   in, so we poll `getGamepads()` for discovery as well as for state.

import { InputSink, nowUs } from "./core.js";
import { PadSlots, PadState, readPad, samePad } from "./gamepad.js";
import { hidUsage, hidUsageFromKeyCode } from "./hid.js";

export type MouseMode = "auto" | "relative" | "absolute";

export interface Capabilities {
  pointerLock: boolean;
  /** null until a lock has been tried; then whether raw deltas were granted. */
  unadjustedMovement: boolean | null;
  keyboardLock: boolean;
  fullscreen: boolean;
  gamepad: boolean;
}

export interface CaptureOptions {
  /** auto: lock the pointer on click, absolute until then. Default auto. */
  mode?: MouseMode;
  /**
   * The rectangle of the video inside the element, in client coordinates, for absolute
   * positions (letterboxing). Default: the element's bounding rectangle.
   */
  contentRect?: () => DOMRect;
  /** Fast gamepad poll period while a pad is connected. Default 4 ms (250 Hz). */
  padPollMs?: number;
}

/** DOM MouseEvent.button to core button (1 left, 2 right, 3 middle, 4 back, 5 forward). */
const domButton: readonly number[] = [1, 3, 2, 4, 5];

/** Wheel units per notch in core.input. */
const notch = 120;

export function detectCapabilities(): Capabilities {
  const el = typeof HTMLElement !== "undefined" ? HTMLElement.prototype : ({} as HTMLElement);
  const nav = typeof navigator !== "undefined" ? (navigator as Navigator & { keyboard?: { lock?: unknown } }) : undefined;
  return {
    pointerLock: "requestPointerLock" in el,
    unadjustedMovement: null,
    keyboardLock: typeof nav?.keyboard?.lock === "function",
    fullscreen: "requestFullscreen" in el || "webkitRequestFullscreen" in el,
    gamepad: typeof nav?.getGamepads === "function",
  };
}

export class InputCapture {
  readonly caps: Capabilities = detectCapabilities();
  /** Counters for the overlay and tests. */
  readonly stats = { keys: 0, buttons: 0, scrolls: 0, moves: 0, pads: 0, unmappedKeys: 0, lockFailures: 0, relX: 0, relY: 0 };

  private mode: MouseMode;
  private locked = false;
  private keysHeld = new Set<number>();
  private buttonsHeld = new Set<number>();
  private wheelRem = { x: 0, y: 0 };
  private slots = new PadSlots();
  private lastPad: (PadState | null)[] = [null, null, null, null];
  private discoverTimer: ReturnType<typeof setInterval> | null = null;
  private fastTimer: ReturnType<typeof setInterval> | null = null;
  private off: (() => void)[] = [];

  constructor(
    readonly element: HTMLElement,
    private sink: InputSink,
    private opts: CaptureOptions = {},
  ) {
    this.mode = opts.mode ?? "auto";
  }

  get pointerLocked(): boolean {
    return this.locked;
  }

  get mouseMode(): MouseMode {
    return this.mode;
  }

  attach(): void {
    const el = this.element;
    if (el.tabIndex < 0) el.tabIndex = 0; // focusable, so key events reach it
    this.on(el, "mousedown", (e) => this.onMouseButton(e as MouseEvent, true));
    this.on(window, "mouseup", (e) => this.onMouseButton(e as MouseEvent, false));
    this.on(el, "mousemove", (e) => this.onMouseMove(e as MouseEvent));
    this.on(document, "mousemove", (e) => this.locked && this.onMouseMove(e as MouseEvent));
    this.on(el, "wheel", (e) => this.onWheel(e as WheelEvent), { passive: false });
    this.on(el, "contextmenu", (e) => e.preventDefault());
    this.on(el, "keydown", (e) => this.onKey(e as KeyboardEvent, true));
    this.on(el, "keyup", (e) => this.onKey(e as KeyboardEvent, false));
    // While locked, key events target the body in some browsers.
    this.on(document, "keydown", (e) => this.locked && e.target !== el && this.onKey(e as KeyboardEvent, true));
    this.on(document, "keyup", (e) => this.locked && e.target !== el && this.onKey(e as KeyboardEvent, false));
    this.on(window, "blur", () => this.releaseAll());
    this.on(document, "visibilitychange", () => document.hidden && this.releaseAll());
    this.on(document, "pointerlockchange", () => {
      this.locked = document.pointerLockElement === el;
      if (!this.locked) this.releaseAll();
    });
    this.on(document, "pointerlockerror", () => {
      this.stats.lockFailures++;
    });
    this.on(document, "fullscreenchange", () => this.onFullscreenChange());
    if (this.caps.gamepad) {
      this.on(window, "gamepadconnected", () => this.pollPads());
      this.on(window, "gamepaddisconnected", () => this.pollPads());
      this.discoverTimer = setInterval(() => this.pollPads(), 250);
    }
  }

  detach(): void {
    this.releaseAll();
    for (const f of this.off) f();
    this.off = [];
    if (this.discoverTimer !== null) clearInterval(this.discoverTimer);
    if (this.fastTimer !== null) clearInterval(this.fastTimer);
    this.discoverTimer = this.fastTimer = null;
    for (const slot of this.slots.claimed()) this.sink.pad(slot, null);
    this.sink.poke();
    if (this.locked) document.exitPointerLock?.();
  }

  setMode(mode: MouseMode): void {
    this.mode = mode;
    if (mode === "absolute" && this.locked) document.exitPointerLock();
  }

  /**
   * Lock the pointer (must run in a user gesture). Tries raw deltas first and falls back
   * to a plain lock. Resolves to whether the pointer ended up locked.
   */
  async lockPointer(): Promise<boolean> {
    if (!this.caps.pointerLock) return false;
    const el = this.element as HTMLElement & {
      requestPointerLock(opts?: { unadjustedMovement?: boolean }): Promise<void> | void;
    };
    const settle = () =>
      new Promise<boolean>((resolve) => {
        if (document.pointerLockElement === el) return resolve(true);
        const done = (ok: boolean) => {
          document.removeEventListener("pointerlockchange", onChange);
          document.removeEventListener("pointerlockerror", onError);
          clearTimeout(t);
          resolve(ok);
        };
        const onChange = () => done(document.pointerLockElement === el);
        const onError = () => done(false);
        document.addEventListener("pointerlockchange", onChange);
        document.addEventListener("pointerlockerror", onError);
        const t = setTimeout(() => done(document.pointerLockElement === el), 1000);
      });
    try {
      const p = el.requestPointerLock({ unadjustedMovement: true });
      if (p && typeof (p as Promise<void>).then === "function") {
        await p;
        this.caps.unadjustedMovement = true;
        return settle();
      }
      // No promise (Firefox, Safari): the option was ignored.
      this.caps.unadjustedMovement = false;
      return settle();
    } catch (err) {
      this.caps.unadjustedMovement = false;
      if ((err as DOMException)?.name !== "NotSupportedError") {
        this.stats.lockFailures++;
        return false;
      }
    }
    try {
      await el.requestPointerLock();
      return settle();
    } catch {
      this.stats.lockFailures++;
      return false;
    }
  }

  /** Fullscreen the element and, where supported, lock the keyboard (user gesture). */
  async enterFullscreen(): Promise<{ fullscreen: boolean; keyboardLocked: boolean }> {
    const el = this.element as HTMLElement & { webkitRequestFullscreen?: () => void };
    try {
      if (el.requestFullscreen) await el.requestFullscreen({ navigationUI: "hide" });
      else el.webkitRequestFullscreen?.();
    } catch {
      return { fullscreen: false, keyboardLocked: false };
    }
    return { fullscreen: true, keyboardLocked: await this.lockKeyboard() };
  }

  private async lockKeyboard(): Promise<boolean> {
    const kb = (navigator as Navigator & { keyboard?: { lock(codes?: string[]): Promise<void> } }).keyboard;
    if (!kb?.lock || !document.fullscreenElement) return false;
    try {
      await kb.lock();
      return true;
    } catch {
      return false;
    }
  }

  private onFullscreenChange(): void {
    const kb = (navigator as Navigator & { keyboard?: { unlock?(): void } }).keyboard;
    if (!document.fullscreenElement) kb?.unlock?.();
  }

  // --- events -----------------------------------------------------------

  private on(target: EventTarget, type: string, fn: (e: Event) => void, opts?: AddEventListenerOptions): void {
    target.addEventListener(type, fn, opts);
    this.off.push(() => target.removeEventListener(type, fn, opts));
  }

  private eventTime(e: Event): number {
    // DOM timeStamps share performance.now()'s origin; clamp in case a browser stamps
    // with a coarser or later clock.
    const t = e.timeStamp > 0 ? e.timeStamp * 1000 : nowUs();
    return Math.min(t, nowUs());
  }

  private onKey(e: KeyboardEvent, down: boolean): void {
    let code = hidUsage(e.code);
    if (code === 0 && !e.code) code = hidUsageFromKeyCode(e.keyCode);
    if (code === 0) {
      this.stats.unmappedKeys++;
      return;
    }
    e.preventDefault();
    e.stopPropagation();
    if (down) this.keysHeld.add(code);
    else if (!this.keysHeld.delete(code)) return; // release of a key pressed before we had focus
    this.stats.keys++;
    this.sink.key(code, down, this.eventTime(e));
    this.sink.poke();
  }

  private onMouseButton(e: MouseEvent, down: boolean): void {
    const code = domButton[e.button] ?? 0;
    if (code === 0) return;
    if (down) {
      this.element.focus({ preventScroll: true });
      if (!this.locked && this.mode !== "absolute") {
        // A click locks the pointer. In relative mode it is not forwarded (the user
        // was aiming at the stream, not at the host); in auto mode it lands where the
        // user clicked.
        if (this.mode === "relative" || (this.mode === "auto" && this.caps.pointerLock)) {
          e.preventDefault();
          void this.lockPointer();
          if (this.mode === "relative") return;
        }
      }
      if (!this.locked) this.sendAbs(e);
      this.buttonsHeld.add(code);
    } else if (!this.buttonsHeld.delete(code)) {
      return;
    }
    e.preventDefault();
    this.stats.buttons++;
    this.sink.button(code, down, this.eventTime(e));
    this.sink.poke();
  }

  private onMouseMove(e: MouseEvent): void {
    if (this.locked) {
      const dx = Math.round(e.movementX);
      const dy = Math.round(e.movementY);
      if (dx === 0 && dy === 0) return;
      this.stats.relX += dx;
      this.stats.relY += dy;
      this.sink.moveRel(dx, dy);
    } else if (this.mode !== "relative") {
      this.sendAbs(e);
    } else {
      return;
    }
    this.stats.moves++;
    this.sink.poke();
  }

  private sendAbs(e: MouseEvent): void {
    const r = this.opts.contentRect?.() ?? this.element.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return;
    const fx = (e.clientX - r.left) / r.width;
    const fy = (e.clientY - r.top) / r.height;
    const to = (f: number) => Math.round(Math.min(1, Math.max(0, f)) * 65535);
    this.sink.moveAbs(to(fx), to(fy));
  }

  private onWheel(e: WheelEvent): void {
    e.preventDefault();
    // To 120 per notch: lines are 3 per notch on most systems, pixels ~100 per notch
    // (Chromium, Safari); pages count as one notch each.
    const scale = e.deltaMode === 1 ? notch / 3 : e.deltaMode === 2 ? notch : notch / 100;
    this.wheelRem.x += e.deltaX * scale;
    this.wheelRem.y += e.deltaY * scale;
    const dx = Math.trunc(this.wheelRem.x);
    const dy = Math.trunc(this.wheelRem.y);
    if (dx === 0 && dy === 0) return;
    this.wheelRem.x -= dx;
    this.wheelRem.y -= dy;
    if (!this.locked && this.mode !== "relative") this.sendAbs(e);
    this.stats.scrolls++;
    this.sink.scroll(dx, dy, this.eventTime(e));
    this.sink.poke();
  }

  /** Release everything held: we won't see the key-ups once focus is gone. */
  private releaseAll(): void {
    const t = nowUs();
    let any = false;
    for (const k of this.keysHeld) {
      this.sink.key(k, false, t);
      any = true;
    }
    for (const b of this.buttonsHeld) {
      this.sink.button(b, false, t);
      any = true;
    }
    this.keysHeld.clear();
    this.buttonsHeld.clear();
    if (any) this.sink.poke();
  }

  // --- gamepads ---------------------------------------------------------

  /** Read every pad; called on discovery and, while any is connected, every padPollMs. */
  pollPads(): void {
    const pads = navigator.getGamepads?.() ?? [];
    const seen = new Set<number>();
    let changed = false;
    for (const gp of pads) {
      if (!gp || !gp.connected) continue;
      seen.add(gp.index);
      const slot = this.slots.claim(gp.index);
      if (slot < 0) continue; // all four slots taken
      const st = readPad(gp);
      const last = this.lastPad[slot];
      if (last && samePad(last, st)) continue;
      this.lastPad[slot] = st;
      this.sink.pad(slot, st);
      this.stats.pads++;
      changed = true;
    }
    for (const slot of this.slots.claimed()) {
      const idx = this.slots.idAt(slot);
      if (idx !== null && !seen.has(idx)) {
        this.slots.release(idx);
        this.lastPad[slot] = null;
        this.sink.pad(slot, null);
        changed = true;
      }
    }
    if (changed) this.sink.poke();
    const any = this.slots.claimed().length > 0;
    if (any && this.fastTimer === null) this.fastTimer = setInterval(() => this.pollPads(), this.opts.padPollMs ?? 4);
    if (!any && this.fastTimer !== null) {
      clearInterval(this.fastTimer);
      this.fastTimer = null;
    }
  }
}
