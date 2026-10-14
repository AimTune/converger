/**
 * `reply`: what an `onTurn` handler answers with. Every helper maps to one
 * agent frame of Protocol v1 (`frames/channel/agent-frame.schema.json`), sent
 * in a `{conversationId, frame}` envelope:
 *
 * | helper | frame |
 * | --- | --- |
 * | `text(text, {actions})` | `text` message (+ `actions` chips), with a `clientId`, resolved by its `ack` |
 * | `message(type, data)` | any message type (`buttons`, `card`, `image`, ...), acked |
 * | `stream()` | `genui` `text` chunks of the turn's stream, one chunk id per stream (mekik `emitToken`) |
 * | `ui(component, props)` | a `genui` `ui` chunk of the turn's stream |
 * | `toolCall(id, status, ...)` | `tool_call` (upserted by id) |
 * | `ask(payload, ...)` | `interrupt`, then `run interrupted`; on `resume`: `interrupt_resolved` and `run started` |
 * | `typing(on)` | `typing` (refreshed while on) |
 * | `end()` | closes the genui stream (`stream_done`), stops typing, `run finished` |
 *
 * @module
 */

import { AgentError } from "./errors.js";
import type {
  AckFrame,
  AIChunk,
  InterruptData,
  JsonObject,
  MessageAction,
  MessageDataMap,
  RunStatus,
  ToolCallData,
  ToolCallStatus,
} from "./frames.js";

/**
 * How `reply.stream()` reaches the end user:
 *
 * - `genui` (default): token deltas as `genui` text chunks (live in chativa and
 *   every mekik/1 client). End-user channels that do not render `genui`
 *   (WhatsApp, Telegram, ...) receive nothing until the hub joins text chunks
 *   into one message (planned in #68).
 * - `text`: deltas are buffered and sent as one `text` message at `end()`;
 *   reaches every channel today, no live tokens.
 * - `genui+text`: both; web clients that render genui show the text twice.
 */
export type StreamMode = "genui" | "text" | "genui+text";

/** Options of a message send. */
export interface SendOptions {
  /** Quick-reply chips (frame-level `actions`, the chativa `parseChatFrame` rule). */
  actions?: MessageAction[];
  /** Activity metadata stored with the message (at most 16 KiB as JSON). */
  metadata?: JsonObject;
  /** The activity this message answers. */
  replyTo?: { id?: string; seq?: number };
  /** A message id to keep (mekik style). Default: none; the server mints one. */
  id?: string;
}

/** Options of {@link Reply.toolCall}. */
export interface ToolCallOptions {
  /** The tool's name. Required on the first call for an id; remembered afterwards. */
  name?: string;
  description?: string;
  params?: JsonObject;
  result?: unknown;
  error?: string;
}

/** Options of {@link Reply.ask}. */
export interface AskOptions {
  /** Answer chips. Without `actions`, `ui`, `event` or `tool` clients offer Approve and Cancel. */
  actions?: MessageAction[];
  /** A GenUI form component that answers the interrupt. */
  ui?: { component: string; props?: JsonObject };
  /** Interrupt id (thread-scoped). Default: a random id. */
  id?: string;
  /** Reject with code `timeout` after this long. Default: wait until the turn is aborted or the agent stops. */
  timeoutMs?: number;
  /** Reject with code `aborted` when this signal aborts. */
  signal?: AbortSignal;
}

/** Options of {@link Reply.stream}. */
export interface StreamOptions {
  mode?: StreamMode;
}

/** A token stream started with {@link Reply.stream}. */
export interface ReplyStream {
  /** The `genui` stream id (the turn's stream). */
  readonly streamId: string;
  /** Everything written so far. */
  readonly text: string;
  /** Append a token delta. Deltas are coalesced and flushed every `streamFlushMs`. */
  write(delta: string): void;
  /** Flush and close the stream. In `text` modes resolves with the message's ack. Idempotent. */
  end(): Promise<AckFrame | undefined>;
}

/** The answer side of one turn. */
export interface Reply {
  /** The conversation this reply writes to. */
  readonly conversationId: string;
  /** Whether {@link Reply.end} was called (or the handler returned). */
  readonly ended: boolean;
  /** Send a `text` message, optionally with quick-reply chips. Resolves with the server's ack. */
  text(text: string, options?: SendOptions): Promise<AckFrame | undefined>;
  /** Start a token stream (see {@link StreamMode}). */
  stream(options?: StreamOptions): ReplyStream;
  /**
   * Send any message type (`buttons`, `quick-reply`, `card`, `carousel`, `image`, `file`, `location`, ...).
   * The vocabulary's types are checked against their generated schema types ({@link MessageDataMap}).
   */
  message<T extends keyof MessageDataMap>(type: T, data: MessageDataMap[T], options?: SendOptions): Promise<AckFrame | undefined>;
  /** Send a message type outside the vocabulary (an opaque renderer type, mekik/1 section 4.5). */
  message<T extends string>(
    type: T extends keyof MessageDataMap ? never : T,
    data: JsonObject,
    options?: SendOptions,
  ): Promise<AckFrame | undefined>;
  /** Report a tool call; call again with the same id as it advances. */
  toolCall(id: string, status: ToolCallStatus, options?: ToolCallOptions): Promise<void>;
  /** Send a GenUI component chunk. Resolves with its chunk id (send again with `{id}` to update it in place). */
  ui(component: string, props?: JsonObject, options?: { id?: string | number }): Promise<string | number>;
  /**
   * Ask the end user (an `interrupt`) and wait for the answer (`resume`), from
   * any channel: the hub turns a tapped button or a numeric reply into `resume`.
   * A string `payload` becomes `{title: payload}`.
   */
  ask<T = unknown>(payload: unknown, options?: AskOptions): Promise<T>;
  /** Show (or hide) the typing indicator; refreshed while on. */
  typing(on?: boolean): Promise<void>;
  /** Send a raw agent frame in this conversation's envelope. */
  send(frame: JsonObject): Promise<AckFrame | undefined>;
  /** Finish the turn: close streams, stop typing, `run finished`. Idempotent. */
  end(): Promise<void>;
}

/** @internal */
export interface ReplyCore {
  send(conversationId: string, frame: JsonObject): Promise<AckFrame | undefined>;
  nextClientId(): string;
  randomId(prefix: string): string;
  waitForAnswer(conversationId: string, interruptId: string, signal: AbortSignal | undefined, timeoutMs: number | undefined): Promise<unknown>;
  readonly streamMode: StreamMode;
  readonly streamFlushMs: number;
  readonly typingRefreshMs: number;
}

/** @internal */
export interface ReplyInit {
  /** Send `run` frames around the turn. */
  run: boolean;
  /** Aborted when the end user sends `abort` or the agent stops. */
  signal?: AbortSignal | undefined;
}

/** @internal */
export class ReplyImpl implements Reply {
  readonly conversationId: string;
  readonly #core: ReplyCore;
  readonly #run: boolean;
  readonly #signal: AbortSignal | undefined;
  readonly #tools = new Map<string, { name: string; startedAt: number }>();
  readonly #streams = new Set<StreamImpl>();
  #streamId: string | undefined;
  #chunkId = 0;
  #genuiOpen = false;
  #typing: ReturnType<typeof setInterval> | undefined;
  #typingOn = false;
  #ending: Promise<void> | undefined;
  #status: RunStatus = "finished";

  constructor(conversationId: string, core: ReplyCore, init: ReplyInit) {
    this.conversationId = conversationId;
    this.#core = core;
    this.#run = init.run;
    this.#signal = init.signal;
    if (this.#run) void this.#sendRun("started");
  }

  get ended(): boolean {
    return this.#ending !== undefined;
  }

  /** @internal The genui stream id of this turn. */
  get streamId(): string {
    this.#streamId ??= this.#core.randomId("stream");
    return this.#streamId;
  }

  /** @internal Mark how the run ends (error, aborted). */
  setStatus(status: RunStatus): void {
    this.#status = status;
  }

  text(text: string, options: SendOptions = {}): Promise<AckFrame | undefined> {
    return this.message("text", { text }, options);
  }

  message(type: string, data: JsonObject, options: SendOptions = {}): Promise<AckFrame | undefined> {
    if (!/^[a-z][a-z0-9_-]{0,63}$/.test(type)) {
      return Promise.reject(new AgentError("invalid_message", `invalid message type: ${type}`, { retryable: false }));
    }
    const frame: JsonObject = { type, clientId: this.#core.nextClientId(), data };
    if (options.actions && options.actions.length > 0) frame["actions"] = options.actions;
    if (options.metadata) frame["metadata"] = options.metadata;
    if (options.replyTo) frame["replyTo"] = options.replyTo;
    if (options.id) frame["id"] = options.id;
    this.#stopTypingTimer();
    this.#typingOn = false;
    return this.#core.send(this.conversationId, frame);
  }

  stream(options: StreamOptions = {}): ReplyStream {
    const stream = new StreamImpl(this, options.mode ?? this.#core.streamMode, this.#core.streamFlushMs, () => {
      this.#streams.delete(stream);
    });
    this.#streams.add(stream);
    return stream;
  }

  async toolCall(id: string, status: ToolCallStatus, options: ToolCallOptions = {}): Promise<void> {
    const known = this.#tools.get(id);
    const name = options.name ?? known?.name;
    if (!name) throw new AgentError("invalid_message", `toolCall(${id}) needs a name on its first call`, { retryable: false });
    const startedAt = known?.startedAt ?? Date.now();
    this.#tools.set(id, { name, startedAt });
    const data: ToolCallData = { id, name, status, startedAt };
    if (options.description !== undefined) data.description = options.description;
    if (options.params !== undefined) data.params = options.params;
    if (options.result !== undefined) data.result = options.result;
    if (options.error !== undefined) data.error = options.error;
    if (status !== "running") data.endedAt = Date.now();
    await this.#core.send(this.conversationId, { type: "tool_call", data: data as unknown as JsonObject });
  }

  async ui(component: string, props: JsonObject = {}, options: { id?: string | number } = {}): Promise<string | number> {
    const id = options.id ?? this.nextChunkId();
    await this.sendChunk({ type: "ui", component, props, id });
    return id;
  }

  async ask<T = unknown>(payload: unknown, options: AskOptions = {}): Promise<T> {
    const id = options.id ?? this.#core.randomId("ask");
    const data: InterruptData = { payload: typeof payload === "string" ? { title: payload } : payload };
    if (options.actions && options.actions.length > 0) data.actions = options.actions;
    if (options.ui) data.ui = options.ui;
    const signals = [this.#signal, options.signal].filter((s): s is AbortSignal => s !== undefined);
    const signal = signals.length === 0 ? undefined : signals.length === 1 ? signals[0] : AbortSignal.any(signals);
    // Register before sending, so an instant answer is not missed.
    const answer = this.#core.waitForAnswer(this.conversationId, id, signal, options.timeoutMs);
    answer.catch(() => undefined);
    this.#stopTypingTimer();
    await this.#core.send(this.conversationId, { type: "interrupt", id, data: data as unknown as JsonObject });
    if (this.#run) void this.#sendRun("interrupted");
    const value = await answer;
    await this.#core.send(this.conversationId, { type: "interrupt_resolved", id, data: { answer: value } });
    if (this.#run && !this.ended) void this.#sendRun("started");
    return value as T;
  }

  async typing(on = true): Promise<void> {
    this.#stopTypingTimer();
    this.#typingOn = on;
    await this.#core.send(this.conversationId, { type: "typing", isTyping: on });
    if (on && this.#core.typingRefreshMs > 0) {
      // An indicator not refreshed within 6 s expires (spec section 8.2).
      this.#typing = setInterval(() => {
        void this.#core.send(this.conversationId, { type: "typing", isTyping: true }).catch(() => undefined);
      }, this.#core.typingRefreshMs);
    }
  }

  send(frame: JsonObject): Promise<AckFrame | undefined> {
    return this.#core.send(this.conversationId, frame);
  }

  end(): Promise<void> {
    this.#ending ??= this.#finish();
    return this.#ending;
  }

  async #finish(): Promise<void> {
    this.#stopTypingTimer();
    const pending: Promise<unknown>[] = [];
    for (const stream of [...this.#streams]) pending.push(stream.end().catch(() => undefined));
    await Promise.all(pending);
    if (this.#typingOn) {
      this.#typingOn = false;
      await this.#core.send(this.conversationId, { type: "typing", isTyping: false }).catch(() => undefined);
    }
    if (this.#genuiOpen) {
      this.#genuiOpen = false;
      await this.#core
        .send(this.conversationId, {
          type: "genui",
          streamId: this.streamId,
          done: true,
          chunk: { type: "event", name: "stream_done", id: this.nextChunkId() },
        })
        .catch(() => undefined);
    }
    if (this.#run) await this.#sendRun(this.#status);
  }

  /** @internal */
  nextChunkId(): number {
    this.#chunkId += 1;
    return this.#chunkId;
  }

  /** @internal */
  async sendChunk(chunk: AIChunk): Promise<void> {
    this.#genuiOpen = true;
    await this.#core.send(this.conversationId, { type: "genui", streamId: this.streamId, done: false, chunk: chunk as unknown as JsonObject });
  }

  /** @internal */
  sendText(text: string): Promise<AckFrame | undefined> {
    return this.text(text);
  }

  #sendRun(status: RunStatus): Promise<void> {
    return this.#core.send(this.conversationId, { type: "run", data: { status } }).then(
      () => undefined,
      () => undefined,
    );
  }

  #stopTypingTimer(): void {
    if (this.#typing) clearInterval(this.#typing);
    this.#typing = undefined;
  }
}

class StreamImpl implements ReplyStream {
  readonly #reply: ReplyImpl;
  readonly #mode: StreamMode;
  readonly #flushMs: number;
  readonly #onEnd: () => void;
  #chunkId: number | undefined;
  #buffer = "";
  #text = "";
  #timer: ReturnType<typeof setTimeout> | undefined;
  #flushing: Promise<void> = Promise.resolve();
  #ending: Promise<AckFrame | undefined> | undefined;

  constructor(reply: ReplyImpl, mode: StreamMode, flushMs: number, onEnd: () => void) {
    this.#reply = reply;
    this.#mode = mode;
    this.#flushMs = flushMs;
    this.#onEnd = onEnd;
  }

  get streamId(): string {
    return this.#reply.streamId;
  }

  get text(): string {
    return this.#text;
  }

  write(delta: string): void {
    if (this.#ending) throw new AgentError("closed", "write() after end()", { retryable: false });
    if (typeof delta !== "string" || delta === "") return;
    this.#text += delta;
    if (this.#mode === "text") return;
    this.#buffer += delta;
    // Coalesce deltas: at most one frame per flush interval (the server allows
    // 20 inbound frames per second per connection, spec section 11).
    this.#timer ??= setTimeout(() => {
      this.#timer = undefined;
      this.#flush();
    }, this.#flushMs);
  }

  end(): Promise<AckFrame | undefined> {
    this.#ending ??= this.#end();
    return this.#ending;
  }

  async #end(): Promise<AckFrame | undefined> {
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = undefined;
    this.#flush();
    try {
      await this.#flushing;
      if (this.#mode !== "genui" && this.#text !== "") return await this.#reply.sendText(this.#text);
      return undefined;
    } finally {
      this.#onEnd();
    }
  }

  #flush(): void {
    // Chain flushes so chunks keep their order; deltas written while a flush is
    // on the wire are coalesced into the next one.
    this.#flushing = this.#flushing.then(async () => {
      if (this.#buffer === "") return;
      const content = this.#buffer;
      this.#buffer = "";
      // Consecutive deltas share one chunk id: one growing bubble (mekik emitToken).
      this.#chunkId ??= this.#reply.nextChunkId();
      await this.#reply.sendChunk({ type: "text", content, id: this.#chunkId }).catch(() => undefined);
    });
  }
}
