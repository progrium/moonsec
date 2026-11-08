// host.html: the demo game (demo/orb-drift.js) hosted from this tab. Query:
// ?relay=URL (repeatable; default https://<this host>:3443), ?autostart,
// ?audioenc=wasm|webcodecs, ?capture=raf|stream, ?codec=h264,av1, ?bitrate=bps, ?fps=N,
// ?ltr=0 (no long-term references even where WebCodecs has them), ?loss=0.02 (test: drop
// that share of the host's datagrams), ?outage=400 (test: and everything for 400 ms every 3 s).
// The latest report is on window.moonsecHost for the tests.

import { BrowserHost } from "./host";
import type { HostReport } from "./protocol";

declare global {
  interface Window {
    moonsecHost: { report: HostReport | null; errors: string[]; host: BrowserHost | null; clientUrl: string };
  }
}

const q = new URLSearchParams(location.search);
const relays = q.getAll("relay");
const relayUrls = relays.length > 0 ? relays : [`https://${location.hostname}:3443`];
window.moonsecHost = { report: null, errors: [], host: null, clientUrl: "" };
const panel = document.getElementById("panel")!;

function show(r: HostReport) {
  const st = r.stats;
  const client = new URL("client.html", location.href);
  client.searchParams.set("ticket", r.ticket);
  for (const u of relayUrls) client.searchParams.append("relay", u);
  window.moonsecHost.clientUrl = client.href;
  const ms = (us: number) => (us < 0 ? "-" : (us / 1000).toFixed(1));
  const lines = [
    `state ${r.state}${r.end && r.end !== "none" ? ` (${r.end})` : ""}  sessions ${r.sessions}  codec ${r.codec}  audio ${r.audio.encoder}`,
    `client: ${r.ticket ? "" : "(waiting for the relay)"}`,
  ];
  panel.textContent = lines.join("\n");
  if (r.ticket) {
    const a = document.createElement("a");
    a.href = client.href;
    a.target = "_blank";
    a.textContent = client.href;
    panel.append(a);
  }
  if (st) {
    panel.append(
      "\n" +
        [
          `frames ${st.frames} (keyframes ${st.keyframes})  ${(st.bytes / 1e6).toFixed(1)} MB  NACKs ${st.nacks} -> ${st.retransmits}  recovery ${st.recovery_requests}`,
          `rtt ${ms(st.rtt_us)} ms  inputs ${st.inputs_applied}  audio frames ${st.audio_frames}`,
          `capture p50 ${ms(st.stages.capture.p50)}  encode p50 ${ms(st.stages.encode.p50)} p99 ${ms(st.stages.encode.p99)}  input p50 ${ms(st.stages.input.p50)} ms`,
          `encoder: busy drops ${r.encoder.busyDrops}, timeouts ${r.encoder.timeouts}${r.encoder.errors.length ? ", " + r.encoder.errors.join("; ") : ""}`,
        ].join("\n"),
    );
  }
}

async function start() {
  document.getElementById("start")!.remove();
  // This click is the user gesture the game's audio needs: remote clicks are synthetic.
  for (const ctx of window.__moonsecHost.contexts) void ctx.resume();
  window.moonsecHost.host = await BrowserHost.start({
    canvas: document.getElementById("game") as HTMLCanvasElement,
    relayUrls,
    base: new URL("dist/", location.href).href,
    pkgUrl: new URL("pkg/", location.href).href,
    audioEncoder: q.get("audioenc") === "webcodecs" ? "webcodecs" : "wasm",
    capture: q.get("capture") === "stream" ? "stream" : "raf",
    codecs: (q.get("codec") ?? "h264,av1").split(","),
    bitrateBps: Number(q.get("bitrate") ?? 6_000_000),
    fps: Number(q.get("fps") ?? 60),
    ltr: q.get("ltr") !== "0",
    loss: Number(q.get("loss") ?? 0),
    outageMs: Number(q.get("outage") ?? 0),
    onReport: (r) => {
      window.moonsecHost.report = r;
      show(r);
    },
    onError: (e) => {
      window.moonsecHost.errors.push(e);
      console.error(e);
    },
  });
}

document.getElementById("start")!.addEventListener("click", () => void start());
if (q.has("autostart")) void start();
