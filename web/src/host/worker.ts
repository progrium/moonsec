// The browser host's worker: owns the iroh endpoint (shim-web), the core's host session
// (app/web_host.zig), the WebCodecs video encoder and the audio encoder. The page sends
// it captured canvas frames and the audio tap's PCM; it sends the page the input actions
// to inject.
//
// Connections: each one's first stream is pairing (while the host user has an invite open)
// or admission (spec/pairing-v0.md): only devices on the host's allowlist get a session.
// Admitted clients are members of one multi-user session (app/multi_host.zig): one capture
// and one encode, sent to every member with its own pacing, retransmits and input stream.
// The session starts with the first member and ends with the last.
//
// Video: one frame inside the encoder at a time, because the core's encode stage pairs
// every `encodeParams` with one `onEncoded` (app/host_session.zig). A frame that arrives
// while the encoder is busy is dropped before it reaches the core, which is what a native
// host's capture does when encode runs long. Recovery has no long-term references in
// WebCodecs, so every recovery request becomes a keyframe.

import { IrohTransport } from "../../../shim-web/js/transport.js";
import { ConnStep, HostCore, HostModule, PeerState, type Action, type HostPeer } from "./core";
import type { FromHostWorker, HostReport, HostStartMsg, Invite, InviteOptions, PairedDevice, TapMsg, ToHostWorker } from "./protocol";

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
type BiStream = import("../../../shim-web/pkg/iroh_web.js").BiStream;

/** Application error code a host closes an unadmitted connection with (spec/pairing-v0.md). */
const CLOSE_NOT_PAIRED = 0x5050;
/** Budget for one connection's pairing exchange or admission, so a stalled peer holds up no one. */
const connBudgetMs = 30_000;
const wallUs = () => Date.now() * 1000;

interface Member {
  ctx: number;
  peer: HostPeer;
  transport: IrohTransport;
  conn: Connection;
  endpointId: string;
  name: string;
  input: boolean;
  pathTimer: ReturnType<typeof setInterval>;
  pathAt: number;
}

class Host {
  m: HostStartMsg;
  module!: HostModule;
  ep!: Endpoint;
  /** The pairing side: its own instance of the module, for the host's whole life. */
  pairCore!: HostCore;
  /** The session (one encode, every member), from the first member until the last leaves. */
  core: HostCore | null = null;
  members = new Map<number, Member>();
  nextCtx = 1;
  allow = new Map<string, PairedDevice>();
  addr = "";
  invite: { ticket: string | null; pin: string | null; expiresAt: number; pairings: number; qr: Invite["qr"] } | null = null;
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
    for (const d of m.allowlist) this.allow.set(d.id, d);
    this.report = {
      type: "stats",
      state: "starting",
      ticket: "",
      endpointId: "",
      sessions: 0,
      codec: "",
      ltr: false,
      invite: null,
      members: [],
      left: [],
      pairing: { paired: 0, failed: 0, admitted: 0, refused: 0, full: 0, lastFailure: "" },
      multi: null,
      encoder: { ltrMarks: 0, ltrRefreshes: 0, configured: 0, frames: 0, busyDrops: 0, timeouts: 0, lateDiscards: 0, errors: [], encodeMs: [], queueMax: 0 },
      audio: { encoder: m.audio ? m.audioEncoder : "off", frames: 0, packets: 0, dropped: 0, peak: 0, errors: [] },
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
    this.pairCore = await HostCore.create(this.module, this.sessionOptions(0), () => {});
    this.pairCore.setIdentity(this.ep.id, this.m.name);
    this.addr = this.ep.ticket();
    this.report.ticket = this.pairCore.ticket(this.addr, false);
    this.report.endpointId = this.ep.id;
    this.report.state = "waiting";
    if (this.m.audio) this.m.audio.onmessage = (ev: MessageEvent<TapMsg>) => this.onTap(ev.data);
    setInterval(() => this.sendReport(), 250);
    this.sendReport();
    void this.acceptLoop();
  }

  sessionOptions(channels: number) {
    return { codec: codecIds[this.codec], width: this.m.width, height: this.m.height, fps: this.m.fps, bitrateBps: this.m.bitrateBps, channels, rateControl: this.m.rateControl, ltr: this.ltr, policy: this.m.policy, maxMembers: this.m.maxMembers };
  }

  async pickCodec() {
    for (const name of this.m.codecs) {
      for (const codec of codecStrings[name] ?? []) {
        const cfg = this.encoderConfig(name, codec);
        try {
          const s = await VideoEncoder.isConfigSupported(cfg);
          if (s.supported && (await this.encodes(cfg))) {
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

  /**
   * Whether an encoder with `cfg` puts out a frame on its own, without a flush or more
   * input: the host keeps one frame in the encoder at a time (see the top). A supported
   * config is not proof. Firefox's H.264 here takes frames and holds them until flushed,
   * which would leave the stream waiting forever.
   */
  async encodes(cfg: VideoEncoderConfig): Promise<boolean> {
    let got = false;
    let done: () => void = () => {};
    const out = new Promise<void>((r) => (done = r));
    const enc = new VideoEncoder({
      output: () => {
        got = true;
        done();
      },
      error: () => done(),
    });
    try {
      enc.configure({ ...cfg, scalabilityMode: undefined });
      const canvas = new OffscreenCanvas(cfg.width, cfg.height);
      canvas.getContext("2d")!.fillRect(0, 0, 16, 16);
      const f = new VideoFrame(canvas, { timestamp: 0 });
      enc.encode(f, { keyFrame: true });
      f.close();
      await Promise.race([out, new Promise((r) => setTimeout(r, 1500))]);
    } catch {
      /* not this one */
    } finally {
      if (enc.state !== "closed") enc.close();
    }
    return got;
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

  // --- pairing window ---------------------------------------------------------------

  openInvite(o: InviteOptions) {
    const seconds = o.seconds ?? 120;
    const pairings = o.pairings ?? 1;
    const deadlineUs = wallUs() + seconds * 1e6;
    const secret = o.secret ?? true;
    const { pin } = this.pairCore.openWindow({ secret, pin: o.pin ?? true, deadlineUs, pairings, attempts: o.attempts ?? 5 });
    const expiresAt = deadlineUs / 1000;
    const ticket = secret ? this.pairCore.ticket(this.addr, true, Math.ceil(expiresAt / 1000)) : null;
    this.invite = { ticket, pin, expiresAt, pairings, qr: ticket ? this.pairCore.qr(ticket) : null };
    this.sendReport();
  }

  closeInvite() {
    this.pairCore.closeWindow();
    this.invite = null;
    this.sendReport();
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
      // Each connection on its own: one that stalls holds up no one else.
      void this.handleConn(conn).catch((e) => {
        this.report.pairing.lastFailure = `${conn.remoteId.slice(0, 8)}: ${e instanceof Error ? e.message : String(e)}`;
        try {
          conn.close(0);
        } catch {
          /* closed */
        }
      });
    }
  }

  /** Pairing or admission on the connection's first stream (spec/pairing-v0.md). */
  async handleConn(conn: Connection) {
    const deadline = Date.now() + connBudgetMs;
    const left = () => Math.max(1, deadline - Date.now());
    const s: BiStream = await conn.acceptBi(left());
    const pc = this.pairCore.newConn(conn.remoteId);
    const write = async (b: Uint8Array) => {
      if (b.length > 0) await s.write(b, left());
    };
    try {
      for (;;) {
        const r = pc.step(wallUs());
        if (r === ConnStep.more) {
          const chunk = await s.read(4096, left());
          if (chunk === null) throw new Error("the stream ended mid-exchange");
          for (let off = 0; off < chunk.length; ) {
            const took = pc.push(chunk.subarray(off));
            off += took;
            if (took === 0) throw new Error("message too long");
          }
          continue;
        }
        if (r === ConnStep.reply) {
          await write(pc.reply());
          continue;
        }
        if (r === ConnStep.paired) {
          await write(pc.reply());
          const p = pc.paired();
          const device: PairedDevice = { id: p.id, name: p.name, paired: Math.floor(Date.now() / 1000), input: true };
          this.allow.set(p.id, device);
          this.report.pairing.paired++;
          this.post({ type: "paired", device });
          // Wait for the client's end so the exchange is delivered, then close.
          s.finish();
          while ((await s.read(4096, left()).catch(() => null)) !== null) {}
          conn.close(0);
          this.sendReport();
          return;
        }
        if (r === ConnStep.failed) {
          await write(pc.reply()).catch(() => {});
          this.report.pairing.failed++;
          this.report.pairing.lastFailure = `${conn.remoteId.slice(0, 8)}: ${reasons[pc.reason] ?? `reason ${pc.reason}`}`;
          s.finish();
          await s.read(4096, 2000).catch(() => null);
          conn.close(0);
          this.sendReport();
          return;
        }
        if (r === ConnStep.admit) {
          const device = this.allow.get(conn.remoteId);
          const full = !!device && !!this.core && this.core.members >= this.m.maxMembers;
          const ok = !!device && !full;
          await write(pc.admitReply(ok));
          s.finish();
          if (!ok) {
            if (full) this.report.pairing.full++;
            else this.report.pairing.refused++;
            await s.read(4096, 2000).catch(() => null);
            conn.close(CLOSE_NOT_PAIRED);
            return;
          }
          await this.addMember(conn, device);
          return;
        }
        throw new Error("malformed first message");
      }
    } finally {
      pc.free();
    }
  }

  async ensureSession(): Promise<HostCore> {
    if (this.core) return this.core;
    const core = await HostCore.create(this.module, this.sessionOptions(this.m.audio ? 2 : 0), (ctx, dg) => {
      if (this.m.loss > 0 && Math.random() < this.m.loss) return;
      if (this.m.outageMs > 0 && performance.now() % 3000 < this.m.outageMs) return;
      this.members.get(ctx)?.transport.send(dg.slice());
    });
    if (this.core) {
      core.free();
      return this.core;
    }
    this.core = core;
    this.forceKey = true;
    this.configureEncoder();
    if (this.m.audio && this.m.audioEncoder === "webcodecs") this.configureAudioEncoder();
    return core;
  }

  async addMember(conn: Connection, device: PairedDevice) {
    const core = await this.ensureSession();
    const ctx = this.nextCtx++;
    const input = device.input !== false;
    const peer = core.addPeer(ctx, device.name, input);
    if (!peer) {
      this.report.pairing.full++;
      conn.close(CLOSE_NOT_PAIRED);
      return;
    }
    this.report.pairing.admitted++;
    this.report.sessions++;
    const transport = new IrohTransport(conn);
    peer.setPath(0, true);
    transport.onDatagram = (dg) => {
      if (peer.push(dg, nowUs())) this.schedule();
    };
    const pathTimer = setInterval(() => this.updatePath(mb), 100);
    const mb: Member = { ctx, peer, transport, conn, endpointId: conn.remoteId, name: device.name, input, pathTimer, pathAt: 0 };
    this.members.set(ctx, mb);
    this.step();
  }

  updatePath(mb: Member) {
    mb.pathAt = performance.now();
    const rows = mb.conn.pathStats() as { isSelected: boolean; rttUs: number }[];
    const sel = rows.find((r) => r.isSelected) ?? rows[0];
    if (sel) mb.peer.setPath(sel.rttUs, true, !mb.transport.closed);
    if (mb.transport.closed) {
      mb.peer.pipeClosed();
      this.schedule();
    }
  }

  /** The host's user removes a device: its session ends, and (if forgotten) it cannot come back. */
  kick(id: string) {
    for (const mb of this.members.values()) if (mb.endpointId === id) mb.peer.close(nowUs());
    this.schedule();
  }

  memberLeft(mb: Member) {
    clearInterval(mb.pathTimer);
    this.members.delete(mb.ctx);
    this.report.left.push({ id: mb.peer.id, endpointId: mb.endpointId, name: mb.name, end: mb.peer.end, stats: mb.peer.stats() });
    if (this.report.left.length > 8) this.report.left.shift();
    mb.transport.close();
    this.post({ type: "left", id: mb.peer.id });
  }

  /** The last member left: the session (and its memory) goes; the next one starts fresh. */
  endSession() {
    const core = this.core;
    if (!core) return;
    this.report.multi = core.multiStats();
    this.core = null;
    this.pending = null;
    this.encoder?.close();
    this.encoder = null;
    this.audioEncoder?.close();
    this.audioEncoder = null;
    this.fill = 0;
    core.free();
  }

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
    // WebKit can starve a worker's intervals while this step timer keeps being re-armed:
    // path updates and reports also run from here when they are due.
    const t = performance.now();
    for (const mb of this.members.values()) if (t - mb.pathAt > 150) this.updatePath(mb);
    if (t - this.reportAt > 400) this.sendReport();
    const now = nowUs();
    core.step(now);
    const actions = core.takeActions();
    if (actions.length > 0) this.post({ type: "actions", actions });
    this.checkEncodeTimeout(now);
    for (const mb of [...this.members.values()]) if (mb.peer.state === PeerState.ended) this.memberLeft(mb);
    if (this.members.size === 0) {
      if (this.timer !== null) clearTimeout(this.timer);
      this.timer = null;
      this.endSession();
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

  reportAt = 0;

  sendReport() {
    this.reportAt = performance.now();
    const core = this.core;
    const r = this.report;
    if (r.state !== "starting") {
      r.members = [...this.members.values()].map((mb) => {
        const ts = mb.conn.stats() as Record<string, unknown>;
        const st = mb.peer.state;
        return {
          id: mb.peer.id,
          endpointId: mb.endpointId,
          name: mb.name,
          input: mb.input,
          state: st === PeerState.streaming ? "streaming" : st === PeerState.waiting ? "waiting" : "ended",
          end: mb.peer.end,
          stats: mb.peer.stats(),
          transport: Object.fromEntries(Object.entries(ts).map(([k, v]) => [k, typeof v === "bigint" ? Number(v) : (v as number | boolean)])),
        };
      });
      r.state = core?.streaming ? "streaming" : "waiting";
      if (core) r.multi = core.multiStats();
      if (this.invite) {
        const ws = this.pairCore.windowState(wallUs());
        if (ws !== 1) this.invite = null;
      }
      const inv = this.invite;
      r.invite = inv
        ? { ticket: inv.ticket, pin: inv.pin, expiresAt: inv.expiresAt, pairingsLeft: inv.pairings - this.pairCore.windowPaired, paired: this.pairCore.windowPaired, attemptsLeft: this.pairCore.windowAttemptsLeft, qr: inv.qr }
        : null;
    }
    this.post({ ...r, encoder: { ...r.encoder, errors: [...r.encoder.errors] }, audio: { ...r.audio, errors: [...r.audio.errors] }, members: [...r.members], left: [...r.left], pairing: { ...r.pairing } });
    r.encoder.encodeMs = [];
    r.audio.peak = 0;
  }

  injected(times: number[], from: number[], at: number) {
    const core = this.core;
    if (!core) return;
    const t = fromAbs(at);
    for (let i = 0; i < times.length; i++) core.onInjected(from[i], times[i], t);
  }

  close() {
    this.closing = true;
    if (this.core) {
      this.core.close(nowUs());
      this.step();
    }
  }
}

const reasons: Record<number, string> = {
  1: "not pairing right now",
  2: "method not offered",
  3: "wrong PIN or secret",
  4: "too many wrong attempts",
  5: "the pairing window expired",
  6: "unsupported pairing version",
  7: "protocol error",
  8: "host proof failed",
  9: "not paired",
};

let host: Host | null = null;
/** Settles once the host is up (pairing calls before that wait for it). */
let started: Promise<void> = new Promise(() => {});

self.onmessage = async (ev: MessageEvent<ToHostWorker>) => {
  const m = ev.data;
  try {
    if (m.type === "start") {
      host = new Host(m);
      started = host.start();
      await started;
    } else if (m.type === "frame") {
      if (host) host.onFrame(m.frame, m.captureStartUs, m.capturedUs);
      else m.frame.close();
    } else if (m.type === "injected") {
      host?.injected(m.times, m.from, m.at);
    } else if (m.type === "invite") {
      await started;
      host?.openInvite(m);
    } else if (m.type === "invite-close") {
      await started;
      host?.closeInvite();
    } else if (m.type === "allowlist") {
      await started;
      if (host) {
        host.allow = new Map(m.allowlist.map((d) => [d.id, d]));
        // A device no longer on the list loses its session at once.
        for (const mb of host.members.values()) if (!host.allow.has(mb.endpointId)) host.kick(mb.endpointId);
      }
    } else if (m.type === "kick") {
      await started;
      host?.kick(m.id);
    } else if (m.type === "close") {
      host?.close();
    }
  } catch (e) {
    self.postMessage({ type: "error", message: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e) } satisfies FromHostWorker);
  }
};

export type { Action };
