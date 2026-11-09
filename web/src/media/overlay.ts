// The latency overlay (as platform/client/common/overlay.zig draws it natively): stream
// line, path line with the relay badge, and per-stage last / p50 / p99 in ms.

import { stageNames } from "../core";
import type { StatsMsg } from "./protocol";

const ms = (us: number) => (us < 0 ? "-" : (us / 1000).toFixed(1));
const labels: Record<string, string> = { capture: "CAP", encode: "ENC", network: "NET", decode: "DEC", present: "PRES", total: "TOT", input: "INPUT" };

export function overlayText(m: StatsMsg): string {
  const o = m.overlay;
  const c = m.config;
  const lines: string[] = [];
  const badge = o.relayed ? "RELAY" : "DIRECT";
  lines.push(`MOONSEC  ${c ? `${c.width}x${c.height} ${c.fps} FPS` : m.state.toUpperCase()}  ${(o.bitrateBps / 1e6).toFixed(1)} MBPS  ${badge}`);
  lines.push(`RTT ${ms(o.rttUs)}  LOSS ${(o.loss * 100).toFixed(1)}%  FREEZE ${o.freezes}${o.clockSynced ? "" : "  CLOCK SYNCING"}`);
  lines.push(`${m.video.codec ?? "-"} ${m.video.hardware}`);
  lines.push("STAGE    LAST    P50    P99");
  for (const n of stageNames) {
    const s = o.stages[n];
    if (n === "input" && s.count === 0) continue;
    lines.push(`${labels[n].padEnd(6)}${ms(s.last).padStart(7)}${ms(s.p50).padStart(7)}${ms(s.p99).padStart(7)}`);
  }
  lines.push(`DROP ${m.stats.frames_dropped + m.stats.frames_lost}  FRAMES ${m.stats.frames_presented}  AUDIO ${m.audio.rendered}`);
  return lines.join("\n");
}

export function renderOverlay(el: HTMLElement, m: StatsMsg): void {
  el.textContent = overlayText(m);
  el.dataset.relayed = String(m.overlay.relayed);
}
