/**
 * The Phoenix Channels binding: `wss://HOST/socket/converger/websocket?token=&vsn=2.0.0`,
 * topic `converger:conversation:ID` (spec section 2.2), with Phoenix's V2 JSON
 * serializer (`[join_ref, ref, topic, event, payload]`) implemented here, so
 * the `phoenix` npm package is not needed.
 *
 * What the server does on this binding today, and how it is normalised:
 *
 * - Activities arrive in the pre-v1 `activitySet {activities, watermark, has_more}`
 *   shape, without a per-activity `seq`. The transport turns each activity into
 *   a v1 frame and derives `seq` from the set's watermark (the seq of its last
 *   activity, the set being contiguous). On a routed socket whose middleware
 *   halts activities the derived seqs can be off; prefer the native endpoint.
 * - Sends use the event `frame` (v1 `text` frames); `ack` and `error` come back
 *   as `frame` events (#24).
 * - `deliveryStatus`, `typing` and `presence` are events named by the frame type.
 * - There is no `welcome`: one is synthesised after the join, with an unknown
 *   head (`watermark: null`). There is no mid-session `auth` (#22): a refreshed
 *   token is used on the next connection. `sync` is a rejoin with the watermark.
 * - The Phoenix heartbeat replaces `ping`.
 *
 * @module
 */

import {
  PROTOCOL_VERSION,
  type ActivityFrame,
  type ClientFrame,
  type ServerFrame,
  type WelcomeFrame,
} from "../protocol/frames.js";
import { encodeOpaqueWatermark, parseWatermark } from "../protocol/watermark.js";
import type { RestActivity } from "../rest/types.js";
import { decodeToken } from "../token.js";
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

/** Options of the Phoenix transport. */
export interface PhoenixTransportOptions {
  /** Socket path (without `/websocket`). Default `/socket/converger`. */
  path?: string;
  /** Phoenix heartbeat interval. Default 30000. */
  heartbeatIntervalMs?: number;
  /** Give up on a connection whose join has not been answered after this long. Default 15000. */
  connectTimeoutMs?: number;
}

type PhoenixMessage = [string | null, string | null, string, string, unknown];

/**
 * A REST/Phoenix activity as a v1 persistent frame (spec section 5.4 mapping).
 *
 * @internal
 */
export function activityToFrame(activity: RestActivity, seq: number, userId: string | undefined): ActivityFrame {
  const senderId = activity.from?.id ?? "unknown";
  const role = senderId === "system" ? "system" : userId !== undefined && senderId === userId ? "user" : "bot";
  const base = {
    id: activity.id,
    seq,
    from: role === "user" ? ("user" as const) : ("bot" as const),
    sender: { id: senderId, role },
    timestamp: Date.parse(activity.timestamp) || Date.now(),
  };
  const metadata = activity.channelData && Object.keys(activity.channelData).length > 0 ? activity.channelData : undefined;

  switch (activity.type) {
    case "conversationUpdate":
      return { ...base, type: "conversationUpdate", data: activity.channelData ?? {} };
    case "endOfConversation":
      return { ...base, type: "conversationUpdate", data: { event: "conversation_ended", status: "closed" } };
    case "typing":
      return { ...base, type: "typing", isTyping: false } as unknown as ActivityFrame;
    case "event": {
      const data: { text: string; name?: string; value?: unknown } = { text: activity.text ?? "" };
      if (typeof metadata?.["name"] === "string") data.name = metadata["name"];
      if (metadata && "value" in metadata) data.value = metadata["value"];
      return metadata ? { ...base, type: "event", data, metadata } : { ...base, type: "event", data };
    }
    case "messageReaction":
    case "messageUpdate":
    case "messageDelete": {
      const value: Record<string, unknown> = { replyToId: activity.replyToId ?? null };
      if (activity.text) value["text"] = activity.text;
      if (activity.attachments && activity.attachments.length > 0) value["attachments"] = activity.attachments;
      const data = { name: activity.type, text: activity.text ?? "", value };
      return metadata ? { ...base, type: "event", data, metadata } : { ...base, type: "event", data };
    }
    default: {
      const data: { text: string; attachments?: RestActivity["attachments"] & object } = { text: activity.text ?? "" };
      if (activity.attachments && activity.attachments.length > 0) data.attachments = activity.attachments;
      const frame: ActivityFrame = { ...base, type: "text", data } as ActivityFrame;
      if (metadata) (frame as { metadata?: unknown }).metadata = metadata;
      if (activity.replyToId) (frame as { replyTo?: unknown }).replyTo = { id: activity.replyToId };
      return frame;
    }
  }
}

class PhoenixTransport implements Transport {
  readonly name = "phoenix";
  readonly capabilities = { auth: false, sync: true, signals: true, requiresConversationId: true };

  readonly #env: TransportEnvironment;
  readonly #path: string;
  readonly #heartbeatMs: number;
  #socket: WebSocketLike | undefined;
  #handlers: TransportHandlers | undefined;
  #params: TransportConnectParams | undefined;
  #topic = "";
  #userId: string | undefined;
  #ref = 0;
  #joinRef: string | null = null;
  #joined = false;
  #opened = false;
  #closed = false;
  #welcomed = false;
  #heartbeat: ReturnType<typeof setInterval> | undefined;
  readonly #connectTimeoutMs: number;
  #connectTimer: ReturnType<typeof setTimeout> | undefined;
  #pendingHeartbeat: string | null = null;
  #watermark: number | undefined;
  #retryAfterMs: number | undefined;

  constructor(env: TransportEnvironment, options: PhoenixTransportOptions) {
    this.#env = env;
    this.#path = options.path ?? "/socket/converger";
    this.#heartbeatMs = options.heartbeatIntervalMs ?? 30_000;
    this.#connectTimeoutMs = options.connectTimeoutMs ?? 15_000;
  }

  connect(params: TransportConnectParams, handlers: TransportHandlers): void {
    this.#handlers = handlers;
    this.#params = params;
    if (!params.conversationId) {
      queueMicrotask(() => this.#finish(4404, "the Phoenix binding needs a conversation id"));
      return;
    }
    this.#topic = `converger:conversation:${params.conversationId}`;
    const claims = decodeToken(params.token);
    this.#userId = typeof claims?.user_id === "string" ? claims.user_id : params.userId;
    this.#watermark = params.watermark;

    const WS = requireWebSocket(this.#env);
    const query = new URLSearchParams({ token: params.token, vsn: "2.0.0" });
    let socket: WebSocketLike;
    try {
      socket = new WS(`${toWebSocketUrl(params.baseUrl)}${this.#path}/websocket?${query.toString()}`);
    } catch (error) {
      queueMicrotask(() => this.#finish(1006, error instanceof Error ? error.message : "connect failed"));
      return;
    }
    this.#socket = socket;
    this.#connectTimer = setTimeout(() => this.close(4000, "connect timeout"), this.#connectTimeoutMs);

    socket.onopen = () => {
      this.#opened = true;
      handlers.onOpen();
      this.#join(this.#watermark);
      this.#heartbeat = setInterval(() => this.#beat(), this.#heartbeatMs);
    };
    socket.onmessage = (event) => {
      if (typeof event.data === "string") this.#receive(event.data);
    };
    socket.onclose = (event) => this.#finish(event.code, event.reason ?? "");
    socket.onerror = () => {
      // A close event always follows.
    };
  }

  #nextRef(): string {
    this.#ref += 1;
    return String(this.#ref);
  }

  #push(joinRef: string | null, topic: string, event: string, payload: unknown): string | null {
    const socket = this.#socket;
    if (!socket || socket.readyState !== OPEN) return null;
    const ref = this.#nextRef();
    try {
      socket.send(JSON.stringify([joinRef, ref, topic, event, payload]));
      return ref;
    } catch {
      return null;
    }
  }

  #join(watermark: number | undefined): void {
    this.#joined = false;
    const ref = String(this.#ref + 1);
    this.#joinRef = ref;
    const payload: Record<string, unknown> = {};
    if (watermark !== undefined) payload["watermark"] = encodeOpaqueWatermark(watermark);
    this.#push(ref, this.#topic, "phx_join", payload);
  }

  #rejoin(watermark: number): void {
    if (this.#joinRef !== null) this.#push(this.#joinRef, this.#topic, "phx_leave", {});
    this.#watermark = watermark;
    this.#join(watermark);
  }

  #beat(): void {
    if (this.#pendingHeartbeat !== null) {
      // The previous heartbeat was never answered: the connection is dead.
      this.close(4000, "heartbeat timeout");
      return;
    }
    this.#pendingHeartbeat = this.#push(null, "phoenix", "heartbeat", {});
  }

  #receive(raw: string): void {
    let message: PhoenixMessage;
    try {
      message = JSON.parse(raw) as PhoenixMessage;
    } catch {
      return;
    }
    if (!Array.isArray(message) || message.length !== 5) return;
    const [joinRef, ref, topic, event, payload] = message;

    if (topic === "phoenix") {
      if (event === "phx_reply" && ref === this.#pendingHeartbeat) this.#pendingHeartbeat = null;
      return;
    }
    if (topic !== this.#topic) return;
    // Messages of a previous join (before a rejoin) are stale.
    if (joinRef !== null && joinRef !== this.#joinRef) return;

    const body = (payload ?? {}) as Record<string, unknown>;
    switch (event) {
      case "phx_reply":
        if (ref === this.#joinRef) this.#onJoinReply(body);
        return;
      case "activitySet":
        this.#onActivitySet(body);
        return;
      case "frame":
        this.#handlers?.onFrame(body as unknown as ServerFrame);
        return;
      case "deliveryStatus":
      case "typing":
      case "presence":
        this.#handlers?.onFrame({ ...body, type: event } as unknown as ServerFrame);
        return;
      case "error":
        this.#onLegacyError(body);
        return;
      case "phx_error":
        this.close(1011, "channel crashed");
        return;
      case "phx_close":
        this.close(1000, "channel closed");
        return;
      default:
        return;
    }
  }

  #onJoinReply(body: Record<string, unknown>): void {
    const response = (body["response"] ?? {}) as Record<string, unknown>;
    if (body["status"] !== "ok") {
      const reason = typeof response["reason"] === "string" ? response["reason"] : "join refused";
      if (typeof response["retry_after_ms"] === "number") this.#retryAfterMs = response["retry_after_ms"];
      const code = reason === "unauthorized" ? 4401 : reason === "unavailable" ? 1013 : 4400;
      this.close(code, reason);
      return;
    }
    this.#joined = true;
    if (this.#connectTimer) clearTimeout(this.#connectTimer);
    if (this.#welcomed) return;
    this.#welcomed = true;
    const welcome: WelcomeFrame = {
      type: "welcome",
      data: {
        protocol: PROTOCOL_VERSION,
        scope: "conversation",
        conversationId: this.#params?.conversationId ?? "",
        watermark: null,
        capabilities: { acks: true, receipts: true, presence: true, typing: true },
      },
    };
    if (this.#userId !== undefined) welcome.data.userId = this.#userId;
    const exp = decodeToken(this.#params?.token ?? "")?.exp;
    if (typeof exp === "number") welcome.data.expiresAt = exp * 1000;
    this.#handlers?.onFrame(welcome);
  }

  #onActivitySet(body: Record<string, unknown>): void {
    const activities = Array.isArray(body["activities"]) ? (body["activities"] as RestActivity[]) : [];
    const last = parseWatermark(body["watermark"]);
    if (activities.length === 0 || last === null) return;
    const first = last - activities.length + 1;
    activities.forEach((activity, index) => {
      this.#handlers?.onFrame(activityToFrame(activity, first + index, this.#userId) as ServerFrame);
    });
    this.#watermark = last;
    // A capped replay: continue from where it stopped.
    if (body["has_more"] === true) this.#rejoin(last);
  }

  #onLegacyError(body: Record<string, unknown>): void {
    const code = typeof body["code"] === "string" ? body["code"] : "internal";
    const data: Record<string, unknown> = {
      code,
      message: typeof body["message"] === "string" ? body["message"] : code,
      retryable: true,
    };
    if (typeof body["retry_after_ms"] === "number") data["retryAfterMs"] = body["retry_after_ms"];
    const watermark = parseWatermark(body["watermark"]);
    if (watermark !== null) data["details"] = { watermark };
    this.#handlers?.onFrame({ type: "error", data } as unknown as ServerFrame);
  }

  send(frame: ClientFrame): boolean {
    if (!this.#joined || this.#joinRef === null) return false;
    switch (frame.type) {
      case "text":
        return this.#push(this.#joinRef, this.#topic, "frame", frame) !== null;
      case "typing":
        return this.#push(this.#joinRef, this.#topic, "typing", { isTyping: frame.isTyping }) !== null;
      case "read":
        return this.#push(this.#joinRef, this.#topic, "read", { watermark: frame.watermark }) !== null;
      case "sync":
        this.#rejoin(frame.watermark);
        return true;
      case "ping":
      case "auth":
      case "hello":
        // Heartbeats are Phoenix's; tokens are checked on connect only (#22).
        return true;
      default:
        return false;
    }
  }

  close(code = 1000, reason = "client closed"): void {
    const socket = this.#socket;
    const open = !this.#closed;
    // Report first (and detach the handlers): do not wait for the close
    // handshake of a dead connection, and ignore the socket's own close event.
    this.#finish(code, reason);
    if (socket && open) {
      try {
        socket.close(code >= 4000 || code === 1000 ? code : 1000, reason);
      } catch {
        // ignore
      }
    }
  }

  #finish(code: number, reason: string): void {
    if (this.#closed) return;
    this.#closed = true;
    if (this.#heartbeat) clearInterval(this.#heartbeat);
    if (this.#connectTimer) clearTimeout(this.#connectTimer);
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

/** The Phoenix Channels binding (`/socket/converger/websocket`). Needs an existing conversation. */
export function phoenixTransport(options: PhoenixTransportOptions = {}): TransportFactory {
  const factory: TransportFactory = (env) => new PhoenixTransport(env, options);
  factory.transportName = "phoenix";
  return factory;
}
