// Page patches for the browser host, bundled as a classic script (dist/host-patch.js) that
// must run before the game's own scripts: put it first in <head>.
//
//  - Audio: every realtime AudioContext gets a tap bus. Connections to ctx.destination are
//    redirected to the bus, which feeds the real destination and, once the host starts, a
//    tap worklet that copies the mix out (tap-worklet.ts). Contexts are created at 48 kHz
//    unless the game asks for another rate.
//  - Gamepads: navigator.getGamepads() also returns the remote clients' pads (virtual
//    Gamepad objects with the standard mapping) and gamepadconnected/disconnected fire.
//  - Frames: requestAnimationFrame callbacks are wrapped so a capture runs right after the
//    game has drawn a frame (a microtask after its callback), not on a separate clock; when
//    the tab is hidden and rAF stops, a timer runs the game's frames instead.
//
// Everything is reachable from the host module through window.__moonsecHost.

export interface VirtualPad {
  id: string;
  index: number;
  connected: boolean;
  mapping: GamepadMappingType;
  timestamp: number;
  axes: number[];
  buttons: { pressed: boolean; touched: boolean; value: number }[];
  vibrationActuator: null;
  hapticActuators: [];
}

export interface PatchHooks {
  contexts: AudioContext[];
  /** The bus a context's destination-bound nodes are routed into. */
  busOf(ctx: BaseAudioContext): GainNode | null;
  pads: (VirtualPad | null)[];
  setPad(slot: number, pad: VirtualPad | null): void;
  /** Called after each animation frame the game drew. */
  onFrame: ((t: number) => void) | null;
  lastFrameAt: number;
  nativeRaf: typeof requestAnimationFrame;
  /** Animation frames run from the watchdog timer because the native rAF had stopped. */
  timerFrames: number;
  onContext: ((ctx: AudioContext) => void) | null;
  /** AudioNode.connect before the patch (for wiring the tap without the redirect). */
  nativeConnect: (from: AudioNode, to: AudioNode) => void;
}

declare global {
  interface Window {
    __moonsecHost: PatchHooks;
    webkitAudioContext?: typeof AudioContext;
  }
}

(() => {
  if (window.__moonsecHost) return;
  const buses = new WeakMap<BaseAudioContext, GainNode>();
  const hooks: PatchHooks = {
    contexts: [],
    busOf: (ctx) => buses.get(ctx) ?? null,
    pads: [null, null, null, null],
    setPad(slot, pad) {
      const before = hooks.pads[slot];
      hooks.pads[slot] = pad;
      const fire = (type: string, gp: VirtualPad) => {
        const ev = new Event(type);
        Object.defineProperty(ev, "gamepad", { value: gp });
        window.dispatchEvent(ev);
      };
      if (pad && !before) fire("gamepadconnected", pad);
      if (!pad && before) fire("gamepaddisconnected", { ...before, connected: false });
    },
    onFrame: null,
    lastFrameAt: 0,
    nativeRaf: window.requestAnimationFrame.bind(window),
    timerFrames: 0,
    onContext: null,
    nativeConnect: (from, to) => void from.connect(to),
  };
  window.__moonsecHost = hooks;

  // --- audio ---------------------------------------------------------------------------
  const Native = window.AudioContext ?? window.webkitAudioContext;
  if (Native) {
    const nativeConnect = AudioNode.prototype.connect as (this: AudioNode, ...a: unknown[]) => unknown;
    const nativeDisconnect = AudioNode.prototype.disconnect as (this: AudioNode, ...a: unknown[]) => unknown;
    hooks.nativeConnect = (from, to) => void nativeConnect.call(from, to);
    const Patched = class extends Native {
      constructor(opts?: AudioContextOptions) {
        super({ sampleRate: 48000, ...(opts ?? {}) });
        const bus = this.createGain();
        nativeConnect.call(bus, this.destination);
        buses.set(this, bus);
        hooks.contexts.push(this);
        hooks.onContext?.(this);
      }
    };
    window.AudioContext = Patched;
    if (window.webkitAudioContext) window.webkitAudioContext = Patched;
    AudioNode.prototype.connect = function (this: AudioNode, ...a: unknown[]) {
      const bus = buses.get(this.context);
      if (bus && a[0] === this.context.destination && this !== bus) {
        nativeConnect.call(this, bus, ...a.slice(1));
        return a[0];
      }
      return nativeConnect.apply(this, a);
    } as typeof AudioNode.prototype.connect;
    AudioNode.prototype.disconnect = function (this: AudioNode, ...a: unknown[]) {
      const bus = buses.get(this.context);
      if (bus && a[0] === this.context.destination && this !== bus) return nativeDisconnect.call(this, bus, ...a.slice(1));
      return nativeDisconnect.apply(this, a);
    } as typeof AudioNode.prototype.disconnect;
  }

  // --- gamepads ----------------------------------------------------------------------------
  const nativeGetGamepads = navigator.getGamepads?.bind(navigator);
  navigator.getGamepads = function () {
    const real = nativeGetGamepads ? Array.from(nativeGetGamepads()) : [];
    const out: (Gamepad | null)[] = [];
    const n = Math.max(4, real.length);
    // Remote pads take slots no local pad uses, lowest first.
    let v = 0;
    for (let i = 0; i < n; i++) {
      if (real[i]) out.push(real[i]);
      else {
        while (v < hooks.pads.length && !hooks.pads[v]) v++;
        const p = v < hooks.pads.length ? hooks.pads[v++] : null;
        if (p) p.index = i;
        out.push(p as unknown as Gamepad | null);
      }
    }
    return out;
  } as typeof navigator.getGamepads;

  // --- frames -------------------------------------------------------------------------------
  // Callbacks run from the native rAF. While the host runs (`onFrame` set), a watchdog also
  // runs them from a timer when the native rAF has stopped: Chromium stops rAF in a hidden
  // tab, but a tab playing audio keeps its timers, so the game and the stream keep going
  // when the host's tab is in the background.
  let captureQueued = false;
  let nativeFiredAt = performance.now();
  let nextId = 1;
  const queued = new Map<number, { cb: FrameRequestCallback; native: number }>();
  const afterFrame = () => {
    if (!captureQueued && hooks.onFrame) {
      captureQueued = true;
      queueMicrotask(() => {
        captureQueued = false;
        hooks.lastFrameAt = performance.now();
        hooks.onFrame?.(performance.now());
      });
    }
  };
  const run = (id: number, t: number) => {
    const q = queued.get(id);
    if (!q) return;
    queued.delete(id);
    try {
      q.cb(t);
    } finally {
      afterFrame();
    }
  };
  const nativeCancel = window.cancelAnimationFrame.bind(window);
  window.requestAnimationFrame = function (cb: FrameRequestCallback): number {
    const id = nextId++;
    const native = hooks.nativeRaf((t) => {
      nativeFiredAt = performance.now();
      run(id, t);
    });
    queued.set(id, { cb, native });
    return id;
  };
  window.cancelAnimationFrame = function (id: number) {
    const q = queued.get(id);
    if (!q) return;
    queued.delete(id);
    nativeCancel(q.native);
  };
  hooks.timerFrames = 0;
  setInterval(() => {
    if (!hooks.onFrame || performance.now() - nativeFiredAt < 100 || queued.size === 0) return;
    const t = performance.now();
    hooks.timerFrames++;
    for (const id of [...queued.keys()]) run(id, t);
  }, 1000 / 60);
})();
