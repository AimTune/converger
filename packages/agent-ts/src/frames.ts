/**
 * Converger Protocol v1 frame types, as an agent on a channel-scoped
 * connection sees them.
 *
 * The protocol types are **generated** from the JSON Schemas in
 * `priv/protocol/v1/` of the server repository (published under
 * `https://converger.aimtune.dev/schemas/protocol/v1/`) by
 * `scripts/generate-types.mjs` into `src/generated/protocol.ts`; CI fails when
 * the committed output is stale. This module gives them the SDK's stable
 * public names. Every generated type is also available as `protocol.<Name>`
 * (for example `protocol.ServerPresenceFrame`).
 *
 * A few types stay hand-written because the SDK needs them looser than a
 * conforming sender's frame (`MessageFrame`, `InboundFrame`: receivers must
 * ignore unknown fields and frame types, section 5.5) or because no schema
 * describes them (`Attachment`, `TurnAction`). The unit tests validate every
 * frame the SDK builds against `frames/channel/agent-frame.schema.json` and
 * `client-envelope.schema.json`.
 *
 * @module
 */

import type * as P from "./generated/protocol.js";

/** Every generated protocol type, by its schema name (`protocol.ButtonsMessageData`, `protocol.ServerWelcomeFrame`, ...). */
export type * as protocol from "./generated/protocol.js";

/** The typed `data` of each message type (`messages/*.schema.json`, docs/protocol/messages.md). */
export type {
  AudioMessageData,
  ButtonsMessageData,
  CardMessageData,
  CarouselMessageData,
  ContactMessageData,
  FileMessageData,
  ImageMessageData,
  LocationMessageData,
  QuickReplyMessageData,
  TextMessageData,
  ToolCallMessageData,
  VideoMessageData,
} from "./generated/protocol.js";

/** Message type name to its `data` type, for `reply.message(type, data)`. */
export interface MessageDataMap {
  text: P.TextMessageData;
  "quick-reply": P.QuickReplyMessageData;
  buttons: P.ButtonsMessageData;
  card: P.CardMessageData;
  carousel: P.CarouselMessageData;
  image: P.ImageMessageData;
  file: P.FileMessageData;
  video: P.VideoMessageData;
  audio: P.AudioMessageData;
  location: P.LocationMessageData;
  contact: P.ContactMessageData;
}

/** The protocol version this SDK speaks. */
export const PROTOCOL_VERSION = "converger/1";

/** WebSocket subprotocol of the native endpoint (JSON text frames). */
export const SUBPROTOCOL = "converger.v1";

/** Default path of the native endpoint. */
export const DEFAULT_PATH = "/socket/converger/v1";

/** Any JSON object. */
export type JsonObject = Record<string, unknown>;

/** Who sent a persistent frame (`common.schema.json#/$defs/sender`). */
export type Sender = P.Sender;

/** A tappable chip or button (`common.schema.json#/$defs/messageAction`). */
export type MessageAction = P.MessageAction;

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
export type Limits = NonNullable<P.WelcomeData["limits"]>;

/** The channel `welcome` (section 10): no conversation, `scope: "channel"` (`frames/server/welcome.schema.json`). */
export type WelcomeFrame = P.ServerWelcomeFrame;

/** The data of an `error` frame (section 12.1). */
export type ErrorData = P.ErrorData;

/** `error`, bare (about the connection) or enveloped (about one conversation). */
export type ErrorFrame = P.ServerErrorFrame;

/** `ack` of a message frame sent with a `clientId` (section 7). */
export type AckFrame = P.ServerAckFrame;

/**
 * A message frame (section 5.1): `text` and every rich message type
 * (`buttons`, `card`, `image`, `location`, ...). Looser than the generated
 * `protocol.ServerMessageFrame` (every field but `type` and `data` optional),
 * because the SDK also reads frames from fake servers and older peers.
 */
export interface MessageFrame {
  type: string;
  id?: string;
  seq?: number;
  from?: P.From;
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
export type ResumeFrame = P.ClientResumeFrame;

/** `abort`: the end user asks the bot to stop the current run (forwarded). */
export type AbortFrame = P.ClientAbortFrame;

/** `genui_event`: an interaction with a GenUI component (forwarded). */
export type GenuiEventFrame = P.ClientGenuiEventFrame;

/** `replayTruncated`: more frames were missed than one replay carries (section 6.2). */
export type ReplayTruncatedFrame = P.ServerReplayTruncatedFrame;

/** `heartbeat` (section 8.5). */
export type HeartbeatFrame = P.ServerHeartbeatFrame;

/** `tokenRefreshed`: the answer to `auth` (section 3.3). */
export type TokenRefreshedFrame = P.ServerTokenRefreshedFrame;

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

/** `hello` on a channel-scoped connection (`frames/client/hello.schema.json`). */
export type HelloFrame = P.ClientHelloFrame;

/** One tool invocation (`messages/tool-call.schema.json`). */
export type ToolCallData = P.ToolCallMessageData;

/** Status of a tool call. */
export type ToolCallStatus = ToolCallData["status"];

/** A GenUI chunk (`common.schema.json#/$defs/aiChunk`). */
export type AIChunk = P.AiChunk;

/** `interrupt` data (`common.schema.json#/$defs/interruptData`). */
export type InterruptData = P.InterruptData;

/** Status of a `run` frame. */
export type RunStatus = P.RunData["status"];

/**
 * What an agent sends inside an envelope (`frames/channel/agent-frame.schema.json`):
 * a message frame, a mekik-native persistent frame (its `seq` is assigned by
 * the server), a transient bot frame, or `typing`, `read`, `sync`.
 */
export type AgentFrame =
  | { type: string; data: JsonObject; clientId?: string; id?: string; actions?: MessageAction[]; metadata?: JsonObject; replyTo?: { id?: string; seq?: number } }
  | { type: "tool_call"; data: ToolCallData }
  | { type: "genui"; streamId: string; done: boolean; chunk: AIChunk }
  | { type: "interrupt"; id: string; data: InterruptData }
  | { type: "interrupt_resolved"; id: string; data: P.InterruptResolvedData }
  | { type: "run"; data: P.RunData }
  | P.ClientTypingFrame
  | P.ClientReadFrame
  | P.ClientSyncFrame
  | ErrorFrame;

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
