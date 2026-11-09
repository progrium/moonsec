// The media worker: owns the Zig core's client session, the transport, the WebCodecs
// decoder and the OffscreenCanvas (docs/design.md, "Web client").
//
// Video: every frame the core hands out is decoded at once and drawn in the output
// callback, then closed; nothing waits in a queue. The core holds frames back after a
// gap until the recovery frame (core/recovery), so the decoder never sees a frame whose
// reference is missing; a decoder error is reported as a failed decode, the decoder is
// rebuilt, and frames are failed until the next keyframe, so recovery asks for one.
//
// Audio: the worklet asks for a frame whenever its queue runs low; the worker renders
// one from the core's jitter buffer (spec/audio-v0.md: 20 ms target) and posts it.

import { CoreSession, State } from "../core";
import { WebSocketTransport, type Transport } from "../transport";
import { codecString, probeDecoders, type DecoderSupport } from "./codec";
import type { AudioReport, FromWorker, IrohDial, InputOp, NeedMsg, PcmMsg, ProbeEvent, StartMsg, ToWorker, VideoReport } from "./protocol";
import { IrohTransport } from "../../../shim-web/js/transport.js";
import { loadPair, PairError } from "../../../shim-web/js/pair.js";

declare const self: DedicatedWorkerGlobalScope;

const nowUs = () => performance.now() * 1000;

/** At most this many frames inside the decoder: one decoding, one arriving. */
const maxInDecoder = 2;
/** How far audio rendering may run ahead of the worker's clock. */
const audioLeadUs = 40_000;
/** How often the page gets a stats message while the session runs. */
const reportEveryUs = 250_000;

class Media {
  core: CoreSession;
  transport: Transport;
  canvas: OffscreenCanvas;
  ctx: OffscreenCanvasRenderingContext2D;
  support: DecoderSupport;
  relayed: boolean;
  decoder: VideoDecoder | null = null;
  needKey = true;
  /** frame id -> when decode() was called. */
  inflight = new Map<number, number>();
  timer: ReturnType<typeof setTimeout> | null = null;
  stepScheduled = false;
  ended = false;
  streamingSince = 0;
  /** When the last stats message went to the page (µs). */
  reportedAt = 0;
  seconds: number;
  video: VideoReport = { codec: null, hardware: "", configured: 0, submitted: 0, decoded: 0, drawn: 0, failed: 0, errors: [], decodeMs: [], drawMs: [], nonBlank: false };
  audio: AudioReport = { rendered: 0, paced: 0, played: 0, loud: 0, underruns: 0, queued: 0, sampleRate: 0 };
  audioPort: MessagePort | null;
  /** When the first audio frame was rendered, and how much audio has been since (µs). */
  audioStartUs = 0;
  audioPlayedUs = 0;
  probe: { x: number; y: number } | null;
  probeLight: boolean | null = null;
  probeEvents: ProbeEvent[] = [];

  constructor(core: CoreSession, transport: Transport, m: StartMsg, support: DecoderSupport) {
    this.core = core;
    this.transport = transport;
    this.canvas = m.canvas;
    this.ctx = m.canvas.getContext("2d", { alpha: false, desynchronized: true } as CanvasRenderingContext2DSettings) as OffscreenCanvasRenderingContext2D;
    this.support = support;
    this.relayed = m.relayed;
    this.seconds = m.seconds;
    this.audioPort = m.audio;
    this.probe = m.probe ?? null;
    core.setPath({ rttUs: 0, relayed: m.relayed, pathEpoch: 0, connEpoch: 0, connected: true });
    transport.onDatagram = (dg) => {
      if (!core.push(dg, nowUs())) return;
      this.schedule();
    };
    if (this.audioPort) this.audioPort.onmessage = (ev: MessageEvent<NeedMsg>) => this.onNeed(ev.data);
    // Stats go out from step() while it runs (below), and from this interval while it
    // doesn't: WebKit starves a worker's interval while the step timer keeps being re-armed
    // (Playwright's WebKit never fired it during a stream), so the interval alone left the
    // page without stats until the session ended.
    setInterval(() => this.reportIfDue(), reportEveryUs / 1000);
    this.step();
  }

  /** One step per burst of arrivals: after the current task, before timers. */
  schedule() {
    if (this.stepScheduled) return;
    this.stepScheduled = true;
    queueMicrotask(() => {
      this.stepScheduled = false;
      this.step();
    });
  }

  step() {
    if (this.ended) return;
    const now = nowUs();
    this.core.step(now);
    this.reportIfDue(now);
    const state = this.core.state;
    if (state === State.streaming) {
      if (this.streamingSince === 0) this.streamingSince = now;
      if (this.seconds > 0 && now - this.streamingSince > this.seconds * 1e6) this.core.close(now);
      this.pumpVideo();
    }
    if (this.core.state === State.ended) return this.finish();
    if (this.timer !== null) clearTimeout(this.timer);
    const wake = this.core.nextWake(now);
    this.timer = setTimeout(() => {
      this.timer = null;
      this.step();
    }, Math.max(0, (wake - nowUs()) / 1000));
  }

  finish() {
    this.ended = true;
    this.report();
    this.transport.close();
    this.decoder?.close();
  }

  // --- video ---------------------------------------------------------------

  pumpVideo() {
    while (!this.decoder || this.decoder.decodeQueueSize + this.inflight.size < maxInDecoder + 1) {
      const f = this.core.nextFrame();
      if (!f) return;
      const now = nowUs();
      if (this.needKey) {
        if (!f.keyframe || !this.configure(f.codec, f.data)) {
          // No decoder state to decode a delta frame against: fail it, and recovery
          // asks the host for a keyframe.
          this.video.failed++;
          this.core.onDecoded(f.frameId, false, now);
          continue;
        }
        this.needKey = false;
      }
      // EncodedVideoChunk copies the bytes out of wasm memory.
      const chunk = new EncodedVideoChunk({ type: f.keyframe ? "key" : "delta", timestamp: f.frameId, data: f.data });
      this.inflight.set(f.frameId, now);
      this.video.submitted++;
      try {
        this.decoder!.decode(chunk);
      } catch (e) {
        this.onDecodeError(e);
      }
    }
  }

  configure(codec: number, au: Uint8Array): boolean {
    const s = codecString(codec, au);
    if (!s) return false;
    const cfg = this.core.config();
    const name = codec === 1 ? "h264" : codec === 2 ? "hevc" : "av1";
    const hardwareAcceleration = this.support.hardware[name] ?? "no-preference";
    this.decoder?.close();
    this.inflight.clear();
    this.decoder = new VideoDecoder({ output: (frame) => this.onOutput(frame), error: (e) => this.onDecodeError(e) });
    // No description: the chunks are Annex B (H.264/HEVC) or OBUs (AV1).
    this.decoder.configure({ codec: s, optimizeForLatency: true, hardwareAcceleration, codedWidth: cfg?.width, codedHeight: cfg?.height });
    this.video.codec = s;
    this.video.hardware = hardwareAcceleration;
    this.video.configured++;
    return true;
  }

  onOutput(frame: VideoFrame) {
    const id = frame.timestamp;
    const decodedAt = nowUs();
    const calledAt = this.inflight.get(id);
    this.inflight.delete(id);
    this.core.onDecoded(id, true, decodedAt);
    this.video.decoded++;
    if (calledAt !== undefined) this.video.decodeMs.push((decodedAt - calledAt) / 1000);
    if (this.canvas.width !== frame.displayWidth || this.canvas.height !== frame.displayHeight) {
      this.canvas.width = frame.displayWidth;
      this.canvas.height = frame.displayHeight;
    }
    this.ctx.drawImage(frame, 0, 0);
    frame.close();
    const presentedAt = nowUs();
    this.core.onPresented(id, presentedAt);
    if (this.probe) {
      const px = this.ctx.getImageData(this.probe.x, this.probe.y, 1, 1).data;
      const light = px[0] + px[1] + px[2] > 384;
      if (light !== this.probeLight) {
        this.probeLight = light;
        this.probeEvents.push({ at: presentedAt + performance.timeOrigin * 1000, light, frameId: id });
      }
    }
    this.video.drawn++;
    this.video.drawMs.push((presentedAt - decodedAt) / 1000);
    if (!this.video.nonBlank && this.video.drawn % 30 === 0) {
      const px = this.ctx.getImageData(this.canvas.width >> 1, this.canvas.height >> 1, 8, 8).data;
      for (let i = 0; i < px.length; i += 4) if (px[i] + px[i + 1] + px[i + 2] > 60) this.video.nonBlank = true;
    }
    this.schedule();
  }

  onDecodeError(e: unknown) {
    const msg = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
    if (this.video.errors.length < 10) this.video.errors.push(msg);
    const now = nowUs();
    for (const id of this.inflight.keys()) {
      this.video.failed++;
      this.core.onDecoded(id, false, now);
    }
    this.inflight.clear();
    if (this.decoder && this.decoder.state !== "closed") this.decoder.close();
    this.decoder = null;
    this.needKey = true;
    this.schedule();
  }

  // --- audio ---------------------------------------------------------------

  onNeed(m: NeedMsg) {
    this.audio.played = m.played;
    this.audio.loud = m.loud;
    this.audio.underruns = m.underruns;
    this.audio.queued = m.queued;
    this.audio.sampleRate = m.sampleRate;
    const now = nowUs();
    // Never pull ahead of real time by more than `audioLead`: a browser that delivers the
    // worklet's requests in bursts (WebKit) would otherwise drain the jitter buffer ahead
    // of the network and turn every frame into concealment. The worklet asks again.
    let pcm: Float32Array | null = null;
    const due = this.audioStartUs === 0 || this.audioPlayedUs <= now - this.audioStartUs + audioLeadUs;
    if (!this.ended && due) pcm = this.core.renderAudio(now);
    if (pcm) {
      if (this.audioStartUs === 0) this.audioStartUs = now;
      this.audioPlayedUs += ((pcm.length / this.core.audioChannels) * 1e6) / 48000;
      this.audio.rendered++;
    } else if (!due) this.audio.paced++;
    const msg: PcmMsg = { pcm, channels: this.core.audioChannels };
    this.audioPort!.postMessage(msg, pcm ? [pcm.buffer] : []);
  }

  // --- reports -------------------------------------------------------------

  reportIfDue(now = nowUs()) {
    if (!this.ended && now - this.reportedAt >= reportEveryUs) this.report();
  }

  report() {
    this.reportedAt = nowUs();
    const st = this.core.state;
    const msg: FromWorker = {
      type: "stats",
      state: st === State.connecting ? "connecting" : st === State.streaming ? "streaming" : "ended",
      end: this.core.end,
      config: this.core.config(),
      overlay: this.core.overlay(nowUs()),
      stats: this.core.stats(),
      video: { ...this.video, errors: [...this.video.errors] },
      audio: { ...this.audio },
      relayed: this.relayed,
      probe: this.probeEvents,
      transport: transportStats(this.transport),
    };
    this.probeEvents = [];
    this.video.decodeMs = [];
    this.video.drawMs = [];
    self.postMessage(msg);
  }

  /** Input from the page: into the core's sender, then a step so it goes out now. */
  input(ops: InputOp[]) {
    if (this.ended) return;
    const origin = performance.timeOrigin * 1000;
    for (const o of ops) {
      const t = o.t - origin; // page clock to this worker's
      switch (o.op) {
        case "key":
          this.core.key(o.code, o.down, t);
          break;
        case "button":
          this.core.button(o.code, o.down, t);
          break;
        case "scroll":
          this.core.scroll(o.dx, o.dy, t);
          break;
        case "rel":
          this.core.moveRel(o.x, o.y, t);
          break;
        case "abs":
          this.core.moveAbs(o.x, o.y, t);
          break;
        case "pad":
          this.core.pad(o.index, o.state, t);
          break;
      }
    }
    this.schedule();
  }

  close() {
    if (this.ended) return;
    this.core.close(nowUs());
    this.step();
  }
}

let media: Media | null = null;

function transportStats(t: Transport): Record<string, number | boolean> | null {
  const conn = (t as Partial<IrohTransport>).conn;
  if (!conn) return null;
  return Object.fromEntries(Object.entries(conn.stats() as Record<string, unknown>).map(([k, v]) => [k, typeof v === "bigint" ? Number(v) : (v as number | boolean)]));
}

let pinWaiter: ((pin: string) => void) | null = null;
const status = (text: string) => self.postMessage({ type: "status", text } satisfies FromWorker);

/**
 * shim-web in this worker: bind this device's endpoint, pair with the host in the ticket
 * unless it already did (spec/pairing-v0.md, Exchange), then dial it and ask for a session
 * (Admission). Media datagrams start only once the host admitted this device.
 */
async function dialIroh(o: IrohDial): Promise<Transport> {
  type IrohModule = typeof import("../../../shim-web/pkg/iroh_web.js");
  const iroh: IrohModule = await import(/* @vite-ignore */ new URL("iroh_web.js", o.pkgUrl).href);
  await iroh.default({ module_or_path: new URL("iroh_web_bg.wasm", o.pkgUrl) });
  const pair = await loadPair(new URL("moonsec-pair.wasm", o.pkgUrl));
  const t = pair.decodeTicket(o.ticket.trim());
  const ep = await iroh.Endpoint.bind({ relayUrls: o.relayUrls, ...(o.secretKey ? { secretKey: o.secretKey } : {}) });
  await ep.online(15000);
  let known = o.hosts.find((h) => h.hostId === t.hostId) ?? null;
  let pin = o.pin ?? "";
  const pairOnce = async () => {
    for (;;) {
      if (!t.hasSecret && !pin) pin = await askPin(t.hostId, "", -1);
      status("pairing");
      try {
        const h = await pair.pairWithTicket(ep, o.ticket.trim(), { pin, name: o.name });
        self.postMessage({ type: "paired-host", host: h } satisfies FromWorker);
        return h;
      } catch (e) {
        // A wrong PIN: ask again while the host has attempts left.
        if (e instanceof PairError && e.reason === 3 && !t.hasSecret) {
          pin = await askPin(t.hostId, e.message, e.attemptsLeft);
          continue;
        }
        throw e;
      }
    }
  };
  if (!known) known = await pairOnce();
  for (let attempt = 0; ; attempt++) {
    status("connecting");
    // The ticket's address is the freshest; a paired host's stored one is the fallback.
    const conn = await ep.connect(t.addr || known.addr, "moonsec/0", 30000);
    if (conn.remoteId !== t.hostId) {
      conn.close(0);
      throw new Error("the host at that address is not the one in the ticket");
    }
    try {
      await pair.admit(conn);
    } catch (e) {
      conn.close(0);
      // The host forgot this device: pair again once if the ticket allows it.
      if (attempt === 0 && e instanceof PairError && e.reason === 9 && (t.hasSecret || o.pin !== undefined)) {
        known = await pairOnce();
        continue;
      }
      throw e;
    }
    const tr = new IrohTransport(conn);
    // Keep the endpoint reachable: when its wrapper is garbage collected, wasm-bindgen's
    // finalizer drops the Rust endpoint and the connection closes under the session.
    (tr as IrohTransport & { endpoint?: unknown }).endpoint = ep;
    return tr;
  }
}

function askPin(hostId: string, error: string, attemptsLeft: number): Promise<string> {
  self.postMessage({ type: "pin-needed", hostId, error, attemptsLeft } satisfies FromWorker);
  return new Promise((resolve) => (pinWaiter = resolve));
}

self.onmessage = async (ev: MessageEvent<ToWorker>) => {
  const m = ev.data;
  try {
    if (m.type === "start") {
      const support = await probeDecoders();
      if (support.codecs === 0) throw new Error("this browser has no WebCodecs video decoder for H.264, HEVC or AV1");
      let transport: Transport | null = null;
      const pending: Uint8Array[] = [];
      // Pairing can wait on a person typing a PIN: dial before the session starts its clock.
      const dialed = m.iroh ? await dialIroh(m.iroh) : null;
      const core = await CoreSession.create(fetch(m.wasmUrl), { codecs: support.codecs, channels: m.audio ? 2 : 0 }, (dg) => {
        // Copy out of wasm memory before returning.
        if (transport) transport.send(dg.slice());
        else pending.push(dg.slice());
      });
      transport = dialed ?? (await WebSocketTransport.connect(m.wsUrl));
      for (const dg of pending) transport.send(dg);
      media = new Media(core, transport, m, support);
    } else if (m.type === "input") {
      media?.input(m.ops);
    } else if (m.type === "pin") {
      const w = pinWaiter;
      pinWaiter = null;
      w?.(m.pin);
    } else if (m.type === "close") {
      media?.close();
    }
  } catch (e) {
    self.postMessage({ type: "error", message: e instanceof Error ? e.message : String(e) } satisfies FromWorker);
  }
};
