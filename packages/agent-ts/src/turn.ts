/**
 * `turn`: one end-user message as an `onTurn` handler sees it.
 *
 * @module
 */

import type { Attachment, Envelope, InboundFrame, JsonObject, MessageFrame, Sender, TurnAction } from "./frames.js";

/** Where a turn came from, when the frame says so (`meta.channel` or `metadata.channel`). */
export interface TurnChannel {
  id?: string;
  type?: string;
  [key: string]: unknown;
}

/** Options of {@link Turn.history}. */
export interface HistoryOptions {
  /** Replay frames after this seq. Default 0 (the whole transcript, at most `replayMax` frames). */
  since?: number;
  /** Return at most the last `limit` frames. */
  limit?: number;
  /** Give up waiting for the replay after this long and return what arrived. Default 5000. */
  timeoutMs?: number;
}

/** One user turn. */
export interface Turn {
  /** The conversation (any channel: web widget, WhatsApp, Telegram, ...). */
  readonly conversationId: string;
  /** The message text: `data.text`, else a caption or title, else the tapped action's label, else `""`. */
  readonly text: string;
  /** The message frame (`type`, `data`, `id`, `seq`, `sender`, `metadata`, ...). */
  readonly message: MessageFrame;
  /** The message type (`text`, `image`, `location`, `buttons`, ...). */
  readonly type: string;
  /** The typed payload (`message.data`). */
  readonly data: JsonObject;
  /** Legacy `data.attachments`, or the data of an `image`/`file`/`video`/`audio` message. */
  readonly attachments: Attachment[];
  /** Who sent it (`message.sender`). */
  readonly participant: Sender | undefined;
  /** The end user's channel, when the frame carries it. */
  readonly channel: TurnChannel | undefined;
  /** mekik/1 per-turn context (`message.meta`), relayed and never stored. `{}` when absent. */
  readonly meta: JsonObject;
  /** Stored activity metadata (`message.metadata`). `{}` when absent. */
  readonly metadata: JsonObject;
  /** `metadata.action`: the action a tapped button or numeric reply chose (messages.md section 6). */
  readonly action: TurnAction | undefined;
  /** The activity this turn answers (a tapped button's message). */
  readonly replyTo: { id?: string; seq?: number } | undefined;
  /** The activity id and seq of the turn. */
  readonly id: string | undefined;
  readonly seq: number | undefined;
  /** Aborted when the end user sends `abort` or the agent stops. */
  readonly signal: AbortSignal;
  /** The raw `{conversationId, frame}` envelope. */
  readonly raw: Envelope<InboundFrame>;
  /**
   * The conversation's persistent frames as the agent sees them (`from: "user"`
   * for the end user, `"bot"` for agents), oldest first. Read with an enveloped
   * `sync` on the agent's socket: the REST history endpoint does not accept a
   * channel token for routed conversations.
   */
  history(options?: HistoryOptions): Promise<InboundFrame[]>;
}

const MEDIA = new Set(["image", "file", "video", "audio"]);

function record(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as JsonObject) : undefined;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

/** @internal */
export function buildTurn(
  envelope: Envelope<MessageFrame>,
  signal: AbortSignal,
  history: (options?: HistoryOptions) => Promise<InboundFrame[]>,
): Turn {
  const message = envelope.frame;
  const data = record(message.data) ?? {};
  const meta = record(message.meta) ?? {};
  const metadata = record(message.metadata) ?? {};
  const action = record(metadata["action"]) as TurnAction | undefined;

  const text =
    str(data["text"]) ?? str(data["caption"]) ?? str(data["title"]) ?? str(data["name"]) ?? str(action?.label) ?? "";

  let attachments: Attachment[] = [];
  if (Array.isArray(data["attachments"])) attachments = data["attachments"].filter((a) => record(a)) as Attachment[];
  else if (MEDIA.has(message.type)) attachments = [{ ...data, contentType: str(data["mimeType"]) ?? str(data["contentType"]) ?? message.type }];

  const rawChannel = meta["channel"] ?? metadata["channel"];
  const channel: TurnChannel | undefined =
    typeof rawChannel === "string" ? { type: rawChannel } : (record(rawChannel) as TurnChannel | undefined);

  return {
    conversationId: envelope.conversationId,
    text,
    message,
    type: message.type,
    data,
    attachments,
    participant: message.sender,
    channel,
    meta,
    metadata,
    action,
    replyTo: message.replyTo,
    id: message.id,
    seq: message.seq,
    signal,
    raw: envelope as Envelope<InboundFrame>,
    history,
  };
}
