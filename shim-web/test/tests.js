// In-page tests for shim-web, driven by run.mjs through Playwright. Each export takes the
// iroh-web module, the pairing module and an options object, and returns plain JSON.
// The native peer is `shim-echo serve` (tools/shim-echo/main.zig) or `moonsec`.

import { IrohTransport } from "../js/transport.js";

const ECHO_ALPN = "moonsec/s1-echo/0";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => performance.now();

function pct(sorted, p) {
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}

async function bind(iroh, relayUrl, extra = {}) {
  const t0 = now();
  const ep = await iroh.Endpoint.bind({ relayUrls: [relayUrl], ...extra });
  await ep.online(15000);
  return { ep, onlineMs: now() - t0 };
}

async function dial(iroh, o) {
  const { ep, onlineMs } = await bind(iroh, o.relayUrl);
  const t0 = now();
  const conn = await ep.connect(o.ticket, ECHO_ALPN, 30000);
  return { ep, conn, onlineMs, connectMs: now() - t0 };
}

/** Datagram echo (sequential pings, RTT percentiles) and a bidirectional stream echo. */
export async function echo(iroh, _pair, o) {
  const { ep, conn, onlineMs, connectMs } = await dial(iroh, o);
  try {
    const count = o.count ?? 200;
    const size = Math.min(o.size ?? 1150, conn.maxDatagramSize());
    const rtts = [];
    let mismatches = 0;
    let lost = 0;
    const buf = new Uint8Array(size);
    for (let seq = 0; seq < count; seq++) {
      for (let k = 0; k < size; k++) buf[k] = (k * 31 + seq) & 0xff;
      new DataView(buf.buffer).setUint32(0, seq, true);
      let ok = false;
      for (let attempt = 0; attempt < 3 && !ok; attempt++) {
        const t0 = now();
        conn.sendDatagram(buf);
        try {
          for (;;) {
            const d = await conn.recvDatagram(1000);
            if (d.length >= 4 && new DataView(d.buffer, d.byteOffset).getUint32(0, true) === seq) {
              rtts.push(now() - t0);
              if (d.length !== size || d.some((b, k) => b !== buf[k])) mismatches++;
              ok = true;
              break;
            }
          }
        } catch (e) {
          if (e.code !== "timeout") throw e;
        }
      }
      if (!ok) lost++;
    }
    rtts.sort((a, b) => a - b);

    // Stream echo: 256 KiB in 16 KiB writes, read back and compare.
    const s = await conn.openBi(10000);
    const total = o.streamBytes ?? 256 * 1024;
    const data = new Uint8Array(total);
    for (let k = 0; k < total; k++) data[k] = (k * 7 + 3) & 0xff;
    const t0 = now();
    const reader = (async () => {
      const got = new Uint8Array(total);
      let n = 0;
      for (;;) {
        const c = await s.read(65536, 15000);
        if (c === null) break;
        got.set(c.subarray(0, Math.min(c.length, total - n)), n);
        n += c.length;
      }
      return { n, ok: n === total && got.every((b, k) => b === data[k]) };
    })();
    for (let off = 0; off < total; off += 16384) await s.write(data.subarray(off, off + 16384), 15000);
    s.finish();
    const back = await reader;
    const streamMs = now() - t0;

    // The web client's Transport over the same connection: a burst of 100 echoed back.
    const tr = new IrohTransport(conn);
    let trGot = 0;
    tr.onDatagram = (d) => { if (d[0] === 0x54) trGot++; };
    for (let k = 0; k < 100; k++) tr.send(new Uint8Array([0x54, k, 0, 0]));
    const td = now() + 3000;
    while (trGot < 100 && now() < td) await sleep(5);
    tr.closed = true;

    return {
      id: ep.id,
      transport: { sent: 100, got: trGot },
      remoteId: conn.remoteId,
      onlineMs,
      connectMs,
      maxDatagramSize: conn.maxDatagramSize(),
      datagrams: { count, size, ok: rtts.length, lost, mismatches, rttMs: { min: rtts[0], p50: pct(rtts, 50), p90: pct(rtts, 90), p99: pct(rtts, 99), max: rtts[rtts.length - 1] } },
      stream: { bytes: total, echoed: back.n, intact: back.ok, ms: streamMs },
      stats: conn.stats(),
      paths: conn.pathStats(),
      events: drainEvents(conn),
    };
  } finally {
    conn.close(0);
    await ep.close();
  }
}

function drainEvents(conn) {
  const out = [];
  for (let e = conn.pollEvent(); e !== undefined; e = conn.pollEvent()) out.push(e);
  return out;
}

/**
 * Datagram throughput through the relay at each offered rate, both directions:
 * down = native -> browser ("BLST"), up = browser -> native ("SINK", counted by "STAT").
 */
export async function rate(iroh, _pair, o) {
  const { ep, conn } = await dial(iroh, o);
  try {
    const size = Math.min(o.size ?? 1150, conn.maxDatagramSize());
    const ms = o.ms ?? 2000;
    const rows = [];
    for (const kbps of o.ratesKbps ?? [2000, 10000, 25000, 50000]) {
      // Down.
      conn.drainDatagrams();
      const cmd = new Uint8Array(16);
      cmd.set(new TextEncoder().encode("BLST"));
      const dv = new DataView(cmd.buffer);
      dv.setUint32(4, kbps, true);
      dv.setUint32(8, ms, true);
      dv.setUint32(12, size, true);
      conn.sendDatagram(cmd);
      let got = 0, bytes = 0, sent = -1, first = 0, last = 0;
      const deadline = now() + ms + 3000;
      while (now() < deadline) {
        let d;
        try { d = await conn.recvDatagram(Math.max(1, Math.ceil(deadline - now()))); } catch (e) { if (e.code === "timeout") break; throw e; }
        const tag = String.fromCharCode(d[0], d[1], d[2], d[3]);
        if (tag === "BDAT") {
          if (got === 0) first = now();
          last = now();
          got++;
          bytes += d.length;
        } else if (tag === "BEND") {
          sent = new DataView(d.buffer, d.byteOffset).getUint32(4, true);
          await sleep(100);
          for (const x of conn.drainDatagrams()) if (x[0] === 0x42 && x[1] === 0x44) { got++; bytes += x.length; }
          break;
        }
      }
      const downSecs = Math.max(0.001, (last - first) / 1000);
      // Up.
      conn.sendDatagram(new TextEncoder().encode("STAT"));
      await sleep(200);
      conn.drainDatagrams();
      const up = new Uint8Array(size);
      up.set(new TextEncoder().encode("SINK"));
      const interval = (size * 8) / kbps; // ms per datagram
      const t0 = now();
      let upSent = 0;
      while (now() - t0 < ms) {
        const due = Math.floor((now() - t0) / interval) + 1;
        while (upSent < due) {
          conn.sendDatagram(up);
          upSent++;
        }
        await sleep(1);
      }
      const upSecs = (now() - t0) / 1000;
      await sleep(300);
      conn.sendDatagram(new TextEncoder().encode("STAT"));
      let upGot = -1, upBytes = 0;
      const sd = now() + 2000;
      while (now() < sd) {
        let d;
        try { d = await conn.recvDatagram(500); } catch (e) { if (e.code === "timeout") continue; throw e; }
        if (d.length >= 20 && String.fromCharCode(d[0], d[1], d[2], d[3]) === "STAT") {
          const v = new DataView(d.buffer, d.byteOffset);
          upGot = Number(v.getBigUint64(4, true));
          upBytes = Number(v.getBigUint64(12, true));
          break;
        }
      }
      rows.push({
        offeredKbps: kbps,
        down: { sent, got, lossPct: sent > 0 ? (100 * (sent - got)) / sent : null, kbps: Math.round((bytes * 8) / downSecs / 1000) },
        up: { sent: upSent, got: upGot, lossPct: upGot >= 0 ? (100 * (upSent - upGot)) / upSent : null, kbps: Math.round((upBytes * 8) / upSecs / 1000) },
      });
    }
    return { size, ms, rows, stats: conn.stats() };
  } finally {
    conn.close(0);
    await ep.close();
  }
}

/** Pairs a fresh browser key with `moonsec pair host` through its QR ticket (or PIN). */
export async function pairWithHost(iroh, pair, o) {
  const { ep } = await bind(iroh, o.relayUrl);
  try {
    const t0 = now();
    const host = await pair.pairWithTicket(ep, o.ticket, { name: o.name ?? "headless browser", pin: o.pin ?? "" });
    const secret = ep.secretKey();
    return { id: ep.id, idFromCore: pair.idFromSecret(secret), secretKey: Array.from(secret), host, ms: now() - t0 };
  } catch (e) {
    return { error: e.message, reason: e.reason, attemptsLeft: e.attemptsLeft };
  } finally {
    await ep.close();
  }
}

/** Dials `moonsec peer iroh host --state-dir` and asks for a session with the given key. */
export async function admit(iroh, pair, o) {
  const opts = o.secretKey ? { secretKey: new Uint8Array(o.secretKey) } : {};
  const { ep } = await bind(iroh, o.relayUrl, opts);
  try {
    const conn = await ep.connect(o.ticket, "moonsec/0", 30000);
    const res = { id: ep.id, remoteId: conn.remoteId };
    try {
      await pair.admit(conn);
      res.admitted = true;
      // The host's session starts after `admitted`: count what arrives for a moment.
      const t0 = now();
      let n = 0, bytes = 0;
      while (now() - t0 < (o.listenMs ?? 1000)) {
        try {
          const d = await conn.recvDatagram(100);
          n++;
          bytes += d.length;
        } catch (e) {
          if (e.code !== "timeout") break;
        }
      }
      res.datagramsAfterAdmit = n;
      res.bytesAfterAdmit = bytes;
    } catch (e) {
      res.admitted = false;
      res.error = e.message;
      res.reason = e.reason;
    }
    conn.close(0);
    return res;
  } finally {
    await ep.close();
  }
}
