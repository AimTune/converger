/**
 * The Server-Sent Events fallback for networks that block WebSockets (spec
 * section 2.4): frames are received from
 * `GET /api/v1/converger/conversations/:id/events?watermark=N` and turns are
 * sent with `POST /api/v1/converger/conversations/:id/activities`.
 *
 * The stream is read with `fetch` (not `EventSource`), so the token travels in
 * the `Authorization` header in browsers too, and it works in Node.
 *
 * Sends carry `X-Idempotency-Key: ws:<userId>:<clientId>`, the key the
 * WebSocket bindings store a clientId under (spec section 7), so a message
 * resent over another transport is still stored once. The REST answer has no
 * `seq`; the `ack` is emitted when the turn arrives on the stream (the stream
 * does not apply the echo rule).
 *
 * Limitations: no `typing` or `read` from the client, no mid-session `auth`
 * (the stream ends with `token_expired` and the session reconnects with a fresh
 * token), and the stream needs an existing conversation.
 *
 * @module
 */

import { PROTOCOL_VERSION, isPersistent, type ClientFrame, type ServerFrame, type WelcomeFrame } from "../protocol/frames.js";
import { apiErrorFrom } from "../errors.js";
import type { FetchLike } from "../rest/client.js";
import { trimBaseUrl } from "../rest/client.js";
import { decodeToken } from "../token.js";
import type {
  Transport,
  TransportConnectParams,
  TransportEnvironment,
  TransportFactory,
  TransportHandlers,
} from "./types.js";

/** Options of the SSE transport. */
export interface SseTransportOptions {
  /** Close a stream that sent nothing (not even a heartbeat) for this long. Default 75000. */
  livenessTimeoutMs?: number;
}

class SseTransport implements Transport {
  readonly name = "sse";
  readonly capabilities = { auth: false, sync: true, signals: false, requiresConversationId: true };

  readonly #fetch: FetchLike | undefined;
  readonly #livenessMs: number;
  #handlers: TransportHandlers | undefined;
  #params: TransportConnectParams | undefined;
  #abort = new AbortController();
  #opened = false;
  #closed = false;
  #userId: string | undefined;
  /** Recent persistent frames (id -> seq): the stream may deliver a turn before its POST returns. */
  readonly #recent = new Map<string, number>();
  #liveness: ReturnType<typeof setTimeout> | undefined;
  #retryAfterMs: number | undefined;
  /** activity id -> clientId of sends whose frame has not arrived yet. */
  readonly #awaiting = new Map<string, string>();

  constructor(env: TransportEnvironment, options: SseTransportOptions) {
    this.#fetch = env.fetch;
    this.#livenessMs = options.livenessTimeoutMs ?? 75_000;
  }

  connect(params: TransportConnectParams, handlers: TransportHandlers): void {
    this.#handlers = handlers;
    this.#params = params;
    const claims = decodeToken(params.token);
    this.#userId = typeof claims?.user_id === "string" ? claims.user_id : params.userId;
    void this.#run(params);
  }

  async #run(params: TransportConnectParams): Promise<void> {
    const fetchImpl = this.#fetch;
    if (!fetchImpl) return this.#finish(1006, "no fetch implementation");
    if (!params.conversationId) return this.#finish(4404, "the SSE stream needs a conversation id");

    const query = new URLSearchParams();
    if (params.watermark !== undefined) query.set("watermark", String(params.watermark));
    if (this.#userId && !decodeToken(params.token)?.user_id) query.set("userId", this.#userId);
    const qs = query.toString();
    const url = `${trimBaseUrl(params.baseUrl)}/api/v1/converger/conversations/${encodeURIComponent(params.conversationId)}/events${qs ? `?${qs}` : ""}`;

    let response: Response;
    try {
      response = await fetchImpl(url, {
        headers: { authorization: `Bearer ${params.token}`, accept: "text/event-stream" },
        signal: this.#abort.signal,
      });
    } catch (error) {
      return this.#finish(1006, error instanceof Error ? error.message : "stream failed");
    }

    if (!response.ok || !response.body) {
      let body: unknown = null;
      try {
        body = await response.json();
      } catch {
        // ignore
      }
      const apiError = apiErrorFrom(response.status, body, response.headers.get("retry-after"));
      if (apiError.retryAfterMs !== undefined) this.#retryAfterMs = apiError.retryAfterMs;
      const code = response.status === 401 ? 4401 : response.status === 403 ? 4403 : response.status === 404 ? 1008 : 1013;
      return this.#finish(code, apiError.message);
    }

    this.#opened = true;
    this.#handlers?.onOpen();
    this.#emitWelcome();
    this.#touch();

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        this.#touch();
        buffer += decoder.decode(value, { stream: true });
        let boundary: number;
        while ((boundary = buffer.search(/\r?\n\r?\n/)) !== -1) {
          const chunk = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary).replace(/^\r?\n\r?\n/, "");
          this.#event(chunk);
        }
      }
      this.#finish(1006, "stream ended");
    } catch (error) {
      this.#finish(1006, error instanceof Error ? error.message : "stream failed");
    }
  }

  #emitWelcome(): void {
    const params = this.#params;
    const welcome: WelcomeFrame = {
      type: "welcome",
      data: {
        protocol: PROTOCOL_VERSION,
        scope: "conversation",
        conversationId: params?.conversationId ?? "",
        watermark: null,
        capabilities: { acks: true, receipts: true, presence: true, typing: false },
      },
    };
    if (this.#userId !== undefined) welcome.data.userId = this.#userId;
    const exp = decodeToken(params?.token ?? "")?.exp;
    if (typeof exp === "number") welcome.data.expiresAt = exp * 1000;
    this.#handlers?.onFrame(welcome);
  }

  #event(chunk: string): void {
    const data: string[] = [];
    for (const line of chunk.split(/\r?\n/)) {
      if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
    }
    if (data.length === 0) return;
    let frame: ServerFrame;
    try {
      frame = JSON.parse(data.join("\n")) as ServerFrame;
    } catch {
      return;
    }
    if (typeof frame !== "object" || frame === null || typeof frame.type !== "string") return;

    if (isPersistent(frame)) {
      if (typeof frame.id === "string") {
        this.#recent.set(frame.id, frame.seq);
        if (this.#recent.size > 500) this.#recent.delete(this.#recent.keys().next().value as string);
      }
      const clientId = typeof frame.id === "string" ? this.#awaiting.get(frame.id) : undefined;
      if (clientId !== undefined && typeof frame.id === "string") {
        this.#awaiting.delete(frame.id);
        this.#handlers?.onFrame({ type: "ack", clientId, id: frame.id, seq: frame.seq });
      }
    } else if (frame.type === "error") {
      if (typeof frame.data.retryAfterMs === "number") this.#retryAfterMs = frame.data.retryAfterMs;
      this.#handlers?.onFrame(frame);
      // The stream ends after token_expired, channel_inactive and unavailable.
      const code = frame.data.code;
      if (code === "token_expired") this.close(4401, code);
      else if (code === "channel_inactive") this.close(4403, code);
      else if (code === "unavailable") this.close(1012, code);
      return;
    }
    this.#handlers?.onFrame(frame);
  }

  #touch(): void {
    if (this.#liveness) clearTimeout(this.#liveness);
    this.#liveness = setTimeout(() => this.close(4000, "stream silent"), this.#livenessMs);
  }

  send(frame: ClientFrame): boolean {
    if (!this.#opened || this.#closed) return false;
    switch (frame.type) {
      case "text":
        void this.#post(frame);
        return true;
      case "sync":
        // Reconnecting resumes from the watermark (Last-Event-ID semantics).
        this.close(4000, "sync");
        return true;
      case "ping":
      case "auth":
      case "hello":
        return true;
      default:
        return false;
    }
  }

  async #post(frame: Extract<ClientFrame, { type: "text" }>): Promise<void> {
    const params = this.#params;
    const fetchImpl = this.#fetch;
    if (!params?.conversationId || !fetchImpl) return;
    const headers: Record<string, string> = {
      authorization: `Bearer ${params.token}`,
      "content-type": "application/json",
      accept: "application/json",
    };
    const sender = this.#userId ?? "user";
    if (frame.clientId) headers["x-idempotency-key"] = `ws:${sender}:${frame.clientId}`;
    const body: Record<string, unknown> = { type: "message", text: frame.data.text, from: { id: sender } };
    if (frame.data.attachments) body["attachments"] = frame.data.attachments;
    if (frame.metadata) body["channelData"] = frame.metadata;
    if (frame.replyTo) body["replyToId"] = frame.replyTo.id;

    try {
      const response = await fetchImpl(
        `${trimBaseUrl(params.baseUrl)}/api/v1/converger/conversations/${encodeURIComponent(params.conversationId)}/activities`,
        { method: "POST", headers, body: JSON.stringify(body), signal: this.#abort.signal },
      );
      const text = await response.text();
      let parsed: unknown = null;
      try {
        parsed = text ? JSON.parse(text) : null;
      } catch {
        parsed = text;
      }
      if (response.ok) {
        const id = (parsed as { id?: unknown } | null)?.id;
        if (frame.clientId && typeof id === "string") {
          const seq = this.#recent.get(id);
          if (seq !== undefined) this.#handlers?.onFrame({ type: "ack", clientId: frame.clientId, id, seq });
          else this.#awaiting.set(id, frame.clientId);
        }
        return;
      }
      const apiError = apiErrorFrom(response.status, parsed, response.headers.get("retry-after"));
      const code = response.status === 409 ? "conversation_closed" : response.status === 422 ? "invalid_message" : apiError.code;
      const data: Record<string, unknown> = {
        code,
        message: apiError.message,
        retryable: apiError.retryable,
        frameType: "text",
      };
      if (frame.clientId) data["clientId"] = frame.clientId;
      if (apiError.retryAfterMs !== undefined) data["retryAfterMs"] = apiError.retryAfterMs;
      if (apiError.details) data["details"] = apiError.details;
      this.#handlers?.onFrame({ type: "error", data } as unknown as ServerFrame);
    } catch {
      // Network failure: the send stays in the outbox and is resent after the reconnect.
    }
  }

  close(code = 1000, reason = "client closed"): void {
    this.#finish(code, reason);
  }

  #finish(code: number, reason: string): void {
    if (this.#closed) return;
    this.#closed = true;
    if (this.#liveness) clearTimeout(this.#liveness);
    this.#abort.abort();
    const close: { code: number; reason: string; opened: boolean; retryAfterMs?: number } = {
      code,
      reason,
      opened: this.#opened,
    };
    if (this.#retryAfterMs !== undefined) close.retryAfterMs = this.#retryAfterMs;
    this.#handlers?.onClose(close);
  }
}

/** The Server-Sent Events fallback (receive over SSE, send over REST). Needs an existing conversation. */
export function sseTransport(options: SseTransportOptions = {}): TransportFactory {
  const factory: TransportFactory = (env) => new SseTransport(env, options);
  factory.transportName = "sse";
  return factory;
}
