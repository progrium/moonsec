import type { Connection, Endpoint, BiStream } from "../pkg/iroh_web.js";

export declare const ALPN: "moonsec/0";
export declare const CLOSE_NOT_PAIRED: number;
export declare const REASONS: Record<number, string>;
export declare class PairError extends Error {
  readonly reason: number;
  readonly attemptsLeft: number;
}
export interface PairedHost {
  hostId: string;
  hostName: string;
  addr: string;
}
export declare function loadPair(source: URL | string | ArrayBuffer | ArrayBufferView | WebAssembly.Module): Promise<Pair>;
export declare class Pair {
  decodeTicket(text: string): { hostId: string; hasSecret: boolean; expires: number; addr: string };
  idFromSecret(secret: Uint8Array): string;
  pairWithTicket(endpoint: Endpoint, ticketText: string, opts?: { pin?: string; name?: string; timeoutMs?: number }): Promise<PairedHost>;
  admit(conn: Connection): Promise<BiStream>;
}
