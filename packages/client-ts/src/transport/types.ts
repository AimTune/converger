/**
 * Transport abstraction. A transport carries one connection attempt to one
 * conversation and normalises whatever the wire speaks to Protocol v1 frames:
 * the native endpoint (`/socket/converger/v1`, raw frames), the Phoenix
 * Channels binding (`/socket/converger/websocket`) and the Server-Sent Events
 * fallback (`/api/v1/converger/conversations/:id/events` plus REST sends).
 *
 * The conversation session (reconnects, watermark, outbox) is the same for
 * all of them.
 *
 * @module
 */

import type { ClientFrame, ServerFrame } from "../protocol/frames.js";
import type { FetchLike } from "../rest/client.js";

/** A WebSocket constructor (the global one, or e.g. the `ws` package in old Node). */
export interface WebSocketLike {
  readonly readyState: number;
  readonly protocol: string;
  binaryType: string;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: ((event: { code: number; reason: string; wasClean?: boolean }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

/** A WebSocket constructor. */
export type WebSocketConstructor = new (url: string, protocols?: string | string[]) => WebSocketLike;

/** How a connection attempt ended. */
export interface TransportClose {
  code: number;
  reason: string;
  /** From a JSON close reason (`{"reason": "unavailable", "retryAfterMs": N}`) or an error frame. */
  retryAfterMs?: number;
  /** Whether the connection was ever established. */
  opened: boolean;
}

/** What a transport may or may not do. */
export interface TransportCapabilities {
  /** Mid-session token refresh with the `auth` frame. */
  auth: boolean;
  /** `sync {watermark}` on a live connection. */
  sync: boolean;
  /** Client `typing` and `read`. */
  signals: boolean;
  /** Needs an existing conversation id (cannot create one in the handshake). */
  requiresConversationId: boolean;
}

/** Parameters of one connection attempt. */
export interface TransportConnectParams {
  /** `https://host[:port]`. */
  baseUrl: string;
  token: string;
  conversationId?: string;
  userId?: string;
  /** Resume after this seq. */
  watermark?: number;
}

/** Callbacks a transport reports to. */
export interface TransportHandlers {
  /** The connection is established (the handshake may still be running). */
  onOpen(): void;
  /** A Protocol v1 server frame. */
  onFrame(frame: ServerFrame): void;
  /** The attempt ended; called exactly once. */
  onClose(close: TransportClose): void;
}

/** Environment a transport runs in. */
export interface TransportEnvironment {
  WebSocket: WebSocketConstructor | undefined;
  fetch: FetchLike | undefined;
}

/** One connection attempt. */
export interface Transport {
  readonly name: string;
  readonly capabilities: TransportCapabilities;
  /** Start connecting. */
  connect(params: TransportConnectParams, handlers: TransportHandlers): void;
  /** Send a client frame. Returns false when it could not be sent (not open). */
  send(frame: ClientFrame): boolean;
  /** Close the connection (onClose still fires). */
  close(code?: number, reason?: string): void;
}

/** Creates a transport for one connection attempt. */
export type TransportFactory = ((env: TransportEnvironment) => Transport) & { transportName?: string };

/** Turn `http(s)://` into `ws(s)://`. @internal */
export function toWebSocketUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "").replace(/^http(s?):\/\//i, (_m, s: string) => `ws${s}://`);
}

/** Parse a JSON close reason for `retryAfterMs`. @internal */
export function retryAfterFromReason(reason: string): number | undefined {
  if (!reason || reason[0] !== "{") return undefined;
  try {
    const parsed = JSON.parse(reason) as { retryAfterMs?: unknown };
    return typeof parsed.retryAfterMs === "number" ? parsed.retryAfterMs : undefined;
  } catch {
    return undefined;
  }
}

/** @internal */
export function requireWebSocket(env: TransportEnvironment): WebSocketConstructor {
  if (!env.WebSocket) {
    throw new Error(
      "no WebSocket implementation: use Node 22+ or a browser, or pass the `WebSocket` option (e.g. from the `ws` package)",
    );
  }
  return env.WebSocket;
}
