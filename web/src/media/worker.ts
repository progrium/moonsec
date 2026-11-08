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
import type { AudioReport, FromWorker, NeedMsg, PcmMsg, StartMsg, ToWorker, VideoReport } from "./protocol";

declare const self: DedicatedWorkerGlobalScope;

const nowUs = () => performance.now() * 1000;

/** At most this many frames inside the decoder: one decoding, one arriving. */
const maxInDecoder = 2;

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
  seconds: number;
  video: VideoReport = { codec: null, hardware: "", configured: 0, submitted: 0, decoded: 0, drawn: 0, failed: 0, errors: [], decodeMs: [], drawMs: [], nonBlank: false };
  audio: AudioReport = { rendered: 0, played: 0, loud: 0, underruns: 0, queued: 0, sampleRate: 0 };
  audioPort: MessagePort | null;

  constructor(core: CoreSession, transport: Transport, m: StartMsg, support: DecoderSupport) {
    this.core = core;
    this.transport = transport;
    this.canvas = m.canvas;
    this.ctx = m.canvas.getContext("2d", { alpha: false, desynchronized: true } as CanvasRenderingContext2DSettings) as OffscreenCanvasRenderingContext2D;
    this.support = support;
    this.relayed = m.relayed;
    this.seconds = m.seconds;
    this.audioPort = m.audio;
    core.setPath({ rttUs: 0, relayed: m.relayed, pathEpoch: 0, connEpoch: 0, connected: true });
    transport.onDatagram = (dg) => {
      if (!core.push(dg, nowUs())) return;
      this.schedule();
    };
    if (this.audioPort) this.audioPort.onmessage = (ev: MessageEvent<NeedMsg>) => this.onNeed(ev.data);
    setInterval(() => this.report(), 250);
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
    const pcm = this.ended ? null : this.core.renderAudio(nowUs());
    if (pcm) this.audio.rendered++;
    const msg: PcmMsg = { pcm, channels: this.core.audioChannels };
    this.audioPort!.postMessage(msg, pcm ? [pcm.buffer] : []);
  }

  // --- reports -------------------------------------------------------------

  report() {
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
    };
    this.video.decodeMs = [];
    this.video.drawMs = [];
    self.postMessage(msg);
  }

  close() {
    if (this.ended) return;
    this.core.close(nowUs());
    this.step();
  }
}

let media: Media | null = null;

self.onmessage = async (ev: MessageEvent<ToWorker>) => {
  const m = ev.data;
  try {
    if (m.type === "start") {
      const support = await probeDecoders();
      if (support.codecs === 0) throw new Error("this browser has no WebCodecs video decoder for H.264, HEVC or AV1");
      let transport: Transport | null = null;
      const pending: Uint8Array[] = [];
      const core = await CoreSession.create(fetch(m.wasmUrl), { codecs: support.codecs, channels: m.audio ? 2 : 0 }, (dg) => {
        // Copy out of wasm memory before returning.
        if (transport) transport.send(dg.slice());
        else pending.push(dg.slice());
      });
      transport = await WebSocketTransport.connect(m.wsUrl);
      for (const dg of pending) transport.send(dg);
      media = new Media(core, transport, m, support);
    } else if (m.type === "close") {
      media?.close();
    }
  } catch (e) {
    self.postMessage({ type: "error", message: e instanceof Error ? e.message : String(e) } satisfies FromWorker);
  }
};
