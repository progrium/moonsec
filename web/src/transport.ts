// The web client's view of a transport: unreliable datagrams both ways, each one a
// whole wire-v0 message (envelope included). shim-web (iroh over a relay) implements it
// in production; tests use WebSocketTransport against web/e2e's stub host.

export interface Transport {
  /** Send one datagram. May drop it (datagrams are unreliable). */
  send(datagram: Uint8Array): void;
  /** Called for every datagram received. */
  onDatagram: ((datagram: Uint8Array) => void) | null;
  close(): void;
}

/**
 * Datagrams carried as binary WebSocket messages. Test-only: a WebSocket is reliable
 * and ordered, so the stub host simulates loss on its side.
 */
export class WebSocketTransport implements Transport {
  onDatagram: ((datagram: Uint8Array) => void) | null = null;
  private ws: WebSocket;

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.binaryType = "arraybuffer";
    ws.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) this.onDatagram?.(new Uint8Array(ev.data));
    };
  }

  static connect(url: string): Promise<WebSocketTransport> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.onopen = () => resolve(new WebSocketTransport(ws));
      ws.onerror = () => reject(new Error(`WebSocket ${url} failed`));
    });
  }

  send(datagram: Uint8Array): void {
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(datagram);
  }

  close(): void {
    this.ws.close();
  }
}

/** The transport-wide envelope sequence counter (spec/wire-v0.md), one per direction. */
export class EnvelopeSeq {
  private next = 0;
  take(): number {
    const s = this.next;
    this.next = (this.next + 1) >>> 0;
    return s;
  }
}
