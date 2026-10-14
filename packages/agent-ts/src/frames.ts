/**
 * Converger Protocol v1 frame types, as an agent on a channel-scoped
 * connection sees them.
 *
 * Hand-written from `docs/protocol/v1.md` (sections 4 to 10 and 12) and the
 * JSON Schemas in `priv/protocol/v1/` of the server repository, like the
 * frame types of `@converger/client`. The unit tests validate every frame the
 * SDK builds against `frames/channel/agent-frame.schema.json` and
 * `client-envelope.schema.json`, so a schema change that breaks the SDK fails
 * them. Receivers must ignore unknown fields and frame types (section 5.5), so
 * every union here is open.
 *
 * @module
 */

/** The protocol version this SDK speaks. */
export const PROTOCOL_VERSION = "converger/1";

/** WebSocket subprotocol of the native endpoint (JSON text frames). */
export const SUBPROTOCOL = "converger.v1";

/** Default path of the native endpoint. */
export const DEFAULT_PATH = "/socket/converger/v1";

/** Any JSON object. */
export type JsonObject = Record<string, unknown>;

/** Who sent a persistent frame (`common.schema.json#/$defs/sender`). */
export interface Sender {
  id: string;
  role?: "user" | "bot" | "agent" | "system" | (string & {});
  name?: string;
}

/** A tappable chip or button (`common.schema.json#/$defs/messageAction`). */
export interface MessageAction {
  label: string;
  /** Omitted: the answer is `label`. Outside interrupts it SHOULD be a string. */
  value?: unknown;
  /** Makes the action a link. */
  url?: string;
}

/** A file attached to a message (legacy `data.attachments`, or the data of an `image`/`file`/... message). */
export interface Attachment {
  url?: string;
  contentType?: string;
  contentUrl?: string;
  name?: string;
  size?: number;
  [key: string]: unknown;
}

/** `metadata.action` of a user turn that answers an actionable message (messages.md section 6). */
export interface TurnAction {
  label?: string;
  value?: unknown;
  source?: "button" | "list" | "keyboard" | "numeric" | "email" | "web" | (string & {});
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Server -> agent
// ---------------------------------------------------------------------------

/** Limits announced in `welcome.data.limits` (section 11). */
export interface Limits {
  maxFrameBytes?: number;
  maxTextBytes?: number;
  maxMetadataBytes?: number;
  maxInFlight?: number;
  heartbeatIntervalMs?: number;
  idleTimeoutMs?: number;
  replayBatch?: number;
  replayMax?: number;
  maxConversations?: number;
  [key: string]: unknown;
}

/** The channel `welcome` (section 10): no conversation, `scope: "channel"`. */
export interface WelcomeFrame {
  type: "welcome";
  data: {
    protocol: string;
    compat?: string[];
    connectionId: string;
    scope?: "conversation" | "channel";
    channelId?: string;
    userId?: string;
    /** Token expiry, ms since the epoch. */
    expiresAt?: number;
    capabilities?: Record<string, unknown>;
    limits?: Limits;
    [key: string]: unknown;
  };
}

/** The data of an `error` frame (section 12.1). */
export interface ErrorData {
  code: string;
  message: string;
  number?: number;
  retryable?: boolean;
  retryAfterMs?: number;
  clientId?: string;
  frameType?: string;
  details?: JsonObject;
}

/** `error`, bare (about the connection) or enveloped (about one conversation). */
export interface ErrorFrame {
  type: "error";
  data: ErrorData;
}

/** `ack` of a message frame sent with a `clientId` (section 7). */
export interface AckFrame {
  type: "ack";
  clientId: string;
  id: string;
  seq: number;
  timestamp?: number;
  duplicate?: boolean;
}

/**
 * A message frame (section 5.1): `text` and every rich message type
 * (`buttons`, `card`, `image`, `location`, ...).
 */
export interface MessageFrame {
  type: string;
  id?: string;
  seq?: number;
  from?: "user" | "bot";
  data: JsonObject;
  timestamp?: number;
  sender?: Sender;
  metadata?: JsonObject;
  /** mekik/1 per-turn context of a user turn; relayed, never stored. */
  meta?: JsonObject;
  actions?: MessageAction[];
  clientId?: string;
  replyTo?: { id?: string; seq?: number };
  [key: string]: unknown;
}

/** `resume`: the end user's answer to open interrupts, keyed by interrupt id (forwarded, section 9). */
export interface ResumeFrame {
  type: "resume";
  answers: Record<string, unknown>;
  clientId?: string;
}

/** `abort`: the end user asks the bot to stop the current run (forwarded). */
export interface AbortFrame {
  type: "abort";
}

/** `genui_event`: an interaction with a GenUI component (forwarded). */
export interface GenuiEventFrame {
  type: "genui_event";
  streamId?: string;
  eventType?: string;
  scope?: "component" | "graph";
  component?: string;
  payload?: unknown;
}

/** `replayTruncated`: more frames were missed than one replay carries (section 6.2). */
export interface ReplayTruncatedFrame {
  type: "replayTruncated";
  data: { watermark: number; headSeq: number };
}

/** `heartbeat` (section 8.5). */
export interface HeartbeatFrame {
  type: "heartbeat";
  timestamp?: number;
  nonce?: string;
}

/** `tokenRefreshed`: the answer to `auth` (section 3.3). */
export interface TokenRefreshedFrame {
  type: "tokenRefreshed";
  data: { expiresAt: number };
}

/** Any frame inside a server envelope. Open: unknown types are passed through. */
export type InboundFrame =
  | MessageFrame
  | AckFrame
  | ErrorFrame
  | ResumeFrame
  | AbortFrame
  | GenuiEventFrame
  | ReplayTruncatedFrame
  | { type: string; seq?: number; [key: string]: unknown };

/** Bare connection-level frames. */
export type ConnectionFrame = WelcomeFrame | ErrorFrame | HeartbeatFrame | TokenRefreshedFrame | { type: string; [key: string]: unknown };

/** `{conversationId, frame}` (section 10). The envelope has no `type`. */
export interface Envelope<F = InboundFrame> {
  conversationId: string;
  frame: F;
}

// ---------------------------------------------------------------------------
// Agent -> server
// ---------------------------------------------------------------------------

/** `hello` on a channel-scoped connection. */
export interface HelloFrame {
  type: "hello";
  protocol: string;
  token?: string;
  userId?: string;
  group?: string;
  watermarks?: Record<string, number>;
}

/** One tool invocation (`messages/tool-call.schema.json`). */
export interface ToolCallData {
  id: string;
  name: string;
  status: ToolCallStatus;
  description?: string;
  params?: JsonObject;
  result?: unknown;
  error?: string;
  startedAt?: number;
  endedAt?: number;
}

/** Status of a tool call. */
export type ToolCallStatus = "running" | "completed" | "error";

/** A GenUI chunk (`common.schema.json#/$defs/aiChunk`). */
export type AIChunk =
  | { type: "text"; content: string; id?: string | number }
  | { type: "ui"; component: string; props?: JsonObject; id?: string | number }
  | { type: "event"; name: string; payload?: unknown; id?: string | number; for?: string | number };

/** `interrupt` data (`common.schema.json#/$defs/interruptData`). */
export interface InterruptData {
  payload: unknown;
  ui?: { component: string; props?: JsonObject };
  actions?: MessageAction[];
  event?: string;
  tool?: { name: string; params?: unknown };
}

/** Status of a `run` frame. */
export type RunStatus = "started" | "finished" | "interrupted" | "error" | "aborted";

/** What an agent sends inside an envelope (`frames/channel/agent-frame.schema.json`). */
export type AgentFrame =
  | { type: string; data: JsonObject; clientId?: string; id?: string; actions?: MessageAction[]; metadata?: JsonObject; replyTo?: { id?: string; seq?: number } }
  | { type: "tool_call"; data: ToolCallData }
  | { type: "genui"; streamId: string; done: boolean; chunk: AIChunk }
  | { type: "interrupt"; id: string; data: InterruptData }
  | { type: "interrupt_resolved"; id: string; data: { answer?: unknown } }
  | { type: "run"; data: { status: RunStatus } }
  | { type: "typing"; isTyping: boolean }
  | { type: "read"; watermark: number }
  | { type: "sync"; watermark: number }
  | { type: "error"; data: ErrorData };

/** Frame types that are not message frames (never dispatched as turns). */
export const NON_MESSAGE_TYPES: ReadonlySet<string> = new Set([
  "hello", "welcome", "resume", "genui_event", "client_tools", "client_skills", "abort",
  "tool_call", "skill", "skills", "genui", "genui_components", "interrupt", "interrupt_resolved",
  "run", "error", "typing", "survey", "regenerate", "edit", "ack", "deliveryStatus", "presence",
  "conversationUpdate", "endOfConversation", "event", "heartbeat", "ping", "read", "sync", "auth",
  "tokenRefreshed", "replayTruncated", "subscribe", "unsubscribe", "subscribed", "unsubscribed",
  "message", "activity", "activitySet", "frame",
]);

/** Frame types an agent sends without an ack (mekik-native and transient frames). */
export const UNACKED_TYPES: ReadonlySet<string> = new Set([
  "tool_call", "skill", "genui", "interrupt", "interrupt_resolved", "run", "genui_components", "skills",
  "error", "typing", "read", "sync",
]);

/** Whether `frame` is a message frame (a candidate turn). */
export function isMessageFrame(frame: { type?: unknown; data?: unknown }): frame is MessageFrame {
  return (
    typeof frame.type === "string" &&
    !NON_MESSAGE_TYPES.has(frame.type) &&
    typeof frame.data === "object" &&
    frame.data !== null
  );
}
