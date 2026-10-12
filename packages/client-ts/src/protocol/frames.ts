/**
 * Converger Protocol v1 (`converger/1`) frame types.
 *
 * Hand-written from `docs/protocol/v1.md` and the JSON Schemas in
 * `priv/protocol/v1/` of the server repository. Only what the server
 * implements today is typed precisely; receivers must ignore unknown fields and
 * unknown frame types (spec section 5.5), so every union here is open.
 *
 * @module
 */

/** The protocol version this client speaks. */
export const PROTOCOL_VERSION = "converger/1";

/** WebSocket subprotocol of the native endpoint (JSON text frames). */
export const SUBPROTOCOL = "converger.v1";

/** A sender of a frame (`common.schema.json#/$defs/sender`). */
export interface Sender {
  id: string;
  role: "user" | "bot" | "agent" | "system" | (string & {});
  name?: string;
}

/** Limits announced in `welcome.data.limits` (spec section 11). */
export interface Limits {
  maxFrameBytes: number;
  maxTextBytes: number;
  maxMetadataBytes: number;
  maxInFlight: number;
  heartbeatIntervalMs: number;
  idleTimeoutMs: number;
  replayBatch: number;
  replayMax: number;
  [key: string]: unknown;
}

/** Capabilities announced in `welcome.data.capabilities`. */
export interface Capabilities {
  acks: boolean;
  receipts: boolean;
  presence: boolean;
  typing: boolean;
  regenerate: boolean;
  edit: boolean;
  messageTypes?: string[];
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Server -> client
// ---------------------------------------------------------------------------

/** `welcome`: the handshake answer (spec section 4). */
export interface WelcomeFrame {
  type: "welcome";
  data: {
    protocol: string;
    compat?: string[];
    scope?: "conversation" | "channel";
    conversationId: string;
    userId?: string;
    connectionId?: string;
    /** The conversation's head seq at handshake time; null when the transport cannot tell (Phoenix binding). */
    watermark: number | null;
    pending?: unknown[];
    /** Token expiry, ms since the epoch. */
    expiresAt?: number;
    capabilities?: Partial<Capabilities>;
    limits?: Partial<Limits>;
  };
}

/** A file attached to a message (legacy `data.attachments`). */
export interface Attachment {
  contentType?: string;
  contentUrl?: string;
  name?: string;
  size?: number;
  [key: string]: unknown;
}

/** Fields every persistent message frame carries (spec section 5.1). */
export interface PersistentFrameBase {
  /** Activity id. */
  id: string;
  /** 1-based, per conversation, strictly monotonic. */
  seq: number;
  /** Relative to the end user: everyone else is `bot`. */
  from: "user" | "bot";
  /** ms since the epoch (commit time). */
  timestamp?: number;
  sender?: Sender;
  metadata?: Record<string, unknown>;
  /** The sender's clientId, on the sender's own turns. */
  clientId?: string;
  replyTo?: { id: string };
}

/** A `text` message frame. */
export interface TextFrame extends PersistentFrameBase {
  type: "text";
  data: { text: string; attachments?: Attachment[] };
  actions?: unknown[];
}

/** An `event` frame (reactions, edits and deletes until #68, channel events). */
export interface EventFrame extends PersistentFrameBase {
  type: "event";
  data: { name?: string; text: string; value?: unknown };
}

/** A `conversationUpdate` frame (lifecycle: closed, reopened, ended). */
export interface ConversationUpdateFrame extends PersistentFrameBase {
  type: "conversationUpdate";
  data: { event?: string; status?: string; reason?: string; [key: string]: unknown };
}

/** Any other persistent message frame (rich types, mekik/1-native frames). */
export interface RichMessageFrame {
  type: string;
  seq: number;
  id?: string;
  from?: "user" | "bot";
  data?: unknown;
  timestamp?: number;
  [key: string]: unknown;
}

/** A persistent frame: stored as an activity, has a `seq`, is replayed. */
export type ActivityFrame = TextFrame | EventFrame | ConversationUpdateFrame | RichMessageFrame;

/** `ack`: a send was persisted (spec section 7). */
export interface AckFrame {
  type: "ack";
  clientId: string;
  id: string;
  seq: number;
  timestamp?: number;
  /** The clientId was seen before; this is the original activity. */
  duplicate?: boolean;
}

/** Stable error codes (spec section 12.2). */
export type ErrorCode =
  | "bad_request"
  | "no_session"
  | "unsupported_protocol"
  | "invalid_watermark"
  | "invalid_message"
  | "unauthorized"
  | "token_expired"
  | "forbidden"
  | "channel_inactive"
  | "rate_limited"
  | "payload_too_large"
  | "too_many_in_flight"
  | "too_many_subscriptions"
  | "slow_consumer"
  | "conversation_closed"
  | "conversation_not_found"
  | "busy"
  | "interrupted"
  | "not_interrupted"
  | "incomplete_resume"
  | "bot_unavailable"
  | "internal"
  | "unavailable"
  | "replay_unavailable"
  | (string & {});

/** `error` (spec section 12.1). */
export interface ErrorFrame {
  type: "error";
  data: {
    code: ErrorCode;
    message: string;
    number?: number;
    retryable?: boolean;
    retryAfterMs?: number;
    clientId?: string;
    frameType?: string;
    details?: Record<string, unknown>;
  };
}

/** Delivery statuses, in order (`failed` is terminal for an attempt series). */
export type DeliveryStatusValue = "queued" | "sent" | "delivered" | "read" | "failed";

/** `deliveryStatus`: progress of one activity, or a read receipt up to a seq. */
export interface DeliveryStatusFrame {
  type: "deliveryStatus";
  data: {
    activityId?: string;
    seq?: number;
    upToSeq?: number;
    channelId?: string;
    status: DeliveryStatusValue;
    by?: Sender;
    attempt?: number;
    error?: { code: string; message?: string; retryable?: boolean };
    timestamp: number;
  };
}

/** `typing` (transient; a `seq` only on legacy persisted typing activities). */
export interface TypingFrame {
  type: "typing";
  isTyping: boolean;
  from?: "user" | "bot";
  sender?: Sender;
  seq?: number;
  id?: string;
}

/** `presence`: a participant's live connections changed. */
export interface PresenceFrame {
  type: "presence";
  data: {
    participant: Sender;
    status: "online" | "away" | "offline";
    connections?: number;
    lastSeenAt?: number;
  };
}

/** `heartbeat`: answer to `ping` and outbound keep-alive. */
export interface HeartbeatFrame {
  type: "heartbeat";
  timestamp: number;
  nonce?: string;
  headSeq?: number;
}

/** `tokenRefreshed`: the session runs on the token sent with `auth`. */
export interface TokenRefreshedFrame {
  type: "tokenRefreshed";
  data: { expiresAt: number };
}

/** `replayTruncated`: more than `replayMax` frames were missing. */
export interface ReplayTruncatedFrame {
  type: "replayTruncated";
  data: { watermark: number; headSeq: number };
}

/** Frames the client handles itself (not persistent). */
export type ControlFrame =
  | WelcomeFrame
  | AckFrame
  | ErrorFrame
  | DeliveryStatusFrame
  | TypingFrame
  | PresenceFrame
  | HeartbeatFrame
  | TokenRefreshedFrame
  | ReplayTruncatedFrame;

/** Any frame the server may send. Unknown types are kept as `RichMessageFrame` or ignored. */
export type ServerFrame = ControlFrame | ActivityFrame;

// ---------------------------------------------------------------------------
// Client -> server
// ---------------------------------------------------------------------------

/** `hello`: the first frame (spec section 4). */
export interface HelloFrame {
  type: "hello";
  protocol: string;
  conversationId?: string;
  userId?: string;
  watermark?: number;
  token?: string;
}

/** A user turn (spec section 5.3). Only `text` is stored today; rich types are #68. */
export interface ClientMessageFrame {
  type: "text";
  clientId?: string;
  data: { text: string; attachments?: Attachment[] };
  metadata?: Record<string, unknown>;
  meta?: Record<string, unknown>;
  replyTo?: { id: string };
}

export interface SyncFrame {
  type: "sync";
  watermark: number;
}

export interface PingFrame {
  type: "ping";
  nonce?: string;
}

export interface AuthFrame {
  type: "auth";
  token: string;
}

export interface ClientTypingFrame {
  type: "typing";
  isTyping: boolean;
}

export interface ReadFrame {
  type: "read";
  watermark: number;
}

/** Any frame this client sends. */
export type ClientFrame =
  | HelloFrame
  | ClientMessageFrame
  | SyncFrame
  | PingFrame
  | AuthFrame
  | ClientTypingFrame
  | ReadFrame;

/** Frame types the client treats as control frames (never as activities). */
const CONTROL_TYPES = new Set([
  "welcome",
  "ack",
  "error",
  "deliveryStatus",
  "presence",
  "heartbeat",
  "tokenRefreshed",
  "replayTruncated",
  "run",
  "genui_components",
  "skills",
]);

/**
 * Whether a server frame is persistent (has an integer `seq` and is not a
 * control frame). `typing` frames with a `seq` are legacy persisted typing
 * activities: they advance the watermark but are reported as `typing`.
 */
export function isPersistent(frame: { type?: unknown; seq?: unknown }): frame is ActivityFrame {
  return (
    typeof frame.type === "string" &&
    !CONTROL_TYPES.has(frame.type) &&
    typeof frame.seq === "number" &&
    Number.isInteger(frame.seq) &&
    frame.seq > 0
  );
}

/** Close codes of the native endpoint (spec section 12.3). */
export const CloseCode = {
  normal: 1000,
  internalError: 1011,
  tooBig: 1009,
  restart: 1012,
  tryAgainLater: 1013,
  conversationNotFound: 1008,
  unsupportedProtocol: 4400,
  unauthorized: 4401,
  forbidden: 4403,
  idleTimeout: 4408,
  slowConsumer: 4503,
} as const;

/** Error codes the server marks retryable; a send with one is retried with the same clientId. */
export const RETRYABLE_SEND_ERRORS: ReadonlySet<string> = new Set([
  "rate_limited",
  "too_many_in_flight",
  "unavailable",
  "internal",
]);
