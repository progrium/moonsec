// moonsec pairing in the browser (spec/pairing-v0.md): the client side of `moonsec pair
// client` and session admission, over a shim-web connection. The protocol itself runs in
// core/pair compiled to wasm (shim-web/pair/pair.zig, `zig build web-pair`); this file only
// moves bytes between that module and an iroh stream.
//
//   const pair = await loadPair(new URL("moonsec-pair.wasm", import.meta.url));
//   const host = await pair.pairWithTicket(endpoint, "MOONSEC1:...", { name: "Browser" });
//   // later: const conn = await endpoint.connect(host.addr, ALPN); await pair.admit(conn);

export const ALPN = "moonsec/0";
/** Application error code a host closes an unadmitted connection with. */
export const CLOSE_NOT_PAIRED = 0x5050;

export const REASONS = {
  1: "the host is not pairing right now",
  2: "the host is not offering that method",
  3: "wrong PIN or secret",
  4: "too many wrong attempts; start pairing on the host again",
  5: "the pairing window expired",
  6: "unsupported pairing version",
  7: "protocol error",
  8: "the host could not prove it holds the secret",
  9: "this device is not paired with the host",
};

const TICKET_ERRORS = { [-1]: "not a moonsec ticket", [-2]: "bad encoding", [-3]: "checksum mismatch (typo?)", [-4]: "unsupported ticket version", [-5]: "malformed ticket" };

export class PairError extends Error {
  constructor(reason, attemptsLeft) {
    super(`pairing failed: ${REASONS[reason] ?? `reason ${reason}`}`);
    this.reason = reason;
    this.attemptsLeft = attemptsLeft;
  }
}

const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

export async function loadPair(source) {
  let instance;
  if (source instanceof WebAssembly.Module) instance = await WebAssembly.instantiate(source, {});
  else if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) ({ instance } = await WebAssembly.instantiate(source, {}));
  else ({ instance } = await WebAssembly.instantiateStreaming(fetch(source), {}));
  return new Pair(instance.exports);
}

export class Pair {
  constructor(x) {
    this.x = x;
    this.ioLen = x.mp_io_len();
  }
  get #in() {
    return new Uint8Array(this.x.memory.buffer, this.x.mp_in(), this.ioLen);
  }
  #out(n) {
    return new Uint8Array(this.x.memory.buffer, this.x.mp_out(), n).slice();
  }

  /** Decodes a `MOONSEC1:` ticket: { hostId (hex), hasSecret, expires (unix s, 0 = none), addr }. */
  decodeTicket(text) {
    const b = new TextEncoder().encode(text);
    if (b.length > this.ioLen) throw new Error("ticket too long");
    this.#in.set(b);
    const r = this.x.mp_ticket_decode(b.length);
    if (r !== 0) throw new Error(`bad ticket: ${TICKET_ERRORS[r] ?? r}`);
    const hostId = hex(this.#out(this.x.mp_ticket_host_id()));
    const hasSecret = this.x.mp_ticket_has_secret() === 1;
    const expires = this.x.mp_ticket_expires();
    const addr = new TextDecoder().decode(this.#out(this.x.mp_ticket_addr()));
    return { hostId, hasSecret, expires, addr };
  }

  /** The endpoint ID (hex) core/pair derives from a 32-byte secret key. */
  idFromSecret(secret) {
    this.#in.set(secret);
    return hex(this.#out(this.x.mp_public_from_secret()));
  }

  // Feeds stream bytes into the module and steps `stepFn` until it needs more.
  async #run(stream, stepFn, onStep) {
    for (;;) {
      const r = stepFn();
      if (r === 0) {
        const chunk = await stream.read(4096, 30000);
        if (chunk === null) throw new PairError(7, -1);
        for (let off = 0; off < chunk.length; ) {
          const n = Math.min(chunk.length - off, this.ioLen);
          this.#in.set(chunk.subarray(off, off + n));
          const took = this.x.mp_push(n);
          off += took;
          if (took < n) {
            // Framer full: consume a message before pushing the rest.
            const done = await onStep(stepFn());
            if (done !== undefined) return done;
          }
        }
        continue;
      }
      const done = await onStep(r);
      if (done !== undefined) return done;
    }
  }

  /**
   * Pairs this endpoint with the host in `ticketText` (spec/pairing-v0.md, Exchange).
   * A QR ticket pairs with its secret; an address ticket needs `pin`. Resolves to
   * { hostId, hostName, addr }; keep it (and the endpoint's secret key) to start sessions.
   * Rejects with PairError (reason, attemptsLeft) when the host refuses.
   */
  async pairWithTicket(endpoint, ticketText, { pin = "", name = "moonsec web", timeoutMs = 30000 } = {}) {
    const t = this.decodeTicket(ticketText.trim());
    if (t.expires !== 0 && Date.now() / 1000 >= t.expires) throw new Error("this ticket has expired; start pairing on the host again");
    if (!t.hasSecret && !pin) throw new Error("this ticket has no secret; give the host's PIN");
    const conn = await endpoint.connect(t.addr, ALPN, timeoutMs);
    try {
      if (conn.remoteId !== t.hostId) throw new Error("the host at that address is not the one in the ticket");
      const s = await conn.openBi(10000);
      const enc = new TextEncoder();
      const pinB = enc.encode(pin);
      const nameB = enc.encode(name).subarray(0, 256);
      const idB = Uint8Array.from(endpoint.id.match(/../g), (h) => parseInt(h, 16));
      const inp = this.#in;
      inp.set(idB, 0);
      inp.set(crypto.getRandomValues(new Uint8Array(16)), 32); // nonce
      inp.set(crypto.getRandomValues(new Uint8Array(32)), 48); // secret CPace seed
      inp.set(pinB, 80);
      inp.set(nameB, 80 + pinB.length);
      const hl = this.x.mp_client_start(pinB.length, nameB.length);
      if (hl < 0) throw new Error(hl === -2 ? "bad PIN: six digits" : `cannot start pairing (${hl})`);
      await s.write(this.#out(hl), 10000);
      const result = await this.#run(s, () => this.x.mp_client_step(), async (r) => {
        if (r === -1) throw new PairError(7, -1);
        const rl = this.x.mp_reply_len();
        if (rl > 0) await s.write(this.#out(rl), 10000);
        if (r === 1) return undefined;
        if (r === 3) {
          try { s.finish(); } catch {}
          throw new PairError(this.x.mp_reason(), this.x.mp_attempts_left());
        }
        const hostName = new TextDecoder().decode(this.#out(this.x.mp_paired_name()));
        return { hostId: t.hostId, hostName, addr: t.addr };
      });
      // Finish our side and wait for the host's end, so `confirm` is delivered before closing.
      s.finish();
      while ((await s.read(4096, 10000)) !== null) {}
      return result;
    } finally {
      conn.close(0);
    }
  }

  /**
   * Asks a paired host for a session on `conn` (spec/pairing-v0.md, Admission): sends
   * `admit` on the first stream. Resolves once admitted; rejects with PairError otherwise.
   * Checking that `conn.remoteId` is a paired host is the caller's job, as on native.
   */
  async admit(conn) {
    const s = await conn.openBi(10000);
    const n = this.x.mp_admit_start();
    await s.write(this.#out(n), 10000);
    await this.#run(s, () => this.x.mp_admit_step(), async (r) => {
      if (r === -1) throw new PairError(7, -1);
      if (r === 2) throw new PairError(this.x.mp_reason(), -1);
      return true;
    });
    return s;
  }
}
