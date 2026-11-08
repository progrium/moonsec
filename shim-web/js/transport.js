// shim-web as the web client's datagram Transport (web/src/transport.ts: send, onDatagram,
// close). The web client gets a connection that pairing admitted (pair.js) and wraps it:
//
//   const conn = await endpoint.connect(host.addr, ALPN);
//   await pair.admit(conn);
//   const t = new IrohTransport(conn);
//   t.onDatagram = (d) => core.onDatagram(d);
export class IrohTransport {
  /** @param conn a shim-web Connection */
  constructor(conn) {
    this.conn = conn;
    this.onDatagram = null;
    this.closed = false;
    this.#pump();
  }

  // One awaited datagram, then everything else already queued, so a burst costs one
  // promise rather than one per datagram.
  async #pump() {
    while (!this.closed) {
      let first;
      try {
        first = await this.conn.recvDatagram();
      } catch {
        this.closed = true;
        break;
      }
      this.onDatagram?.(first);
      for (const d of this.conn.drainDatagrams()) this.onDatagram?.(d);
    }
  }

  /** Never blocks; a full send buffer evicts the oldest datagrams (counted in conn.stats()). */
  send(datagram) {
    if (!this.closed) this.conn.sendDatagram(datagram);
  }

  close(code = 0) {
    this.closed = true;
    this.conn.close(code);
  }
}
