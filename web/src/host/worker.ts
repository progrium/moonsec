// The browser host's worker: owns the iroh endpoint (shim-web), the core's host session
// (app/web_host.zig), the WebCodecs video encoder and the audio encoder. The page sends
// it captured canvas frames and the audio tap's PCM; it sends the page the input actions
// to inject.
//
// One client at a time: the endpoint accepts a connection, a fresh core session serves it
// until it ends, then the next connection is accepted.
//
// Video: one frame inside the encoder at a time, because the core's encode stage pairs
// every `encodeParams` with one `onEncoded` (app/host_session.zig). A frame that arrives
// while the encoder is busy is dropped before it reaches the core, which is what a native
// host's capture does when encode runs long. Recovery has no long-term references in
// WebCodecs, so every recovery request becomes a keyframe.

import { IrohTransport } from "../../../shim-web/js/transport.js";
import { HostCore, HostModule, HostState, type Action } from "./core";
import type { FromHostWorker, HostReport, HostStartMsg, TapMsg, ToHostWorker } from "./protocol";

declare const self: DedicatedWorkerGlobalScope;

const ALPN = "moonsec/0";
const nowUs = () => performance.now() * 1000;
/** Absolute µs (page and worker share it) to this worker's performance.now() µs. */
const fromAbs = (t: number) => t - performance.timeOrigin * 1000;

const codecIds: Record<string, number> = { h264: 1, hevc: 2, av1: 3 };
const codecStrings: Record<string, string[]> = {
  h264: ["avc1.42E028", "avc1.42E01F", "avc1.4D0028", "avc1.640028"],
  av1: ["av01.0.08M.08", "av01.0.04M.08"],
  hevc: ["hvc1.1.6.L120.B0"],
};
/** Frames between long-term reference marks. */
const ltrEvery = 30;

type EncoderBuffer = object;
type ManualEncodeOptions = VideoEncoderEncodeOptions & { referenceBuffers?: EncoderBuffer[]; updateBuffer?: EncoderBuffer };

/**
 * Long-term references on WebCodecs' manual reference buffers: two long-term slots that
 * alternate (the newest acked one is never overwritten) and one short-term buffer every
 * other frame predicts from. A refresh references only the newest acked long-term slot.
 */
class RefBuffers {
  private slotToken: (number | null)[] = [null, null];
  private acked = new Set<number>();
  private nextToken = 1;
  private sinceMark = 0;
  marks = 0;
  refreshes = 0;
  constructor(private bufs: EncoderBuffer[]) {}

  reset() {
    this.slotToken = [null, null];
    this.acked.clear();
    this.sinceMark = 0;
  }

  private newestAckedSlot(): number {
    let best = -1;
    for (let i = 0; i < 2; i++) {
      const t = this.slotToken[i];
      if (t !== null && this.acked.has(t) && (best < 0 || t > this.slotToken[best]!)) best = i;
    }
    return best;
  }

  /** Options for the next encode, and what to tell the core about the frame. */
  plan(force: number, ackedTokens: number[], keyFrame: boolean): { opts: ManualEncodeOptions; token: number; refresh: boolean } {
    for (const t of ackedTokens) this.acked.add(t);
    const st = this.bufs[2];
    if (keyFrame || force === 2) {
      this.reset();
      return { opts: { keyFrame: true, updateBuffer: st }, token: -1, refresh: false };
    }
    if (force === 1) {
      const slot = this.newestAckedSlot();
      if (slot < 0) {
        this.reset();
        return { opts: { keyFrame: true, updateBuffer: st }, token: -1, refresh: false };
      }
      this.refreshes++;
      return { opts: { keyFrame: false, referenceBuffers: [this.bufs[slot]], updateBuffer: st }, token: -1, refresh: true };
    }
    if (++this.sinceMark >= ltrEvery) {
      this.sinceMark = 0;
      const keep = this.newestAckedSlot();
      const slot = keep === 0 ? 1 : keep === 1 ? 0 : this.slotToken[0] === null ? 0 : 1;
      const token = this.nextToken++;
      this.slotToken[slot] = token;
      this.marks++;
      return { opts: { keyFrame: false, referenceBuffers: [st], updateBuffer: this.bufs[slot] }, token, refresh: false };
    }
    return { opts: { keyFrame: false, referenceBuffers: [st], updateBuffer: st }, token: -1, refresh: false };
  }
}

/** No output for this long after encode(): the encoder dropped the frame. */
const encodeTimeoutUs = 250_000;

interface Pending {
  ts: number;
  captureStartUs: number;
  capturedUs: number;
  encodeStartUs: number;
  width: number;
  height: number;
}

type IrohModule = typeof import("../../../shim-web/pkg/iroh_web.js");
type Endpoint = import("../../../shim-web/pkg/iroh_web.js").Endpoint;
type Connection = import("../../../shim-web/pkg/iroh_web.js").Connection;

class Host {
  m: HostStartMsg;
  module!: HostModule;
  ep!: Endpoint;
  core: HostCore | null = null;
  transport: IrohTransport | null = null;
  timer: ReturnType<typeof setTimeout> | null = null;
  stepScheduled = false;
  closing = false;
  report: HostReport;

  // video
  encoder: VideoEncoder | null = null;
  codec = "";
  codecString = "";
  pending: (Pending & { token: number; refresh: boolean }) | null = null;
  refs: RefBuffers | null = null;
  ltr = false;
  forceKey = true;
  frameTs = 0;

  // audio
  audioRate = 48000;
  pcm = new Float32Array(480 * 2);
  fill = 0;
  fillStartUs = 0;
  audioEncoder: AudioEncoder | null = null;
  audioTs = new Map<number, number>();

  constructor(m: HostStartMsg) {
    this.m = m;
    this.report = {
      type: "stats",
      state: "starting",
      end: "",
      ticket: "",
      endpointId: "",
      sessions: 0,
      client: "",
      codec: "",
      encoder: { ltrMarks: 0, ltrRefreshes: 0, configured: 0, frames: 0, busyDrops: 0, timeouts: 0, lateDiscards: 0, errors: [], encodeMs: [], queueMax: 0 },
      audio: { encoder: m.audio ? m.audioEncoder : "off", frames: 0, packets: 0, dropped: 0, peak: 0, errors: [] },
      stats: null,
      transport: null,
      ltr: false,
    };
  }

  post(msg: FromHostWorker) {
    self.postMessage(msg);
  }

  async start() {
    this.module = await HostModule.load(this.m.wasmUrl);
    await this.pickCodec();
    // AV1 only: Chromium's H.264 encoder (OpenH264) takes the reference buffer options, but
    // its refreshes do not decode right (web/host/README.md, "Long-term references").
    this.ltr = this.m.ltr && this.codec === "av1" && typeof (VideoEncoder.prototype as { getAllFrameBuffers?: unknown }).getAllFrameBuffers === "function";
    this.report.ltr = this.ltr;
    const iroh: IrohModule = await import(/* @vite-ignore */ new URL("iroh_web.js", this.m.pkgUrl).href);
    await iroh.default({ module_or_path: new URL("iroh_web_bg.wasm", this.m.pkgUrl) });
    this.ep = await iroh.Endpoint.bind({ relayUrls: this.m.relayUrls, alpn: ALPN, ...(this.m.secretKey ? { secretKey: this.m.secretKey } : {}) });
    await this.ep.online(15000);
    this.report.ticket = this.ep.ticket();
    this.report.endpointId = this.ep.id;
    this.report.state = "waiting";
    if (this.m.audio) this.m.audio.onmessage = (ev: MessageEvent<TapMsg>) => this.onTap(ev.data);
    setInterval(() => this.sendReport(), 250);
    this.sendReport();
    void this.acceptLoop();
  }

  async pickCodec() {
    for (const name of this.m.codecs) {
      for (const codec of codecStrings[name] ?? []) {
        const cfg = this.encoderConfig(name, codec);
        try {
          const s = await VideoEncoder.isConfigSupported(cfg);
          if (s.supported) {
            this.codec = name;
            this.codecString = codec;
            this.report.codec = codec;
            return;
          }
        } catch {
          /* try the next */
        }
      }
    }
    throw new Error(`no WebCodecs encoder for ${this.m.codecs.join(", ")}`);
  }

  encoderConfig(name: string, codec: string): VideoEncoderConfig {
    const c: VideoEncoderConfig = {
      codec,
      width: this.m.width,
      height: this.m.height,
      bitrate: this.m.bitrateBps,
      framerate: this.m.fps,
      latencyMode: "realtime",
      bitrateMode: "variable",
    };
    if (name === "h264") c.avc = { format: "annexb" };
    if (this.ltr) c.scalabilityMode = "manual";
    if (name === "hevc") (c as VideoEncoderConfig & { hevc?: unknown }).hevc = { format: "annexb" };
    return c;
  }

  // --- connections -------------------------------------------------------------------

  async acceptLoop() {
    while (!this.closing) {
      let conn: Connection;
      try {
        conn = await this.ep.accept();
      } catch (e) {
        this.report.encoder.errors.push(`accept: ${String(e)}`);
        await new Promise((r) => setTimeout(r, 500));
        continue;
      }
      try {
        await this.serve(conn);
      } catch (e) {
        this.post({ type: "error", message: `session: ${e instanceof Error ? e.message : String(e)}` });
      }
    }
  }

  /** One session, until it ends. No admission (spec/pairing-v0.md) yet: the ticket is the access. */
  async serve(conn: Connection) {
    this.report.sessions++;
    this.report.client = conn.remoteId;
    let transport: IrohTransport | null = null;
    const core = await HostCore.create(
      this.module,
      { codec: codecIds[this.codec], width: this.m.width, height: this.m.height, fps: this.m.fps, bitrateBps: this.m.bitrateBps, channels: this.m.audio ? 2 : 0, rateControl: this.m.rateControl, ltr: this.ltr },
      (dg) => {
        if (this.m.loss > 0 && Math.random() < this.m.loss) return;
        if (this.m.outageMs > 0 && performance.now() % 3000 < this.m.outageMs) return;
        transport?.send(dg.slice());
      },
    );
    transport = new IrohTransport(conn);
    this.core = core;
    this.transport = transport;
    this.forceKey = true;
    this.configureEncoder();
    if (this.m.audio && this.m.audioEncoder === "webcodecs") this.configureAudioEncoder();
    core.setPath(0, true);
    transport.onDatagram = (dg) => {
      if (core.push(dg, nowUs())) this.schedule();
    };
    const ended = new Promise<void>((resolve) => (this.onEnded = resolve));
    this.step();
    const pathTimer = setInterval(() => {
      const rows = conn.pathStats() as { isSelected: boolean; rttUs: number }[];
      const sel = rows.find((r) => r.isSelected) ?? rows[0];
      if (sel) core.setPath(sel.rttUs, true, !transport!.closed);
      if (transport!.closed) core.pipeClosed();
    }, 100);
    await ended;
    clearInterval(pathTimer);
    this.report.end = core.end;
    this.report.stats = core.stats();
    this.core = null;
    this.transport = null;
    if (this.pending) this.pending = null;
    this.encoder?.close();
    this.encoder = null;
    this.audioEncoder?.close();
    this.audioEncoder = null;
    transport.close();
    core.free();
  }

  onEnded: (() => void) | null = null;

  schedule() {
    if (this.stepScheduled) return;
    this.stepScheduled = true;
    queueMicrotask(() => {
      this.stepScheduled = false;
      this.step();
    });
  }

  step() {
    const core = this.core;
    if (!core) return;
    const now = nowUs();
    core.step(now);
    const actions = core.takeActions();
    if (actions.length > 0) this.post({ type: "actions", actions });
    this.checkEncodeTimeout(now);
    if (core.state === HostState.ended) {
      const done = this.onEnded;
      this.onEnded = null;
      done?.();
      return;
    }
    if (this.timer !== null) clearTimeout(this.timer);
    const wake = core.nextWake(now);
    this.timer = setTimeout(() => {
      this.timer = null;
      this.step();
    }, Math.max(0, (wake - nowUs()) / 1000));
  }

  // --- video -----------------------------------------------------------------------------

  configureEncoder() {
    this.encoder?.close();
    this.pending = null;
    this.encoder = new VideoEncoder({ output: (c, md) => this.onChunk(c, md), error: (e) => this.onEncoderError(e) });
    this.encoder.configure(this.encoderConfig(this.codec, this.codecString));
    this.report.encoder.configured++;
    if (this.ltr) {
      const bufs = (this.encoder as VideoEncoder & { getAllFrameBuffers(): EncoderBuffer[] }).getAllFrameBuffers();
      this.refs = bufs.length >= 3 ? new RefBuffers(bufs) : null;
      if (!this.refs) this.report.encoder.errors.push(`manual reference buffers: ${bufs.length}, need 3; LTR off`);
    }
  }

  onFrame(frame: VideoFrame, captureStartUs: number, capturedUs: number) {
    const core = this.core;
    if (!core || !core.streaming || !this.encoder || this.encoder.state !== "configured") return frame.close();
    if (this.pending) {
      this.report.encoder.busyDrops++;
      return frame.close();
    }
    const { force, bitrateBps, ackedTokens } = core.encodeBegin();
    if (bitrateBps > 0) {
      // WebCodecs changes the bitrate by reconfiguring; Chromium keeps the stream going
      // without a keyframe for a bitrate-only change.
      this.encoder.configure({ ...this.encoderConfig(this.codec, this.codecString), bitrate: bitrateBps });
      this.refs?.reset();
    }
    // With long-term references a refresh (force 1) is a delta frame; without, every recovery is a keyframe.
    const keyFrame = (this.refs ? force === 2 : force !== 0) || this.forceKey;
    this.forceKey = false;
    const ts = ++this.frameTs;
    const start = nowUs();
    let opts: ManualEncodeOptions = { keyFrame };
    let ltr = { token: -1, refresh: false };
    if (this.refs) {
      const p = this.refs.plan(force, ackedTokens, keyFrame);
      opts = p.opts;
      ltr = { token: p.token, refresh: p.refresh };
      this.report.encoder.ltrMarks = this.refs.marks;
      this.report.encoder.ltrRefreshes = this.refs.refreshes;
    }
    this.pending = { ts, captureStartUs: fromAbs(captureStartUs), capturedUs: fromAbs(capturedUs), encodeStartUs: start, width: frame.displayWidth, height: frame.displayHeight, ...ltr };
    // A frame of another size than configured is scaled by the encoder.
    const vf = new VideoFrame(frame, { timestamp: ts });
    frame.close();
    try {
      this.encoder.encode(vf, opts);
    } catch (e) {
      this.pending = null;
      core.encodeDropped();
      this.onEncoderError(e);
    }
    vf.close();
    this.report.encoder.queueMax = Math.max(this.report.encoder.queueMax, this.encoder?.encodeQueueSize ?? 0);
  }

  onChunk(chunk: EncodedVideoChunk, _md?: EncodedVideoChunkMetadata) {
    const core = this.core;
    const p = this.pending;
    if (!core || !p || p.ts !== chunk.timestamp) {
      // Output for a frame already given up on: the client never gets it, so whatever
      // references it is undecodable. Start over from a keyframe.
      this.report.encoder.lateDiscards++;
      this.forceKey = true;
      return;
    }
    this.pending = null;
    const now = nowUs();
    this.report.encoder.frames++;
    this.report.encoder.encodeMs.push((now - p.encodeStartUs) / 1000);
    core.encodeDone(chunk, { token: p.token, refresh: p.refresh }, { captureStartUs: p.captureStartUs, capturedUs: p.capturedUs, encodeStartUs: p.encodeStartUs, encodedUs: now, width: p.width, height: p.height }, now);
    this.schedule();
  }

  checkEncodeTimeout(now: number) {
    const p = this.pending;
    if (!p || !this.core || now - p.encodeStartUs < encodeTimeoutUs) return;
    this.pending = null;
    this.core.encodeDropped();
    this.report.encoder.timeouts++;
    this.forceKey = true;
  }

  onEncoderError(e: unknown) {
    const msg = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
    if (this.report.encoder.errors.length < 10) this.report.encoder.errors.push(msg);
    if (this.pending && this.core) {
      this.pending = null;
      this.core.encodeDropped();
    }
    if (this.core) this.configureEncoder();
    this.forceKey = true;
  }

  // --- audio -------------------------------------------------------------------------------

  configureAudioEncoder() {
    this.audioEncoder = new AudioEncoder({
      output: (c) => this.onAudioChunk(c),
      error: (e) => {
        if (this.report.audio.errors.length < 10) this.report.audio.errors.push(String(e));
      },
    });
    this.audioEncoder.configure({
      codec: "opus",
      sampleRate: 48000,
      numberOfChannels: 2,
      bitrate: 96000,
      // 10 ms frames like the core's own encoder (spec/audio-v0.md), in-band FEC on.
      opus: { frameDuration: 10000, useinbandfec: true, complexity: 5 },
    } as AudioEncoderConfig);
  }

  /** Tap quanta (128 frames) into 10 ms frames, then into the encoder. */
  onTap(m: TapMsg) {
    this.audioRate = m.sampleRate;
    const core = this.core;
    if (!core || !core.streaming) {
      this.fill = 0;
      return;
    }
    if (m.sampleRate !== 48000) {
      this.report.audio.dropped++;
      return;
    }
    const src = m.pcm;
    let off = 0;
    const now = nowUs();
    while (off < src.length) {
      if (this.fill === 0) this.fillStartUs = now - (((src.length - off) / 2) * 1e6) / 48000;
      const n = Math.min(src.length - off, this.pcm.length - this.fill);
      this.pcm.set(src.subarray(off, off + n), this.fill);
      this.fill += n;
      off += n;
      if (this.fill < this.pcm.length) break;
      this.fill = 0;
      for (let i = 0; i < this.pcm.length; i++) this.report.audio.peak = Math.max(this.report.audio.peak, Math.abs(this.pcm[i]));
      if (this.m.audioEncoder === "webcodecs" && this.audioEncoder?.state === "configured") {
        const ts = Math.round(this.fillStartUs);
        this.audioTs.set(ts, this.fillStartUs);
        this.audioEncoder.encode(new AudioData({ format: "f32", sampleRate: 48000, numberOfFrames: 480, numberOfChannels: 2, timestamp: ts, data: this.pcm.slice() }));
      } else {
        const n = core.audioEncode(this.pcm, this.fillStartUs, nowUs());
        this.report.audio.frames++;
        this.report.audio.packets += n;
      }
    }
    this.schedule();
  }

  onAudioChunk(c: EncodedAudioChunk) {
    const core = this.core;
    if (!core) return;
    const samples = Math.round(((c.duration ?? 10000) * 48000) / 1e6);
    const cap = this.audioTs.get(c.timestamp) ?? c.timestamp;
    this.audioTs.delete(c.timestamp);
    const n = core.audioPacket(c, samples, cap, nowUs());
    this.report.audio.frames++;
    this.report.audio.packets += n;
  }

  // --- reports -------------------------------------------------------------------------

  sendReport() {
    const core = this.core;
    if (core) {
      this.report.state = core.state === HostState.waiting ? "waiting" : core.state === HostState.streaming ? "streaming" : "ended";
      this.report.end = core.end;
      this.report.stats = core.stats();
      const ts = this.transport?.conn.stats() as Record<string, unknown> | undefined;
      this.report.transport = ts ? Object.fromEntries(Object.entries(ts).map(([k, v]) => [k, typeof v === "bigint" ? Number(v) : (v as number | boolean)])) : null;
    } else if (this.report.state !== "starting") this.report.state = "waiting";
    this.post({ ...this.report, encoder: { ...this.report.encoder, errors: [...this.report.encoder.errors] }, audio: { ...this.report.audio, errors: [...this.report.audio.errors] } });
    this.report.encoder.encodeMs = [];
    this.report.audio.peak = 0;
  }

  injected(times: number[], at: number) {
    const core = this.core;
    if (!core) return;
    const t = fromAbs(at);
    for (const ct of times) core.onInjected(ct, t);
  }

  close() {
    this.closing = true;
    if (this.core) {
      this.core.close(nowUs());
      this.step();
    }
  }
}

let host: Host | null = null;

self.onmessage = async (ev: MessageEvent<ToHostWorker>) => {
  const m = ev.data;
  try {
    if (m.type === "start") {
      host = new Host(m);
      await host.start();
    } else if (m.type === "frame") {
      if (host) host.onFrame(m.frame, m.captureStartUs, m.capturedUs);
      else m.frame.close();
    } else if (m.type === "injected") {
      host?.injected(m.times, m.at);
    } else if (m.type === "close") {
      host?.close();
    }
  } catch (e) {
    self.postMessage({ type: "error", message: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e) } satisfies FromHostWorker);
  }
};

export type { Action };
