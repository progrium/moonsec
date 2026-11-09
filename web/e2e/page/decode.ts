// WebCodecs decode and draw, shared by the worker and the main-thread fallback. The
// pattern the web client will use (design, "Web client"): decode, draw, close each
// frame at once, no queue.

export interface ProbeFrame {
  key: boolean;
  index: number;
  data: ArrayBuffer;
  /** performance.timeOrigin + performance.now() when the frame arrived on the page. */
  arrivedAt: number;
}

export interface DecodeReport {
  codec: string;
  config: string;
  hardwareAcceleration: string;
  where: "worker" | "main";
  sent: number;
  decoded: number;
  drawn: number;
  errors: string[];
  /** Per frame, ms: decode() call to output callback. */
  decodeMs: number[];
  /** Per frame, ms: arrival on the page to drawn on the canvas. */
  arrivalToDrawMs: number[];
  /** Per frame, ms: drawImage + close. */
  drawMs: number[];
  /** Whether the last drawn frame has non-black pixels (a real decode, not a blank). */
  nonBlank: boolean;
}

export const codecStrings: Record<string, string> = {
  h264: "avc1.42E01E", // Constrained Baseline 3.0, as the fixture
  vp8: "vp8",
};

const abs = () => performance.timeOrigin + performance.now();

type Canvas = OffscreenCanvas | HTMLCanvasElement;

/** Pick a config the browser says it can decode: hardware first, then any. */
export async function pickConfig(codec: string): Promise<VideoDecoderConfig | null> {
  if (typeof VideoDecoder === "undefined") return null;
  for (const hardwareAcceleration of ["prefer-hardware", "no-preference"] as const) {
    const config: VideoDecoderConfig = {
      codec: codecStrings[codec],
      codedWidth: 320,
      codedHeight: 180,
      hardwareAcceleration,
      optimizeForLatency: true,
    };
    try {
      const r = await VideoDecoder.isConfigSupported(config);
      if (r.supported) return config;
    } catch {
      // TypeError for an unknown codec string: try the next.
    }
  }
  return null;
}

export class DecodeSink {
  readonly report: DecodeReport;
  private decoder: VideoDecoder;
  private ctx: OffscreenCanvasRenderingContext2D | CanvasRenderingContext2D;
  private pending = new Map<number, { calledAt: number; arrivedAt: number }>();
  private waitingForKey = true;

  constructor(canvas: Canvas, codec: string, config: VideoDecoderConfig, where: "worker" | "main") {
    this.report = {
      codec,
      config: config.codec,
      hardwareAcceleration: config.hardwareAcceleration ?? "no-preference",
      where,
      sent: 0,
      decoded: 0,
      drawn: 0,
      errors: [],
      decodeMs: [],
      arrivalToDrawMs: [],
      drawMs: [],
      nonBlank: false,
    };
    this.ctx = canvas.getContext("2d", { willReadFrequently: true }) as OffscreenCanvasRenderingContext2D;
    this.decoder = new VideoDecoder({
      output: (frame) => this.onFrame(frame),
      error: (e) => this.report.errors.push(String(e)),
    });
    this.decoder.configure(config);
  }

  push(f: ProbeFrame): void {
    if (this.decoder.state !== "configured") return;
    // Drop until a keyframe, as native clients drop after a gap until recovery.
    if (this.waitingForKey && !f.key) return;
    this.waitingForKey = false;
    this.pending.set(f.index, { calledAt: abs(), arrivedAt: f.arrivedAt });
    this.report.sent++;
    try {
      this.decoder.decode(new EncodedVideoChunk({ type: f.key ? "key" : "delta", timestamp: f.index, data: f.data }));
    } catch (e) {
      this.report.errors.push(String(e));
    }
  }

  private onFrame(frame: VideoFrame): void {
    const now = abs();
    const t = this.pending.get(frame.timestamp);
    this.pending.delete(frame.timestamp);
    this.report.decoded++;
    if (t) this.report.decodeMs.push(now - t.calledAt);
    const c = this.ctx.canvas;
    this.ctx.drawImage(frame, 0, 0, c.width, c.height);
    frame.close();
    const drawn = abs();
    this.report.drawn++;
    this.report.drawMs.push(drawn - now);
    if (t) this.report.arrivalToDrawMs.push(drawn - t.arrivedAt);
  }

  async finish(): Promise<DecodeReport> {
    try {
      if (this.decoder.state === "configured") await this.decoder.flush();
    } catch (e) {
      this.report.errors.push(String(e));
    }
    try {
      const c = this.ctx.canvas;
      const px = this.ctx.getImageData(0, 0, c.width, c.height).data;
      let sum = 0;
      for (let i = 0; i < px.length; i += 4 * 97) sum += px[i] + px[i + 1] + px[i + 2];
      this.report.nonBlank = sum > 0;
    } catch (e) {
      this.report.errors.push(`readback: ${e}`);
    }
    if (this.decoder.state !== "closed") this.decoder.close();
    return this.report;
  }
}
