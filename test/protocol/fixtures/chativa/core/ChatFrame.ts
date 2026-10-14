/**
 * ChatFrame — the JSON wire frames every message-oriented connector understands.
 *
 * Chativa's rich features (tool-call traces, Generative UI, human-in-the-loop
 * chips) are not transport features: a `{ type: "genui", ... }` frame means the
 * same thing whether it arrived over a WebSocket, a SignalR hub, an SSE stream
 * or an HTTP poll. This file is that shared vocabulary, so a backend can speak
 * one dialect and swap transports, and a connector can gain the features by
 * routing its payloads through `parseChatFrame` instead of re-deriving the rules.
 *
 * The parser deliberately covers only the *rich* frames. Anything else comes
 * back as `{ kind: "other" }` and stays the connector's business — each one
 * already has its own idea of what a plain payload means (`connected` notices,
 * bare text, batched history), and this must not take that over.
 *
 * No external dependencies allowed in this file.
 */

import type { IncomingMessage, MessageAction } from "./Message";
import type { ToolCall } from "./ToolCall";
import type {
  AIChunk,
  GenUIComponentDefinition,
  GenUIEventOptions,
  GenUIEventScope,
} from "./GenUI";

/** A wire frame parsed into what the connector should do with it. */
export type ChatFrame =
  /** Tool-call lifecycle: upsert by `id` as it advances running → completed/error. */
  | { kind: "tool_call"; toolCall: ToolCall }
  /** One Generative UI chunk of the `streamId` stream. */
  | { kind: "genui"; streamId: string; chunk: AIChunk; done: boolean }
  /**
   * The server's catalog of components it defines itself — register them, then
   * mount by name. `hash` versions the catalog (send it back in the next
   * handshake); `unchanged` means the client's cached catalog is still current
   * and `definitions` is empty.
   */
  | {
      kind: "genui_components";
      definitions: GenUIComponentDefinition[];
      hash?: string;
      unchanged: boolean;
    }
  /** Typing indicator toggle. */
  | { kind: "typing"; isTyping: boolean }
  /** A bot question with chips — the human-in-the-loop interrupt. */
  | { kind: "quick_reply"; message: IncomingMessage }
  /** Not a rich frame. The connector applies its own handling. */
  | { kind: "other" };

export interface ParseChatFrameOptions {
  /**
   * Prefix for the id given to a frame that carries none, so ids stay
   * traceable to the connector that minted them (e.g. `"ws"` → `"ws-1699…"`).
   */
  idPrefix?: string;
  /** Injectable clock — keeps the parser deterministic under test. */
  now?: () => number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/**
 * Classify one decoded JSON payload.
 *
 * Pure: it decides *what* a frame is, never what to do about it — the caller
 * owns the handlers, the ordering and any transport-specific extras.
 *
 * @example
 * const frame = parseChatFrame(JSON.parse(raw), { idPrefix: "ws" });
 * switch (frame.kind) {
 *   case "tool_call":   return onToolCall(frame.toolCall);
 *   case "genui":       return onGenUIChunk(frame.streamId, frame.chunk, frame.done);
 *   case "genui_components": return onGenUIComponents(frame.definitions);
 *   case "typing":      return onTyping(frame.isTyping);
 *   case "quick_reply": return onMessage(frame.message);
 *   case "other":       break; // your own handling
 * }
 */
export function parseChatFrame(
  raw: unknown,
  options: ParseChatFrameOptions = {},
): ChatFrame {
  if (!isRecord(raw)) return { kind: "other" };
  const { idPrefix = "frame", now = () => Date.now() } = options;

  // { type: "tool_call", data: {...ToolCall} } — the payload may also be
  // flattened onto the frame itself, which several backends do.
  if (raw.type === "tool_call") {
    const payload = (raw.data ?? raw) as Partial<ToolCall>;
    if (
      typeof payload.id === "string" &&
      typeof payload.name === "string" &&
      typeof payload.status === "string"
    ) {
      return { kind: "tool_call", toolCall: payload as ToolCall };
    }
    return { kind: "other" }; // malformed — don't fabricate a trace
  }

  // { type: "genui", streamId, chunk, done }
  if (raw.type === "genui") {
    const streamId = typeof raw.streamId === "string" ? raw.streamId : "";
    const chunk = raw.chunk;
    if (streamId && isRecord(chunk)) {
      return {
        kind: "genui",
        streamId,
        chunk: chunk as unknown as AIChunk,
        done: raw.done === true,
      };
    }
    return { kind: "other" };
  }

  // { type: "genui_components", hash?, unchanged?, components: [{ name, template, … }] }
  // The server defines the component itself; the client registers it and mounts
  // it by name from then on. `unchanged: true` is the cache hit — the client's
  // stored catalog matches `hash`, so no markup travels. A definition without a
  // name or a string template is dropped: a half-formed component would render
  // as an empty bubble.
  if (raw.type === "genui_components") {
    const list = Array.isArray(raw.components) ? raw.components : [];
    const definitions = list.filter(
      (d): d is GenUIComponentDefinition =>
        isRecord(d) && typeof d.name === "string" && !!d.name && typeof d.template === "string"
    );
    const unchanged = raw.unchanged === true;
    if (definitions.length === 0 && !unchanged) return { kind: "other" };
    return {
      kind: "genui_components",
      definitions,
      unchanged,
      ...(typeof raw.hash === "string" && raw.hash ? { hash: raw.hash } : {}),
    };
  }

  // { type: "typing", isTyping: boolean }
  if (raw.type === "typing") {
    return { kind: "typing", isTyping: raw.isTyping === true };
  }

  // A bot text frame carrying `actions` is the HITL interrupt (or a suggestion
  // list). It becomes a native quick-reply so the chips render without a custom
  // component, and tapping one sends the answer that resumes the paused run.
  //
  // `from: "user"` frames are excluded: those are the transcript replay or
  // multi-tab fan-out of the user's *own* message, and re-offering the chips
  // there would invite answering the same question twice.
  if (
    raw.type === "text" &&
    raw.from !== "user" &&
    Array.isArray(raw.actions) &&
    raw.actions.length > 0
  ) {
    const inner = isRecord(raw.data) ? raw.data : {};
    return {
      kind: "quick_reply",
      message: {
        id: typeof raw.id === "string" ? raw.id : `${idPrefix}-${now()}`,
        type: "quick-reply",
        // keepActions leaves the chips rendered after the tap, so the
        // transcript still reads as a record of what was asked and answered.
        data: { ...inner, actions: raw.actions as MessageAction[], keepActions: true },
        timestamp: typeof raw.timestamp === "number" ? raw.timestamp : now(),
      },
    };
  }

  return { kind: "other" };
}

/**
 * Build the outbound frame for a GenUI component event (form submit, card action…).
 *
 * `scope` and `component` are omitted when unknown rather than sent as `null`, so a
 * backend that does not model routing sees exactly the frame it saw before.
 */
export function createGenUIEventFrame(
  streamId: string,
  eventType: string,
  payload: unknown,
  opts?: GenUIEventOptions,
): {
  type: "genui_event";
  streamId: string;
  eventType: string;
  payload: unknown;
  scope?: GenUIEventScope;
  component?: string;
} {
  return {
    type: "genui_event",
    streamId,
    eventType,
    payload,
    ...(opts?.scope ? { scope: opts.scope } : {}),
    ...(opts?.component ? { component: opts.component } : {}),
  };
}
