// client.html: the web client against the test host (e2e/media-host.mjs). Query:
// ?ws=URL (default: this server's /ws), ?seconds=N (leave after N s of streaming),
// ?autostart (start without a click; test browsers allow audio without a gesture),
// ?mouse=auto|relative|absolute, ?ticket=MOONSEC1:...&relay=URL (dial a host over iroh through that relay instead;
// host.html prints the link: with the invite's ticket this device pairs, with the address
// ticket it pairs by PIN (?pin=123456 or typed) unless it already paired), ?name=N (this
// device's name for the host), ?probe (report changes of the pixel at (8, 8), the demo game's latency probe),
// ?loss=0.05&outage=2000:300 (passed to the test host's /ws: drop that share of host
// datagrams, and everything for 300 ms at 2 s).
// The latest report is on window.moonsec for the tests.

import { WebClient } from "./client";
import type { PairedHost, ProbeEvent, StatsMsg } from "./protocol";

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

// This device's identity and the hosts it paired with, kept in this browser profile. Two
// tabs of one profile share the identity: hosts see them as one device.
function store(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}
const hex = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
function deviceKey(): Uint8Array {
  const s = store();
  const have = s?.getItem("moonsec.client.key");
  if (have && /^[0-9a-f]{64}$/.test(have)) return Uint8Array.from(have.match(/../g)!, (x) => parseInt(x, 16));
  const key = crypto.getRandomValues(new Uint8Array(32));
  try {
    s?.setItem("moonsec.client.key", hex(key));
  } catch {
    /* not kept: this device pairs again next time */
  }
  return key;
}
function pairedHosts(): PairedHost[] {
  try {
    const v = JSON.parse(store()?.getItem("moonsec.client.hosts") ?? "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}
function savePaired(h: PairedHost) {
  try {
    store()?.setItem("moonsec.client.hosts", JSON.stringify([...pairedHosts().filter((x) => x.hostId !== h.hostId), h]));
  } catch {
    /* not kept */
  }
}
function askPin(info: { error: string; attemptsLeft: number }): Promise<string> {
  const form = document.getElementById("pin") as HTMLFormElement;
  const msg = document.getElementById("pin-msg")!;
  const input = form.querySelector("input")!;
  msg.textContent = info.error ? `${info.error}${info.attemptsLeft >= 0 ? ` (${info.attemptsLeft} attempts left)` : ""}` : "Type the PIN the host shows";
  form.hidden = false;
  input.value = "";
  input.focus();
  return new Promise((resolve) => {
    form.onsubmit = (e) => {
      e.preventDefault();
      form.hidden = true;
      resolve(input.value);
    };
  });
}

async function start() {
  document.getElementById("start")!.remove();
  window.moonsec.client = await WebClient.start({
    base: new URL("dist/", location.href).href,
    wsUrl,
    canvas: document.getElementById("video") as HTMLCanvasElement,
    overlay: document.getElementById("overlay")!,
    seconds: Number(q.get("seconds") ?? 0),
    relayed: q.get("relayed") !== "0",
    iroh: ticket
      ? {
          ticket,
          relayUrls: q.getAll("relay"),
          pkgUrl: new URL("pkg/", location.href).href,
          secretKey: deviceKey(),
          hosts: pairedHosts(),
          name: q.get("name") ?? `web client (${navigator.platform || "browser"})`,
          ...(q.has("pin") ? { pin: q.get("pin")! } : {}),
        }
      : undefined,
    onPin: askPin,
    onPaired: savePaired,
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
