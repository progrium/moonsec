// client.html: the web client against the test host (e2e/media-host.mjs). Query:
// ?ws=URL (default: this server's /ws), ?seconds=N (leave after N s of streaming),
// ?autostart (start without a click; test browsers allow audio without a gesture),
// ?loss=0.05&outage=2000:300 (passed to the test host's /ws: drop that share of host
// datagrams, and everything for 300 ms at 2 s).
// The latest report is on window.moonsec for the tests.

import { WebClient } from "./client";
import type { StatsMsg } from "./protocol";

declare global {
  interface Window {
    moonsec: { stats: StatsMsg | null; errors: string[]; client: WebClient | null };
  }
}

const q = new URLSearchParams(location.search);
const wsQuery = new URLSearchParams();
for (const k of ["loss", "outage", "seed"]) if (q.has(k)) wsQuery.set(k, q.get(k)!);
const wsUrl = q.get("ws") ?? `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws?${wsQuery}`;
window.moonsec = { stats: null, errors: [], client: null };

async function start() {
  document.getElementById("start")!.remove();
  window.moonsec.client = await WebClient.start({
    base: new URL("dist/", location.href).href,
    wsUrl,
    canvas: document.getElementById("video") as HTMLCanvasElement,
    overlay: document.getElementById("overlay")!,
    seconds: Number(q.get("seconds") ?? 0),
    relayed: q.get("relayed") !== "0",
    onStats: (s) => (window.moonsec.stats = s),
    onError: (e) => {
      window.moonsec.errors.push(e);
      console.error(e);
    },
  });
}

document.getElementById("start")!.addEventListener("click", () => void start());
if (q.has("autostart")) void start();
