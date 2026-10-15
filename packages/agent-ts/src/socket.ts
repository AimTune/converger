/**
 * One connection attempt to the native endpoint with a channel-scoped token:
 * open the WebSocket with subprotocol `converger.v1`, send `hello`, keep the
 * connection alive with `ping` and drop it when the server goes silent.
 *
 * The token travels in `hello.token` (spec section 3.1), which works with the
 * global WebSocket of Node 22+ and browsers (they cannot set headers) as well
 * as with the `ws` package.
 *
 * @module
 */

import { SUBPROTOCOL, type HelloFrame } from "./frames.js";

/** The subset of the WebSocket API the SDK uses (the global one, or the `ws` package). */
export interface WebSocketLike {
  readonly readyState: number;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: ((event: { code: number; reason: string }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

/** A WebSocket constructor. */
export type WebSocketConstructor = new (url: string, protocols?: string | string[]) => WebSocketLike;

/** How a connection attempt ended. */
export interface SocketClose {
  code: number;
  reason: string;
  /** Whether the WebSocket was ever open. */
  opened: boolean;
  /** From a JSON close reason (`{"reason": "unavailable", "retryAfterMs": N}`) or a preceding error frame. */
  retryAfterMs?: number;
}

/** @internal */
export interface SocketHandlers {
  onOpen(): void;
  onMessage(message: Record<string, unknown>): void;
  onClose(close: SocketClose): void;
}

/** Client-side close code for a connection the server stopped answering on. */
export const CLIENT_IDLE_CLOSE = 4000;

const OPEN = 1;

/** @internal */
export interface SocketOptions {
  url: string;
  WebSocket: WebSocketConstructor;
  hello: HelloFrame;
  connectTimeoutMs: number;
  livenessGraceMs: number;
}

/** @internal */
export class AgentSocket {
  readonly #options: SocketOptions;
  readonly #handlers: SocketHandlers;
  #socket: WebSocketLike | undefined;
  #opened = false;
  #closed = false;
  #welcomed = false;
  #timer: ReturnType<typeof setInterval> | undefined;
  #connectTimer: ReturnType<typeof setTimeout> | undefined;
  #idleTimeoutMs = 60_000;
  #lastIn = 0;
  #lastOut = 0;
  #pings = 0;
  #retryAfterMs: number | undefined;

  constructor(options: SocketOptions, handlers: SocketHandlers) {
    this.#options = options;
    this.#handlers = handlers;
  }

  get open(): boolean {
    return !this.#closed && this.#socket?.readyState === OPEN;
  }

  connect(): void {
    let socket: WebSocketLike;
    try {
      socket = new this.#options.WebSocket(this.#options.url, [SUBPROTOCOL]);
    } catch (error) {
      queueMicrotask(() => this.#finish(1006, error instanceof Error ? error.message : "connect failed"));
      return;
    }
    this.#socket = socket;
    this.#connectTimer = setTimeout(() => this.close(CLIENT_IDLE_CLOSE, "connect timeout"), this.#options.connectTimeoutMs);

    socket.onopen = () => {
      this.#opened = true;
      this.#lastIn = Date.now();
      this.send(this.#options.hello);
      this.#timer = setInterval(() => this.#tick(), 1_000);
      this.#handlers.onOpen();
    };
    socket.onmessage = (event) => {
      this.#lastIn = Date.now();
      if (typeof event.data !== "string") return;
      let message: unknown;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (typeof message !== "object" || message === null || Array.isArray(message)) return;
      const record = message as Record<string, unknown>;
      if (record["type"] === "welcome") {
        this.#welcomed = true;
        if (this.#connectTimer) clearTimeout(this.#connectTimer);
        const limits = (record["data"] as { limits?: { idleTimeoutMs?: unknown } } | undefined)?.limits;
        if (typeof limits?.idleTimeoutMs === "number" && limits.idleTimeoutMs > 0) this.#idleTimeoutMs = limits.idleTimeoutMs;
      } else if (record["type"] === "error") {
        const retry = (record["data"] as { retryAfterMs?: unknown } | undefined)?.retryAfterMs;
        if (typeof retry === "number") this.#retryAfterMs = retry;
      }
      this.#handlers.onMessage(record);
    };
    socket.onclose = (event) => this.#finish(event.code, event.reason ?? "");
    socket.onerror = () => {
      // A close event always follows.
    };
  }

  get welcomed(): boolean {
    return this.#welcomed;
  }

  /** Write one JSON message. Returns false when the socket is not open. */
  send(message: unknown): boolean {
    const socket = this.#socket;
    if (this.#closed || !socket || socket.readyState !== OPEN) return false;
    try {
      socket.send(JSON.stringify(message));
      this.#lastOut = Date.now();
      return true;
    } catch {
      return false;
    }
  }

  close(code = 1000, reason = "agent closed"): void {
    const socket = this.#socket;
    const wasOpen = !this.#closed;
    this.#finish(code, reason);
    if (socket && wasOpen) {
      try {
        socket.close(code, reason);
      } catch {
        // ignore
      }
    }
  }

  #tick(): void {
    const now = Date.now();
    if (now - this.#lastIn > this.#idleTimeoutMs + this.#options.livenessGraceMs) {
      this.close(CLIENT_IDLE_CLOSE, "server silent");
      return;
    }
    // Spec section 8.5: ping after idleTimeoutMs / 2 of the client's own silence.
    if (now - this.#lastOut >= this.#idleTimeoutMs / 2) {
      this.#pings += 1;
      this.send({ type: "ping", nonce: `p-${this.#pings}` });
    }
  }

  #finish(code: number, reason: string): void {
    if (this.#closed) return;
    this.#closed = true;
    if (this.#timer) clearInterval(this.#timer);
    if (this.#connectTimer) clearTimeout(this.#connectTimer);
    const socket = this.#socket;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onclose = null;
      socket.onerror = null;
    }
    const close: SocketClose = { code, reason, opened: this.#opened };
    const retryAfterMs = retryAfterFromReason(reason) ?? this.#retryAfterMs;
    if (retryAfterMs !== undefined) close.retryAfterMs = retryAfterMs;
    this.#handlers.onClose(close);
  }
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

/** `http(s)://host[/path]` or `ws(s)://...` to the endpoint URL. @internal */
export function endpointUrl(url: string, path: string): string {
  const ws = url.replace(/^http(s?):\/\//i, (_m, s: string) => `ws${s}://`);
  const parsed = new URL(ws);
  if (parsed.pathname === "/" || parsed.pathname === "") parsed.pathname = path;
  return parsed.toString();
}

/** `ws(s)://host/...` or `http(s)://host/...` to `http(s)://host`. @internal */
export function httpBase(url: string): string {
  const parsed = new URL(url.replace(/^ws(s?):\/\//i, (_m, s: string) => `http${s}://`));
  return `${parsed.protocol}//${parsed.host}`;
}
