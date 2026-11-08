// Decode and draw in a Worker with OffscreenCanvas (design, "Rendering").
import { DecodeSink, pickConfig, ProbeFrame } from "./decode.js";

let sink: DecodeSink | null = null;

self.onmessage = async (ev: MessageEvent) => {
  const m = ev.data;
  if (m.type === "init") {
    if (typeof VideoDecoder === "undefined") return postMessage({ type: "unsupported", why: "no VideoDecoder in workers" });
    const config = await pickConfig(m.codec);
    if (!config) return postMessage({ type: "unsupported", why: `${m.codec} not supported` });
    sink = new DecodeSink(m.canvas as OffscreenCanvas, m.codec, config, "worker");
    postMessage({ type: "ready" });
  } else if (m.type === "frame") {
    sink?.push(m.frame as ProbeFrame);
  } else if (m.type === "finish") {
    postMessage({ type: "report", report: sink ? await sink.finish() : null });
  }
};
