/**
 * The native Protocol v1 endpoint: `wss://HOST/socket/converger/v1`, raw JSON
 * frames, subprotocol `converger.v1` (spec section 2.1).
 *
 * The token travels in `hello.token`, never in the URL, so it does not end up
 * in proxy logs. The transport keeps the connection alive with `ping` after
 * `idleTimeoutMs / 2` of its own silence and closes a connection that has been
 * silent for longer than `idleTimeoutMs` plus a grace period (a half-open TCP
 * connection after a server crash).
 *
 * @module
 */

import {
  PROTOCOL_VERSION,
  SUBPROTOCOL,
  type ClientFrame,
  type ErrorFrame,
  type HelloFrame,
  type ServerFrame,
  type WelcomeFrame,
} from "../protocol/frames.js";
import {
  requireWebSocket,
  retryAfterFromReason,
  toWebSocketUrl,
  type Transport,
  type TransportConnectParams,
  type TransportEnvironment,
  type TransportFactory,
  type TransportHandlers,
  type WebSocketLike,
} from "./types.js";

const OPEN = 1;
/** Client-side close code for a connection the server stopped answering on. */
export const CLIENT_IDLE_CLOSE = 4000;

/** Options of the native transport. */
export interface NativeTransportOptions {
  /** Path of the endpoint. Default `/socket/converger/v1`. */
  path?: string;
  /** Extra time beyond `idleTimeoutMs` before a silent connection is dropped. Default 15000. */
  livenessGraceMs?: number;
}

class NativeTransport implements Transport {
  readonly name = "native";
  readonly capabilities = { auth: true, sync: true, signals: true, requiresConversationId: false };

  readonly #env: TransportEnvironment;
  readonly #path: string;
  readonly #graceMs: number;
  #socket: WebSocketLike | undefined;
  #handlers: TransportHandlers | undefined;
  #opened = false;
  #closed = false;
  #timer: ReturnType<typeof setInterval> | undefined;
  #idleTimeoutMs = 60_000;
  #lastIn = 0;
  #lastOut = 0;
  #pings = 0;
  #retryAfterMs: number | undefined;

  constructor(env: TransportEnvironment, options: NativeTransportOptions) {
    this.#env = env;
    this.#path = options.path ?? "/socket/converger/v1";
    this.#graceMs = options.livenessGraceMs ?? 15_000;
  }

  connect(params: TransportConnectParams, handlers: TransportHandlers): void {
    this.#handlers = handlers;
    const WS = requireWebSocket(this.#env);
    const query = new URLSearchParams();
    // Identity hints for L7 affinity only (spec section 2.1); the token decides.
    if (params.conversationId) query.set("conversationId", params.conversationId);
    const qs = query.toString();
    let socket: WebSocketLike;
    try {
      socket = new WS(`${toWebSocketUrl(params.baseUrl)}${this.#path}${qs ? `?${qs}` : ""}`, [SUBPROTOCOL]);
    } catch (error) {
      queueMicrotask(() => this.#finish(1006, error instanceof Error ? error.message : "connect failed"));
      return;
    }
    this.#socket = socket;

    socket.onopen = () => {
      this.#opened = true;
      const now = Date.now();
      this.#lastIn = now;
      const hello: HelloFrame = { type: "hello", protocol: PROTOCOL_VERSION, token: params.token };
      if (params.conversationId) hello.conversationId = params.conversationId;
      if (params.userId) hello.userId = params.userId;
      if (params.watermark !== undefined) hello.watermark = params.watermark;
      this.send(hello);
      this.#timer = setInterval(() => this.#tick(), 1_000);
      handlers.onOpen();
    };

    socket.onmessage = (event) => {
      this.#lastIn = Date.now();
      if (typeof event.data !== "string") return; // binary frames need msgpack, which this client does not offer
      let frame: unknown;
      try {
        frame = JSON.parse(event.data);
      } catch {
        return;
      }
      if (typeof frame !== "object" || frame === null || typeof (frame as { type?: unknown }).type !== "string") return;
      const typed = frame as ServerFrame;
      if (typed.type === "welcome") {
        const idle = (typed as WelcomeFrame).data.limits?.idleTimeoutMs;
        if (typeof idle === "number" && idle > 0) this.#idleTimeoutMs = idle;
      } else if (typed.type === "error") {
        const retryAfterMs = (typed as ErrorFrame).data.retryAfterMs;
        if (typeof retryAfterMs === "number") this.#retryAfterMs = retryAfterMs;
      }
      handlers.onFrame(typed);
    };

    socket.onclose = (event) => this.#finish(event.code, event.reason ?? "");
    socket.onerror = () => {
      // A close event always follows.
    };
  }

  send(frame: ClientFrame): boolean {
    const socket = this.#socket;
    if (!socket || socket.readyState !== OPEN) return false;
    try {
      socket.send(JSON.stringify(frame));
      this.#lastOut = Date.now();
      return true;
    } catch {
      return false;
    }
  }

  close(code = 1000, reason = "client closed"): void {
    const socket = this.#socket;
    if (socket && !this.#closed) {
      try {
        socket.close(code, reason);
      } catch {
        // ignore
      }
    }
    // Do not wait for the close handshake of a dead connection.
    this.#finish(code, reason);
  }

  #tick(): void {
    const now = Date.now();
    if (now - this.#lastIn > this.#idleTimeoutMs + this.#graceMs) {
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
    const socket = this.#socket;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onclose = null;
      socket.onerror = null;
    }
    const retryAfterMs = retryAfterFromReason(reason) ?? this.#retryAfterMs;
    const close: { code: number; reason: string; opened: boolean; retryAfterMs?: number } = {
      code,
      reason,
      opened: this.#opened,
    };
    if (retryAfterMs !== undefined) close.retryAfterMs = retryAfterMs;
    this.#handlers?.onClose(close);
  }
}

/** The native `/socket/converger/v1` transport (the default). */
export function nativeTransport(options: NativeTransportOptions = {}): TransportFactory {
  const factory: TransportFactory = (env) => new NativeTransport(env, options);
  factory.transportName = "native";
  return factory;
}
