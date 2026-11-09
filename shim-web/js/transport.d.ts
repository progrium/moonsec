import type { Connection } from "../pkg/iroh_web.js";

/** shim-web as web/src/transport.ts's Transport. */
export declare class IrohTransport {
  constructor(conn: Connection);
  readonly conn: Connection;
  onDatagram: ((datagram: Uint8Array) => void) | null;
  readonly closed: boolean;
  send(datagram: Uint8Array): void;
  close(code?: number): void;
}
