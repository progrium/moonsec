// host.html: the demo game (demo/orb-drift.js) hosted from this tab. Query:
// ?relay=URL (repeatable; default https://<this host>:3443), ?autostart,
// ?invite=N (open a pairing window for N devices on start; default 1, 0 for none),
// ?input=everyone|owner|view, ?media=1 (also play a looping 660 Hz <audio> element, to
// show media elements stream), ?max=N (members at once),
// ?audioenc=wasm|webcodecs, ?capture=raf|stream, ?codec=h264,av1, ?bitrate=bps, ?fps=N,
// ?ltr=0 (no long-term references even where WebCodecs has them), ?loss=0.02 (test: drop
// that share of the host's datagrams), ?outage=400 (test: and everything for 400 ms every 3 s).
// The latest report is on window.moonsecHost for the tests.

import { BrowserHost } from "./host";
import type { HostReport, Invite } from "./protocol";
import type { InputPolicy } from "./core";

declare global {
  interface Window {
    moonsecHost: { report: HostReport | null; errors: string[]; host: BrowserHost | null; clientUrl: string; inviteUrl: string };
  }
}

const q = new URLSearchParams(location.search);
const relays = q.getAll("relay");
const relayUrls = relays.length > 0 ? relays : [`https://${location.hostname}:3443`];
window.moonsecHost = { report: null, errors: [], host: null, clientUrl: "", inviteUrl: "" };
const panel = document.getElementById("panel")!;
const invitePanel = document.getElementById("invite")!;
const devicesPanel = document.getElementById("devices")!;

function clientLink(ticket: string): string {
  const u = new URL("client.html", location.href);
  u.searchParams.set("ticket", ticket);
  for (const r of relayUrls) u.searchParams.append("relay", r);
  return u.href;
}

function drawQr(qr: NonNullable<Invite["qr"]>): HTMLCanvasElement {
  const scale = 4;
  const quiet = 4;
  const n = qr.size + 2 * quiet;
  const c = document.createElement("canvas");
  c.width = c.height = n * scale;
  const g = c.getContext("2d")!;
  g.fillStyle = "#fff";
  g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = "#000";
  for (let y = 0; y < qr.size; y++) for (let x = 0; x < qr.size; x++) if (qr.modules[y * qr.size + x]) g.fillRect((x + quiet) * scale, (y + quiet) * scale, scale, scale);
  return c;
}

let shownInvite = "";
function showInvite(inv: Invite | null) {
  const key = inv ? `${inv.ticket}|${inv.pin}` : "";
  if (key === shownInvite) {
    const left = invitePanel.querySelector(".left");
    if (left && inv) left.textContent = `${Math.max(0, Math.round((inv.expiresAt - Date.now()) / 1000))} s left, ${inv.pairingsLeft} device(s), ${inv.attemptsLeft} wrong PINs allowed`;
    return;
  }
  shownInvite = key;
  invitePanel.replaceChildren();
  window.moonsecHost.inviteUrl = inv?.ticket ? clientLink(inv.ticket) : "";
  if (!inv) return;
  invitePanel.append("Invite a device: open this link on it, or scan the code.\n");
  if (inv.ticket) {
    const a = document.createElement("a");
    a.href = a.textContent = clientLink(inv.ticket);
    a.target = "_blank";
    invitePanel.append(a, "\n");
    if (inv.qr) invitePanel.append(drawQr(inv.qr), "\n");
  }
  if (inv.pin) invitePanel.append(`Or open the address link and type the PIN ${inv.pin.slice(0, 3)} ${inv.pin.slice(3)}\n`);
  const left = document.createElement("span");
  left.className = "left";
  invitePanel.append(left);
}

function showDevices(host: BrowserHost, r: HostReport) {
  devicesPanel.replaceChildren();
  const online = new Map(r.members.map((m) => [m.endpointId, m]));
  if (host.paired.length === 0) return;
  devicesPanel.append("Paired devices:\n");
  for (const d of host.paired) {
    const m = online.get(d.id);
    const row = document.createElement("div");
    row.textContent = `${d.name} (${d.id.slice(0, 8)})${m ? `  ${m.state}, member ${m.id}, rtt ${(m.stats.rtt_us / 1000).toFixed(1)} ms` : ""}  `;
    const forget = document.createElement("button");
    forget.textContent = "Forget";
    forget.onclick = () => host.forget(d.id);
    const input = document.createElement("button");
    input.textContent = d.input === false ? "Allow input" : "View only";
    input.onclick = () => host.setInput(d.id, d.input === false);
    row.append(input, forget);
    devicesPanel.append(row);
  }
}

function show(r: HostReport) {
  const host = window.moonsecHost.host;
  window.moonsecHost.clientUrl = r.ticket ? clientLink(r.ticket) : "";
  const ms = (us: number) => (us < 0 ? "-" : (us / 1000).toFixed(1));
  const mu = r.multi;
  const lines = [
    `state ${r.state}  members ${r.members.length}  sessions ${r.sessions}  codec ${r.codec}  audio ${r.audio.encoder}${host ? `  media elements ${host.media.routed}` : ""}`,
    r.ticket ? `address (for paired devices, or with the PIN): ${window.moonsecHost.clientUrl}` : "(waiting for the relay)",
    `pairing: ${r.pairing.paired} paired, ${r.pairing.failed} failed, ${r.pairing.admitted} admitted, ${r.pairing.refused} refused${r.pairing.lastFailure ? ` (last: ${r.pairing.lastFailure})` : ""}`,
  ];
  if (mu) lines.push(`frames ${mu.frames} (keyframes ${mu.keyframes})  inputs ${mu.inputs_applied} applied, ${mu.inputs_dropped} dropped  audio frames ${mu.audio_frames}`);
  for (const m of r.members) {
    const st = m.stats;
    lines.push(`  ${m.name}: ${m.state}  ${(st.bytes / 1e6).toFixed(1)} MB  NACKs ${st.nacks} -> ${st.retransmits}  recovery ${st.recovery_requests}  rtt ${ms(st.rtt_us)} ms  encode p50 ${ms(st.stages.encode.p50)} ms`);
  }
  lines.push(`encoder: busy drops ${r.encoder.busyDrops}, timeouts ${r.encoder.timeouts}${r.encoder.errors.length ? ", " + r.encoder.errors.join("; ") : ""}`);
  panel.textContent = lines.join("\n");
  showInvite(r.invite);
  if (host) showDevices(host, r);
}

async function start() {
  document.getElementById("start")!.remove();
  // This click is the user gesture the game's audio needs: remote clicks are synthetic.
  for (const ctx of window.__moonsecHost.contexts) void ctx.resume();
  const host = await BrowserHost.start({
    canvas: document.getElementById("game") as HTMLCanvasElement,
    relayUrls,
    base: new URL("dist/", location.href).href,
    pkgUrl: new URL("pkg/", location.href).href,
    name: "orb drift (browser host)",
    input: (q.get("input") as InputPolicy | null) ?? "everyone",
    maxMembers: Number(q.get("max") ?? 8),
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
  window.moonsecHost.host = host;
  if (q.get("media") === "1") playTone();
  const n = Number(q.get("invite") ?? 1);
  if (n > 0) host.invite({ pairings: n });
  const btn = document.getElementById("invite-btn") as HTMLButtonElement;
  btn.hidden = false;
  btn.onclick = () => host.invite({ pairings: 1 });
}

/** A looping 660 Hz tone in an <audio> element (a same-origin blob: WAV). */
function playTone() {
  const rate = 48000;
  const n = rate; // 1 s
  const buf = new ArrayBuffer(44 + n * 2);
  const dv = new DataView(buf);
  const str = (o: number, t: string) => [...t].forEach((c, i) => dv.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF");
  dv.setUint32(4, 36 + n * 2, true);
  str(8, "WAVEfmt ");
  dv.setUint32(16, 16, true);
  dv.setUint16(20, 1, true);
  dv.setUint16(22, 1, true);
  dv.setUint32(24, rate, true);
  dv.setUint32(28, rate * 2, true);
  dv.setUint16(32, 2, true);
  dv.setUint16(34, 16, true);
  str(36, "data");
  dv.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i++) dv.setInt16(44 + i * 2, Math.round(Math.sin((2 * Math.PI * 660 * i) / rate) * 8000), true);
  const el = document.createElement("audio");
  el.id = "tone";
  el.loop = true;
  el.src = URL.createObjectURL(new Blob([buf], { type: "audio/wav" }));
  document.body.append(el);
  void el.play().catch((e) => window.moonsecHost.errors.push(`tone: ${e}`));
}

document.getElementById("start")!.addEventListener("click", () => void start());
if (q.has("autostart")) void start();
