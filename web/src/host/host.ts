// The browser host on the page: captures the game's canvas (or a video) and audio, runs
// the host worker (core, iroh, pairing, encoders), and injects remote input back into the
// page.
//
//   <script src="dist/host-patch.js"></script>            first in <head>, before the game
//   <script type="module">
//     import { BrowserHost } from "./dist/host.js";
//     const host = await BrowserHost.start({ canvas, relayUrls: ["https://relay.example"] });
//     host.invite();                                      // a pairing window: link, QR, PIN
//     host.onReport = (r) => show(r.invite);
//   </script>
//
// Only paired devices get a session (spec/pairing-v0.md). The host's identity (its endpoint
// key) and its allowlist persist in `storage` (localStorage by default), so a device paired
// once reconnects with the plain address ticket. The page the game runs in can read that
// storage; a game you host this way is code you trust with the host's identity.

import type { Action, InputPolicy } from "./core";
import { Injector } from "./inject";
import type { FromHostWorker, HostReport, HostStartMsg, InviteOptions, PairedDevice, ToHostWorker } from "./protocol";

export interface HostStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface BrowserHostOptions {
  /** What is streamed: a canvas (the game's) or a video element. */
  canvas: HTMLCanvasElement | HTMLVideoElement;
  relayUrls: string[];
  /** Where host-worker.js, host-tap.js and moonsec-host.wasm are served (default: this module's directory). */
  base?: string;
  /** shim-web's pkg/ (default: ../pkg/ next to base). */
  pkgUrl?: string;
  /** The host's endpoint key (default: kept in `storage`). */
  secretKey?: Uint8Array;
  /** Where the identity and allowlist are kept (default localStorage; keys start with `storageKey`). */
  storage?: HostStorage | null;
  storageKey?: string;
  /** Name shown to clients that pair (default: the page title). */
  name?: string;
  /** Whose input applies: "everyone" (default; every member may play), "owner" (one at a time), "view". */
  input?: InputPolicy;
  /** Members at once (default 8, at most 32). */
  maxMembers?: number;
  fps?: number;
  bitrateBps?: number;
  codecs?: string[];
  audio?: boolean;
  /** Also stream the sound of <audio> and <video> elements (default true; same-origin or CORS media only). */
  mediaElements?: boolean;
  audioEncoder?: "wasm" | "webcodecs";
  /** "raf": a frame right after each animation frame the game draws (patch.ts); "stream": captureStream. */
  capture?: "raf" | "stream";
  rateControl?: boolean;
  /** Long-term references (needs Chromium's WebCodecsVideoEncoderBuffers feature; off without it). */
  ltr?: boolean;
  /** Test only: drop this share of host-to-client datagrams. */
  loss?: number;
  /** Test only: drop every host-to-client datagram for this many ms every 3 s. */
  outageMs?: number;
  onReport?: (r: HostReport) => void;
  onPaired?: (d: PairedDevice) => void;
  onError?: (message: string) => void;
}

const absUs = () => (performance.timeOrigin + performance.now()) * 1000;
const toHex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const fromHex = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (x) => parseInt(x, 16));

function defaultStorage(): HostStorage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export interface MediaStats {
  routed: number;
  /** Not routed: cross-origin without CORS (it would go silent) or a MediaStream. */
  skipped: number;
}

export class BrowserHost {
  readonly worker: Worker;
  readonly injector: Injector;
  report: HostReport | null = null;
  captured = 0;
  skipped = 0;
  media: MediaStats = { routed: 0, skipped: 0 };
  onReport: ((r: HostReport) => void) | null = null;
  private tapPort: MessagePort | null = null;
  private tapContext: AudioContext | null = null;
  private routed = new WeakSet<HTMLMediaElement>();
  private lastCapture = 0;
  private interval: number;
  private storage: HostStorage | null;
  private key: string;
  private allow: PairedDevice[];

  private constructor(
    private o: BrowserHostOptions,
    worker: Worker,
  ) {
    this.worker = worker;
    this.injector = new Injector(o.canvas);
    this.interval = 1000 / (o.fps ?? 60);
    this.storage = o.storage === undefined ? defaultStorage() : o.storage;
    this.key = o.storageKey ?? "moonsec.host";
    this.allow = this.loadAllowlist();
  }

  static async start(o: BrowserHostOptions): Promise<BrowserHost> {
    const hooks = window.__moonsecHost;
    if (!hooks) throw new Error("host-patch.js must load before the game (first script in <head>)");
    const base = o.base ?? new URL(".", import.meta.url).href;
    const worker = new Worker(new URL("host-worker.js", base), { type: "module" });
    const h = new BrowserHost(o, worker);
    h.onReport = o.onReport ?? null;
    worker.onmessage = (ev: MessageEvent<FromHostWorker>) => h.onMessage(ev.data);
    worker.onerror = (e) => o.onError?.(e.message);

    let audioPort: MessagePort | null = null;
    if (o.audio !== false) {
      const ch = new MessageChannel();
      audioPort = ch.port2;
      h.tapPort = ch.port1;
      // The first AudioContext the page makes is the one streamed (often created on a click).
      const tap = (ctx: AudioContext) => void h.attachTap(ctx, base);
      if (hooks.contexts.length > 0) tap(hooks.contexts[0]);
      else
        hooks.onContext = (ctx) => {
          hooks.onContext = null;
          tap(ctx);
        };
      if (o.mediaElements !== false) {
        hooks.onMediaPlay = (el) => h.routeMedia(el);
        for (const ref of hooks.media) {
          const el = ref.deref();
          if (el && !el.paused) h.routeMedia(el);
        }
      }
    }
    const c = o.canvas;
    const isVideo = c instanceof HTMLVideoElement;
    const start: HostStartMsg = {
      type: "start",
      wasmUrl: new URL("moonsec-host.wasm", base).href,
      pkgUrl: o.pkgUrl ?? new URL("../pkg/", base).href,
      relayUrls: o.relayUrls,
      secretKey: o.secretKey ?? h.identityKey(),
      name: o.name ?? (document.title || "moonsec browser host"),
      allowlist: h.allow,
      policy: o.input ?? "everyone",
      maxMembers: Math.min(32, o.maxMembers ?? 8),
      width: isVideo ? c.videoWidth || c.width || 1280 : c.width,
      height: isVideo ? c.videoHeight || c.height || 720 : c.height,
      fps: o.fps ?? 60,
      bitrateBps: o.bitrateBps ?? 6_000_000,
      codecs: o.codecs ?? ["h264", "av1"],
      audio: audioPort,
      audioEncoder: o.audioEncoder ?? "wasm",
      rateControl: o.rateControl ?? false,
      ltr: o.ltr ?? true,
      loss: o.loss ?? 0,
      outageMs: o.outageMs ?? 0,
    };
    worker.postMessage(start, audioPort ? [audioPort] : []);
    if ((o.capture ?? "raf") === "raf") h.captureOnFrames();
    else void h.captureStream();
    return h;
  }

  // --- identity and pairing ------------------------------------------------------------

  private identityKey(): Uint8Array | null {
    const s = this.storage;
    if (!s) return null;
    const k = `${this.key}.key`;
    const have = s.getItem(k);
    if (have && /^[0-9a-f]{64}$/.test(have)) return fromHex(have);
    const key = crypto.getRandomValues(new Uint8Array(32));
    try {
      s.setItem(k, toHex(key));
    } catch {
      /* not persisted: a new identity next time */
    }
    return key;
  }

  private loadAllowlist(): PairedDevice[] {
    try {
      const v = JSON.parse(this.storage?.getItem(`${this.key}.clients`) ?? "[]");
      return Array.isArray(v) ? v.filter((d) => typeof d?.id === "string" && /^[0-9a-f]{64}$/.test(d.id)) : [];
    } catch {
      return [];
    }
  }

  private saveAllowlist() {
    try {
      this.storage?.setItem(`${this.key}.clients`, JSON.stringify(this.allow));
    } catch {
      /* not persisted */
    }
    this.worker.postMessage({ type: "allowlist", allowlist: this.allow } satisfies ToHostWorker);
  }

  /** Devices that may start sessions. */
  get paired(): PairedDevice[] {
    return [...this.allow];
  }

  /** Opens a pairing window: the report's `invite` then has the link's ticket, its QR code and the PIN. */
  invite(o: InviteOptions = {}) {
    this.worker.postMessage({ type: "invite", ...o } satisfies ToHostWorker);
  }

  closeInvite() {
    this.worker.postMessage({ type: "invite-close" } satisfies ToHostWorker);
  }

  /** Removes a device from the allowlist; its session, if any, ends now. */
  forget(id: string) {
    this.allow = this.allow.filter((d) => d.id !== id);
    this.saveAllowlist();
  }

  /** Lets a paired device's input apply, or makes it view only (from its next session). */
  setInput(id: string, input: boolean) {
    this.allow = this.allow.map((d) => (d.id === id ? { ...d, input } : d));
    this.saveAllowlist();
  }

  /** Ends a member's session (it may come back while it is still paired). */
  kick(id: string) {
    this.worker.postMessage({ type: "kick", id } satisfies ToHostWorker);
  }

  // --- audio ---------------------------------------------------------------------------

  private async attachTap(ctx: AudioContext, base: string) {
    const hooks = window.__moonsecHost;
    const bus = hooks.busOf(ctx);
    if (!bus || !this.tapPort) return;
    this.tapContext = ctx;
    // WebKit can leave a context "interrupted" (no audio session yet), and then nothing
    // reaches the tap. Resume it while it is, and on the host user's next gesture.
    const revive = () => {
      const st = ctx.state as string;
      if (st === "interrupted" || (st === "suspended" && navigator.userActivation?.hasBeenActive !== false)) ctx.resume().catch(() => {});
    };
    setInterval(revive, 500);
    for (const t of ["pointerdown", "keydown"]) addEventListener(t, revive, { capture: true });
    await ctx.audioWorklet.addModule(new URL("host-tap.js", base));
    const node = new AudioWorkletNode(ctx, "moonsec-tap", { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [2], channelCount: 2, channelCountMode: "explicit" });
    hooks.nativeConnect(bus, node);
    // The tap outputs silence; connecting it keeps it pulled by the graph.
    hooks.nativeConnect(node, ctx.destination);
    node.port.postMessage({ port: this.tapPort }, [this.tapPort]);
    this.tapPort = null;
  }

  /**
   * Routes a media element's sound through the tapped context, so it streams and still
   * plays here. A page with no AudioContext of its own gets one for this. Cross-origin
   * media without CORS is left alone: Web Audio would only get silence from it, and the
   * element would go quiet here too.
   */
  routeMedia(el: HTMLMediaElement) {
    if (this.routed.has(el)) return;
    const src = el.currentSrc || el.src;
    let crossOrigin = false;
    try {
      const u = new URL(src, location.href);
      crossOrigin = (u.protocol === "http:" || u.protocol === "https:") && u.origin !== location.origin && el.crossOrigin === null;
    } catch {
      /* no src yet */
    }
    if (el.srcObject || crossOrigin) {
      this.media.skipped++;
      this.routed.add(el);
      return;
    }
    const hooks = window.__moonsecHost;
    let ctx = this.tapContext ?? hooks.contexts[0];
    if (!ctx) {
      // The patched constructor taps it (hooks.onContext).
      ctx = new AudioContext();
      void ctx.resume().catch(() => {});
    }
    try {
      const node = ctx.createMediaElementSource(el);
      node.connect(ctx.destination); // into the bus (patch.ts)
      this.routed.add(el);
      this.media.routed++;
    } catch {
      // Already wired to another context by the page itself.
      this.routed.add(el);
      this.media.skipped++;
    }
  }

  // --- video -----------------------------------------------------------------------------

  private captureOnFrames() {
    const hooks = window.__moonsecHost;
    hooks.onFrame = () => this.capture();
    // Games that draw from timers, a video, or a page whose rAF is throttled: capture on a
    // timer when no animation frame has come for a while.
    setInterval(() => {
      if (performance.now() - hooks.lastFrameAt > 100) this.capture();
    }, this.interval);
  }

  private capture() {
    const now = performance.now();
    // At most `fps`: a 120 Hz display runs rAF twice per encoded frame.
    if (now - this.lastCapture < this.interval * 0.75) {
      this.skipped++;
      return;
    }
    this.lastCapture = now;
    const t0 = absUs();
    let frame: VideoFrame;
    try {
      frame = new VideoFrame(this.o.canvas, { timestamp: t0 });
    } catch {
      return; // a canvas with nothing drawn yet, or a video with no frame
    }
    this.captured++;
    this.worker.postMessage({ type: "frame", frame, captureStartUs: t0, capturedUs: absUs() } satisfies ToHostWorker, [frame]);
  }

  private async captureStream() {
    const src = this.o.canvas as HTMLCanvasElement & { captureStream(fps?: number): MediaStream };
    const track = src.captureStream(this.o.fps ?? 60).getVideoTracks()[0];
    const Proc = (window as unknown as { MediaStreamTrackProcessor?: new (o: { track: MediaStreamTrack }) => { readable: ReadableStream<VideoFrame> } }).MediaStreamTrackProcessor;
    if (!Proc) throw new Error('no MediaStreamTrackProcessor: use capture: "raf"');
    const reader = new Proc({ track }).readable.getReader();
    for (;;) {
      const { value: frame, done } = await reader.read();
      if (done || !frame) return;
      const t = absUs();
      this.captured++;
      this.worker.postMessage({ type: "frame", frame, captureStartUs: t, capturedUs: t } satisfies ToHostWorker, [frame]);
    }
  }

  // --- worker --------------------------------------------------------------------------------

  private onMessage(m: FromHostWorker) {
    if (m.type === "error") return this.o.onError?.(m.message);
    if (m.type === "actions") return this.inject(m.actions);
    if (m.type === "left") return this.injector.releaseMember(m.id);
    if (m.type === "paired") {
      this.allow = [...this.allow.filter((d) => d.id !== m.device.id), m.device];
      this.saveAllowlist();
      this.o.onPaired?.(m.device);
      return;
    }
    if (this.report?.state === "streaming" && m.state !== "streaming" && m.members.length === 0) this.injector.releaseAll();
    this.report = m;
    this.onReport?.(m);
  }

  private inject(actions: Action[]) {
    const times: number[] = [];
    const from: number[] = [];
    for (const a of actions) {
      this.injector.apply(a);
      times.push(a.time);
      from.push(a.from);
    }
    this.worker.postMessage({ type: "injected", times, from, at: absUs() } satisfies ToHostWorker);
  }

  close() {
    this.worker.postMessage({ type: "close" } satisfies ToHostWorker);
  }
}
