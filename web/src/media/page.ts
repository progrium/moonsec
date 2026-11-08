// client.html: the web client against the test host (e2e/media-host.mjs). Query:
// ?ws=URL (default: this server's /ws), ?seconds=N (leave after N s of streaming),
// ?autostart (start without a click; test browsers allow audio without a gesture),
// ?mouse=auto|relative|absolute, ?ticket=T&relay=URL (dial a host over iroh through that relay instead; host.html prints
// the link), ?probe (report changes of the pixel at (8, 8), the demo game's latency probe),
// ?loss=0.05&outage=2000:300 (passed to the test host's /ws: drop that share of host
// datagrams, and everything for 300 ms at 2 s).
// The latest report is on window.moonsec for the tests.

import { WebClient } from "./client";
import type { ProbeEvent, StatsMsg } from "./protocol";

declare global {
  interface Window {
    moonsec: { stats: StatsMsg | null; errors: string[]; client: WebClient | null; probe: ProbeEvent[] };
  }
}

const q = new URLSearchParams(location.search);
const wsQuery = new URLSearchParams();
for (const k of ["loss", "outage", "seed"]) if (q.has(k)) wsQuery.set(k, q.get(k)!);
const wsUrl = q.get("ws") ?? `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws?${wsQuery}`;
window.moonsec = { stats: null, errors: [], client: null, probe: [] };
const ticket = q.get("ticket");

async function start() {
  document.getElementById("start")!.remove();
  window.moonsec.client = await WebClient.start({
    base: new URL("dist/", location.href).href,
    wsUrl,
    canvas: document.getElementById("video") as HTMLCanvasElement,
    overlay: document.getElementById("overlay")!,
    seconds: Number(q.get("seconds") ?? 0),
    relayed: q.get("relayed") !== "0",
    iroh: ticket ? { ticket, relayUrls: q.getAll("relay"), pkgUrl: new URL("pkg/", location.href).href } : undefined,
    probe: q.has("probe") ? { x: 8, y: 8 } : undefined,
    mouseMode: (q.get("mouse") as "auto" | "relative" | "absolute" | null) ?? undefined,
    onStats: (s) => {
      window.moonsec.stats = s;
      window.moonsec.probe.push(...s.probe);
    },
    onError: (e) => {
      window.moonsec.errors.push(e);
      console.error(e);
    },
  });
}

document.getElementById("start")!.addEventListener("click", () => void start());
if (q.has("autostart")) void start();
