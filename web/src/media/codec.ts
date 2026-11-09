// WebCodecs codec strings: which codecs to offer the host (isConfigSupported), and the
// exact string for the stream once its first keyframe shows the profile and level.

import { Codec, CodecBit } from "../core";

/** Representative strings for the hello: H.264 High 4.0, HEVC Main 4.1, AV1 Main 4.0 8-bit. */
const probes: [keyof typeof CodecBit, string][] = [
  ["h264", "avc1.640028"],
  ["h264", "avc1.42E01F"],
  ["hevc", "hvc1.1.6.L123.B0"],
  ["av1", "av01.0.08M.08"],
];

export interface DecoderSupport {
  /** api.CodecSet byte for the hello. */
  codecs: number;
  /** Per codec: the hardware preference that was supported first. */
  hardware: Partial<Record<keyof typeof CodecBit, HardwareAcceleration>>;
}

/** Asks the browser which codecs it decodes (hardware preferred). H.264 is the default. */
export async function probeDecoders(width = 1920, height = 1080): Promise<DecoderSupport> {
  const out: DecoderSupport = { codecs: 0, hardware: {} };
  if (typeof VideoDecoder === "undefined") return out;
  for (const [name, codec] of probes) {
    if (out.codecs & CodecBit[name]) continue;
    for (const hardwareAcceleration of ["prefer-hardware", "no-preference"] as const) {
      try {
        const r = await VideoDecoder.isConfigSupported({ codec, codedWidth: width, codedHeight: height, hardwareAcceleration, optimizeForLatency: true });
        if (r.supported) {
          out.codecs |= CodecBit[name];
          out.hardware[name] = hardwareAcceleration;
          break;
        }
      } catch {
        // TypeError: the browser doesn't know the string.
      }
    }
  }
  return out;
}

const hex2 = (n: number) => n.toString(16).toUpperCase().padStart(2, "0");

/** NAL unit payloads of an Annex B access unit. */
export function* nalUnits(au: Uint8Array): Generator<Uint8Array> {
  let start = -1;
  for (let i = 0; i + 2 < au.length; i++) {
    if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1) {
      if (start >= 0) yield au.subarray(start, au[i - 1] === 0 ? i - 1 : i);
      start = i + 3;
      i += 2;
    }
  }
  if (start >= 0 && start < au.length) yield au.subarray(start);
}

/** Drops emulation prevention bytes (00 00 03 -> 00 00). */
function rbsp(nal: Uint8Array, max: number): Uint8Array {
  const out: number[] = [];
  let zeros = 0;
  for (let i = 0; i < nal.length && out.length < max; i++) {
    const b = nal[i];
    if (zeros >= 2 && b === 3) {
      zeros = 0;
      continue;
    }
    zeros = b === 0 ? zeros + 1 : 0;
    out.push(b);
  }
  return Uint8Array.from(out);
}

/** avc1.PPCCLL from the SPS (NAL type 7). */
export function h264String(au: Uint8Array): string | null {
  for (const nal of nalUnits(au)) {
    if ((nal[0] & 0x1f) === 7 && nal.length >= 4) return `avc1.${hex2(nal[1])}${hex2(nal[2])}${hex2(nal[3])}`;
  }
  return null;
}

/** hvc1.{profile}.{compat}.{tier}{level}.{constraints} from the SPS (NAL type 33). Untested on hardware. */
export function hevcString(au: Uint8Array): string | null {
  for (const nal of nalUnits(au)) {
    if (((nal[0] >> 1) & 0x3f) !== 33) continue;
    // 2-byte NAL header, then vps id / max sub layers / nesting (1 byte), then profile_tier_level.
    const b = rbsp(nal, 16);
    if (b.length < 15) return null;
    const ptl = b.subarray(3);
    const space = ptl[0] >> 6;
    const tier = (ptl[0] >> 5) & 1;
    const profile = ptl[0] & 0x1f;
    let compat = ((ptl[1] << 24) | (ptl[2] << 16) | (ptl[3] << 8) | ptl[4]) >>> 0;
    let rev = 0;
    for (let i = 0; i < 32; i++) {
      rev = ((rev << 1) | (compat & 1)) >>> 0;
      compat >>>= 1;
    }
    const cons = Array.from(ptl.subarray(5, 11));
    while (cons.length > 0 && cons[cons.length - 1] === 0) cons.pop();
    const level = ptl[11];
    const sp = ["", "A", "B", "C"][space];
    return [`hvc1`, `${sp}${profile}`, rev.toString(16).toUpperCase(), `${tier ? "H" : "L"}${level}`, ...cons.map(hex2)].join(".");
  }
  return null;
}

/** av01.{profile}.{level}{tier}.{depth} from the sequence header OBU. 8-bit assumed; untested. */
export function av1String(au: Uint8Array): string | null {
  let i = 0;
  while (i < au.length) {
    const h = au[i];
    const type = (h >> 3) & 0xf;
    const ext = (h >> 2) & 1;
    const hasSize = (h >> 1) & 1;
    let p = i + 1 + ext;
    let size = au.length - p;
    if (hasSize) {
      size = 0;
      for (let k = 0; k < 8; k++) {
        const b = au[p++];
        size |= (b & 0x7f) << (7 * k);
        if (!(b & 0x80)) break;
      }
    }
    if (type === 1 && size >= 2) {
      const profile = au[p] >> 5;
      const reduced = (au[p] >> 3) & 1;
      let level: number;
      let tier = 0;
      if (reduced) level = ((au[p] & 7) << 2) | (au[p + 1] >> 6);
      else {
        // timing_info_present_flag assumed 0 (encoders for streaming leave it off).
        // bits after the first 5: timing(1) initial_display_delay(1) op_cnt(5) idc(12) level(5) [tier]
        const bits = (au[p] << 24) | (au[p + 1] << 16) | (au[p + 2] << 8) | au[p + 3];
        const at = 5 + 1 + 1 + 5 + 12; // bit offset of seq_level_idx[0]
        level = (bits >>> (32 - at - 5)) & 0x1f;
        if (level > 7) tier = (bits >>> (32 - at - 6)) & 1;
      }
      return `av01.${profile}.${String(level).padStart(2, "0")}${tier ? "H" : "M"}.08`;
    }
    if (!hasSize) break;
    i = p + size;
  }
  return null;
}

/** The decoder string for an access unit of `codec` (api.Codec), or null if it has no parameter sets. */
export function codecString(codec: number, au: Uint8Array): string | null {
  switch (codec) {
    case Codec.h264:
      return h264String(au);
    case Codec.hevc:
      return hevcString(au);
    case Codec.av1:
      return av1String(au);
    default:
      return null;
  }
}
