/**
 * One conversation session: connection lifecycle, reconnects, the watermark,
 * the outbox and acks. Transport-independent (see `./transport/types.ts`).
 *
 * @module
 */

import { backoffDelay, type ResolvedReconnect } from "./backoff.js";
import { TypedEmitter } from "./emitter.js";
import { ConvergerClosedError, ConvergerError, ConvergerProtocolError } from "./errors.js";
import {
  CloseCode,
  RETRYABLE_SEND_ERRORS,
  isPersistent,
  type AckFrame,
  type ActivityFrame,
  type Attachment,
  type ClientFrame,
  type ClientMessageFrame,
  type DeliveryStatusFrame,
  type ErrorFrame,
  type PresenceFrame,
  type ReplayTruncatedFrame,
  type ServerFrame,
  type TypingFrame,
  type WelcomeFrame,
} from "./protocol/frames.js";
import type { HistoryOptions, RestClient, UploadOptions } from "./rest/client.js";
import type { ActivitySet, ConversationStatusResponse, UploadResponse } from "./rest/types.js";
import type { ConversationStore, OutboxEntry } from "./storage/outbox.js";
import { TokenManager } from "./token.js";
import type { Transport, TransportClose, TransportEnvironment, TransportFactory } from "./transport/types.js";

/** Connection state of a conversation session. */
export type ConnectionState = "idle" | "connecting" | "open" | "reconnecting" | "closed";

/** Payload of the `connectionState` event. */
export interface ConnectionStateChange {
  state: ConnectionState;
  previous: ConnectionState;
  /** Consecutive failed attempts (0 when open). */
  attempt: number;
  /** Delay before the next attempt, when reconnecting. */
  delayMs?: number;
  /** The transport in use or about to be used. */
  transport: string;
  /** Why the session closed or the connection dropped. */
  close?: TransportClose;
  /** Set when the session closed for good. */
  error?: ConvergerError;
}

/** The result of a send, once the server acknowledged it. */
export interface SendResult {
  clientId: string;
  /** Activity id. */
  id: string;
  seq: number;
  timestamp?: number;
  /** The server had already stored this clientId (a resend). */
  duplicate: boolean;
}

/** Payload of the `sendFailed` event. */
export interface SendFailure {
  clientId: string;
  error: ConvergerError;
}

/** Events of a {@link Conversation}. */
export interface ConversationEvents {
  [key: string]: unknown;
  /** A persistent frame (message, event, conversation update), live or replayed, in seq order per connection. Own turns acknowledged in this session are not repeated. */
  activity: ActivityFrame;
  /** Delivery progress or a read receipt. */
  deliveryStatus: DeliveryStatusFrame;
  /** Someone else started or stopped typing. */
  typing: TypingFrame;
  /** A participant came online or went offline. */
  presence: PresenceFrame;
  /** The connection state changed. */
  connectionState: ConnectionStateChange;
  /** A handshake completed (also after every reconnect). */
  welcome: WelcomeFrame["data"];
  /** A send was acknowledged (also for sends restored from storage, which have no promise). */
  sent: SendResult;
  /** A send was rejected for good and removed from the outbox. */
  sendFailed: SendFailure;
  /** More frames were missing than the server replays at once; the client keeps syncing. */
  replayTruncated: ReplayTruncatedFrame["data"];
  /** A non-fatal problem (protocol error not tied to a send, storage or token refresh failure). */
  error: ConvergerError;
}

/** What `send` accepts besides plain text. */
export interface SendMessage {
  text: string;
  attachments?: Attachment[];
  /** Stored with the activity (REST `channelData`). */
  metadata?: Record<string, unknown>;
  /** Per-turn context relayed to the bot channel, never stored. */
  meta?: Record<string, unknown>;
  /** The activity this turn answers. */
  replyTo?: string;
  /** Your own clientId (1-128 of `A-Z a-z 0-9 . _ : ~ -`); generated when absent. */
  clientId?: string;
}

/** @internal */
export interface ConversationDeps {
  conversationId: string | null;
  tokens: TokenManager;
  restFor: (getToken: () => Promise<string>) => RestClient;
  baseUrl: string;
  transports: TransportFactory[];
  fallbackAfterAttempts: number;
  reconnect: ResolvedReconnect;
  env: TransportEnvironment;
  store: ConversationStore;
  refreshSkewMs: number;
  replayWaitMs: number;
  gapWaitMs: number;
  onDispose: (conversation: Conversation) => void;
}

const CLIENT_ID = /^[A-Za-z0-9._:~-]{1,128}$/;
const FATAL_CLOSE_CODES = new Set<number>([
  CloseCode.unsupportedProtocol,
  CloseCode.forbidden,
  CloseCode.conversationNotFound,
  4404,
]);
const MAX_AUTH_REJECTIONS = 3;

function randomClientId(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (c?.randomUUID) return c.randomUUID();
  let id = "c-";
  for (let i = 0; i < 24; i += 1) id += Math.floor(Math.random() * 36).toString(36);
  return id;
}

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  // Callers may ignore the promise; never report it as unhandled.
  promise.catch(() => undefined);
  return { promise, resolve, reject };
}

/**
 * A conversation session. Create it with `client.conversation()`, then call
 * {@link start} (a new conversation) or {@link resume} (an existing one).
 *
 * Guarantees:
 * - **Ordered, gap-free receive.** Every persistent frame is emitted once; after
 *   a reconnect the session resumes from its watermark (the highest contiguous
 *   seq it has seen), so nothing committed meanwhile is missed.
 * - **Exactly-once send.** Every send gets a clientId and sits in the
 *   persistent outbox until its `ack`. After a reconnect each unacked send is
 *   put on the wire once more, after the replay; the server stores a clientId
 *   only once and answers a resend with the original ack.
 */
export class Conversation extends TypedEmitter<ConversationEvents> {
  readonly #deps: ConversationDeps;
  #tokens: TokenManager;
  #conversationId: string | null;
  #userId: string | undefined;
  #watermark = 0;
  /** Seqs above the watermark already seen (frames and own acks). */
  readonly #seen = new Set<number>();
  /** Seqs and ids of own turns acknowledged in this session. */
  readonly #ownSeqs = new Set<number>();
  readonly #ownIds = new Set<string>();

  #state: ConnectionState = "idle";
  #transport: Transport | undefined;
  #transportIndex = 0;
  #failuresOnTransport = 0;
  #attempt = 0;
  #authRejections = 0;
  #stopped = false;
  #started = false;
  #welcomed = false;
  #connectToken = 0;

  #reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  #refreshTimer: ReturnType<typeof setTimeout> | undefined;
  #replayTimer: ReturnType<typeof setTimeout> | undefined;
  #gapTimer: ReturnType<typeof setTimeout> | undefined;
  #syncTimer: ReturnType<typeof setTimeout> | undefined;

  #replaying = false;
  #replayTarget = 0;
  #maxInFlight = 32;
  readonly #inFlight = new Set<string>();
  readonly #retryAt = new Map<string, number>();
  #retryTimer: ReturnType<typeof setTimeout> | undefined;
  readonly #waiting = new Map<string, Deferred<SendResult>>();
  #ready: Deferred<WelcomeFrame["data"]> | undefined;
  #lastWelcome: WelcomeFrame["data"] | undefined;
  #fatal: ConvergerError | undefined;

  /** @internal */
  constructor(deps: ConversationDeps) {
    super();
    this.#deps = deps;
    this.#tokens = deps.tokens;
    this.#conversationId = deps.conversationId;
    this.setListenerErrorHandler((error) => {
      if (error instanceof ConvergerError) return;
      this.emit("error", new ConvergerError("listener_error", "an event listener threw", { cause: error }));
    });
  }

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /** The conversation id (known after `welcome` for a new conversation). */
  get conversationId(): string | null {
    return this.#conversationId;
  }

  /** The end-user id of the session (from the token, or echoed/minted by the server). */
  get userId(): string | undefined {
    return this.#userId;
  }

  /** The highest contiguous seq seen; resume from here. */
  get watermark(): number {
    return this.#watermark;
  }

  get state(): ConnectionState {
    return this.#state;
  }

  /** The transport in use (`native`, `phoenix`, `sse` or a custom name). */
  get transport(): string {
    return this.#currentFactory().transportName ?? "custom";
  }

  /** The last `welcome` data (limits, capabilities, expiry). */
  get session(): WelcomeFrame["data"] | undefined {
    return this.#lastWelcome;
  }

  /** Sends not yet acknowledged, oldest first (including ones restored from storage). */
  get pending(): readonly OutboxEntry[] {
    return this.#deps.store.entries;
  }

  /**
   * Start a new conversation. With a token restricted to a conversation, that
   * conversation is used. Resolves on the first `welcome`; rejects when the
   * session closes for good before that.
   */
  async start(): Promise<WelcomeFrame["data"]> {
    if (this.#started) throw new ConvergerError("already_started", "start() or resume() was already called");
    this.#started = true;
    this.#conversationId = null;
    return this.#open();
  }

  /**
   * Resume an existing conversation from a watermark: everything with a higher
   * seq is replayed first. Without an argument the stored watermark is used
   * (0, the whole transcript, when there is none).
   */
  async resume(watermark?: number): Promise<WelcomeFrame["data"]> {
    if (this.#started) throw new ConvergerError("already_started", "start() or resume() was already called");
    if (!this.#conversationId) {
      throw new ConvergerError("no_conversation", "resume() needs a conversation id: client.conversation(id)");
    }
    this.#started = true;
    await this.#deps.store.load();
    const stored = this.#deps.store.state;
    if (stored?.userId) this.#userId = stored.userId;
    if (watermark !== undefined) {
      if (!Number.isInteger(watermark) || watermark < 0) {
        throw new ConvergerError("invalid_watermark", "the watermark must be a non-negative integer");
      }
      this.#watermark = watermark;
    } else if (stored && stored.conversationId === this.#conversationId) {
      this.#watermark = stored.watermark;
    }
    return this.#open();
  }

  /**
   * Send a text turn. The promise resolves with the server's `ack`. The
   * message is written to the outbox first, so it is resent after a reconnect
   * (or, with persistent storage, after a reload) until acknowledged; a
   * non-retryable error rejects it and removes it from the outbox.
   */
  send(message: string | SendMessage): Promise<SendResult> {
    if (this.#fatal) return Promise.reject(this.#fatal);
    const input: SendMessage = typeof message === "string" ? { text: message } : message;
    if (typeof input.text !== "string") {
      return Promise.reject(new ConvergerError("invalid_message", "text must be a string"));
    }
    const clientId = input.clientId ?? randomClientId();
    if (!CLIENT_ID.test(clientId)) {
      return Promise.reject(new ConvergerError("invalid_client_id", "clientId must be 1-128 of A-Z a-z 0-9 . _ : ~ -"));
    }
    if (this.#deps.store.get(clientId) || this.#waiting.has(clientId)) {
      return Promise.reject(new ConvergerError("duplicate_client_id", `clientId ${clientId} is already pending`));
    }
    const frame: ClientMessageFrame = { type: "text", clientId, data: { text: input.text } };
    if (input.attachments) frame.data.attachments = input.attachments;
    if (input.metadata) frame.metadata = input.metadata;
    if (input.meta) frame.meta = input.meta;
    if (input.replyTo) frame.replyTo = { id: input.replyTo };

    const wait = deferred<SendResult>();
    this.#waiting.set(clientId, wait);
    this.#deps.store.add({ clientId, frame, createdAt: Date.now(), attempts: 0 });
    this.#flush();
    return wait.promise;
  }

  /** Tell the others you are (not) typing. Dropped when offline or unsupported. */
  typing(isTyping: boolean): boolean {
    if (this.#state !== "open" || !this.#transport?.capabilities.signals) return false;
    return this.#transport.send({ type: "typing", isTyping });
  }

  /** Mark everything up to `seq` (default: the watermark) as read. */
  markRead(seq: number = this.#watermark): boolean {
    if (seq < 1 || this.#state !== "open" || !this.#transport?.capabilities.signals) return false;
    return this.#transport.send({ type: "read", watermark: seq });
  }

  /** Page through the REST history (`GET .../activities`). */
  history(options: HistoryOptions = {}): AsyncGenerator<ActivitySet, void, void> {
    return this.#rest().history(this.#requireId(), options);
  }

  /** Upload a file; the server posts an activity carrying it (`POST .../upload`). */
  upload(file: Blob, options: UploadOptions = {}): Promise<UploadResponse> {
    return this.#rest().upload(this.#requireId(), file, options);
  }

  /** Close the conversation on the server (`POST .../close`). The session stays connected. */
  closeConversation(): Promise<ConversationStatusResponse> {
    return this.#rest().closeConversation(this.#requireId());
  }

  /** Reopen a closed conversation (`POST .../reopen`). */
  reopenConversation(): Promise<ConversationStatusResponse> {
    return this.#rest().reopenConversation(this.#requireId());
  }

  /**
   * Disconnect for good. Unacknowledged sends stay in the outbox (and in
   * persistent storage) and are resent by the next session for this
   * conversation; their promises reject with `ConvergerClosedError`.
   */
  async disconnect(): Promise<void> {
    this.#stopped = true;
    this.#clearTimers();
    const transport = this.#transport;
    this.#transport = undefined;
    transport?.close(CloseCode.normal, "client disconnect");
    this.#setState("closed", {});
    this.#rejectWaiting(new ConvergerClosedError("disconnected; the message stays in the outbox", "disconnected"));
    this.#ready?.reject(new ConvergerClosedError("disconnected before the session was established", "disconnected"));
    await this.#deps.store.flush();
    this.#deps.onDispose(this);
  }

  /** Drop every unacknowledged send of this conversation (memory and storage). */
  async discardOutbox(): Promise<void> {
    for (const entry of [...this.#deps.store.entries]) this.#deps.store.remove(entry.clientId);
    this.#rejectWaiting(new ConvergerError("discarded", "the outbox was discarded"));
    await this.#deps.store.flush();
  }

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  #open(): Promise<WelcomeFrame["data"]> {
    this.#ready = deferred();
    void this.#connect();
    return this.#ready.promise;
  }

  #currentFactory(): TransportFactory {
    const factories = this.#deps.transports;
    return factories[Math.min(this.#transportIndex, factories.length - 1)] as TransportFactory;
  }

  async #connect(): Promise<void> {
    if (this.#stopped) return;
    const token = ++this.#connectToken;
    if (this.#state !== "reconnecting") this.#setState(this.#welcomed ? "reconnecting" : "connecting", {});

    let transport: Transport;
    let accessToken: string;
    try {
      transport = this.#currentFactory()(this.#deps.env);
      if (transport.capabilities.requiresConversationId) await this.#ensureConversationToken(transport);
      accessToken = (await this.#tokens.get()).token;
    } catch (error) {
      if (token !== this.#connectToken || this.#stopped) return;
      const failure = error instanceof ConvergerError ? error : new ConvergerError("connect_failed", "could not connect", { cause: error });
      this.emit("error", failure);
      if (failure.code === "unauthorized" || failure.code === "forbidden" || failure.code === "not_found") {
        this.#close(failure, { code: 4401, reason: failure.message, opened: false });
        return;
      }
      this.#scheduleReconnect({ code: 1006, reason: failure.message, opened: false });
      return;
    }
    if (token !== this.#connectToken || this.#stopped) return;

    this.#transport = transport;
    const params: { baseUrl: string; token: string; conversationId?: string; userId?: string; watermark?: number } = {
      baseUrl: this.#deps.baseUrl,
      token: accessToken,
    };
    if (this.#conversationId) params.conversationId = this.#conversationId;
    if (this.#userId) params.userId = this.#userId;
    if (this.#conversationId) params.watermark = this.#watermark;

    transport.connect(params, {
      onOpen: () => undefined,
      onFrame: (frame) => {
        if (this.#transport === transport) this.#onFrame(frame);
      },
      onClose: (close) => {
        if (this.#transport === transport) this.#onClose(close);
      },
    });
  }

  /**
   * Transports without a handshake that can create or authorise a conversation
   * (Phoenix, SSE) need a conversation id, and the Phoenix binding a token
   * restricted to it. Both come from REST.
   */
  async #ensureConversationToken(transport: Transport): Promise<void> {
    const base = await this.#tokens.get();
    const claims = base.claims;
    if (!this.#conversationId) {
      const created = await this.#rest(base.token).createConversation();
      this.#conversationId = created.conversationId;
      await this.#deps.store.attach(created.conversationId);
      this.#useConversationTokens(created.token, created.expires_in);
      return;
    }
    if (transport.name === "phoenix" && claims?.conversation_id !== this.#conversationId && claims?.scope !== "channel") {
      const fetched = await this.#rest(base.token).getConversation(this.#conversationId);
      this.#useConversationTokens(fetched.token, fetched.expires_in);
    }
  }

  #useConversationTokens(token: string, expiresIn: number): void {
    const clientTokens = this.#deps.tokens;
    const conversationId = this.#conversationId as string;
    this.#tokens = new TokenManager(
      async () => {
        // A fresh conversation token from the client-level token.
        const base = await clientTokens.get();
        const response = await this.#rest(base.token).getConversation(conversationId);
        return { token: response.token, expiresIn: response.expires_in };
      },
      this.#deps.refreshSkewMs,
      { token, expiresIn },
    );
  }

  #rest(token?: string): RestClient {
    return this.#deps.restFor(async () => token ?? (await this.#tokens.get()).token);
  }

  #requireId(): string {
    if (!this.#conversationId) throw new ConvergerError("no_conversation", "the conversation has no id yet; await start()");
    return this.#conversationId;
  }

  #onClose(close: TransportClose): void {
    this.#transport = undefined;
    this.#inFlight.clear();
    this.#endReplay(false);
    if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
    if (this.#gapTimer) clearTimeout(this.#gapTimer);
    if (this.#syncTimer) clearTimeout(this.#syncTimer);
    if (this.#stopped) return;

    if (FATAL_CLOSE_CODES.has(close.code)) {
      const code =
        close.code === CloseCode.unsupportedProtocol
          ? "unsupported_protocol"
          : close.code === CloseCode.forbidden
            ? "channel_inactive"
            : "conversation_not_found";
      this.#close(new ConvergerClosedError(close.reason || code, code), close);
      return;
    }

    if (close.code === CloseCode.unauthorized) {
      this.#authRejections += 1;
      if (this.#authRejections > MAX_AUTH_REJECTIONS) {
        this.#close(new ConvergerClosedError("the server keeps rejecting fresh tokens", "unauthorized"), close);
        return;
      }
      // Reconnect with a fresh token (spec section 3.3: never with the same credential).
      void this.#tokens.fetch("rejected").catch((error: unknown) => {
        this.emit("error", error instanceof ConvergerError ? error : new ConvergerError("token_provider_failed", "token refresh failed", { cause: error }));
      });
    }
    this.#scheduleReconnect(close);
  }

  #scheduleReconnect(close: TransportClose): void {
    const policy = this.#deps.reconnect;
    if (!policy.enabled) {
      this.#close(new ConvergerClosedError("disconnected and reconnecting is disabled", "disconnected"), close);
      return;
    }
    this.#attempt += 1;
    if (this.#attempt > policy.maxAttempts) {
      this.#close(new ConvergerClosedError(`gave up after ${policy.maxAttempts} attempts`, "reconnect_failed"), close);
      return;
    }
    // Fall back to the next transport when this one never connects.
    if (!close.opened) {
      this.#failuresOnTransport += 1;
      if (
        this.#failuresOnTransport >= this.#deps.fallbackAfterAttempts &&
        this.#transportIndex < this.#deps.transports.length - 1
      ) {
        this.#transportIndex += 1;
        this.#failuresOnTransport = 0;
      }
    }
    const delayMs = backoffDelay(this.#attempt, policy, close.retryAfterMs);
    this.#setState("reconnecting", { delayMs, close });
    this.#reconnectTimer = setTimeout(() => void this.#connect(), delayMs);
  }

  #close(error: ConvergerError, close: TransportClose): void {
    this.#stopped = true;
    this.#fatal = error;
    this.#clearTimers();
    const transport = this.#transport;
    this.#transport = undefined;
    transport?.close(CloseCode.normal, "closing");
    this.#setState("closed", { close, error });
    this.#rejectWaiting(error);
    this.#ready?.reject(error);
    this.#deps.onDispose(this);
  }

  #setState(state: ConnectionState, extra: { delayMs?: number; close?: TransportClose; error?: ConvergerError }): void {
    const previous = this.#state;
    if (previous === state && state !== "reconnecting") return;
    this.#state = state;
    const change: ConnectionStateChange = { state, previous, attempt: this.#attempt, transport: this.transport };
    if (extra.delayMs !== undefined) change.delayMs = extra.delayMs;
    if (extra.close) change.close = extra.close;
    if (extra.error) change.error = extra.error;
    this.emit("connectionState", change);
  }

  #clearTimers(): void {
    for (const timer of [this.#reconnectTimer, this.#refreshTimer, this.#replayTimer, this.#gapTimer, this.#syncTimer, this.#retryTimer]) {
      if (timer) clearTimeout(timer);
    }
  }

  #rejectWaiting(error: unknown): void {
    for (const wait of this.#waiting.values()) wait.reject(error);
    this.#waiting.clear();
  }

  // -------------------------------------------------------------------------
  // Frames
  // -------------------------------------------------------------------------

  #onFrame(frame: ServerFrame): void {
    switch (frame.type) {
      case "welcome":
        this.#onWelcome(frame as WelcomeFrame);
        return;
      case "ack":
        this.#onAck(frame as AckFrame);
        return;
      case "error":
        this.#onError(frame as ErrorFrame);
        return;
      case "deliveryStatus":
        this.emit("deliveryStatus", frame as DeliveryStatusFrame);
        return;
      case "presence":
        this.emit("presence", frame as PresenceFrame);
        return;
      case "tokenRefreshed": {
        const expiresAt = (frame as { data?: { expiresAt?: unknown } }).data?.expiresAt;
        if (typeof expiresAt === "number") this.#tokens.setExpiry(expiresAt);
        this.#scheduleRefresh();
        return;
      }
      case "replayTruncated": {
        const data = (frame as ReplayTruncatedFrame).data;
        this.emit("replayTruncated", data);
        // Continue from where the replay stopped (spec section 6.2).
        this.#replaying = true;
        this.#replayTarget = data.headSeq;
        this.#armReplayTimer();
        this.#transport?.send({ type: "sync", watermark: Math.min(this.#watermark, data.watermark) });
        return;
      }
      case "heartbeat": {
        const head = (frame as { headSeq?: unknown }).headSeq;
        if (typeof head === "number" && head > this.#watermark) this.#checkGap(head);
        return;
      }
      default:
        if (isPersistent(frame)) this.#onPersistent(frame);
        else if (frame.type === "typing") this.emit("typing", frame as TypingFrame);
    }
  }

  #onWelcome(frame: WelcomeFrame): void {
    const data = frame.data;
    const asserted = this.#conversationId;
    if (asserted && data.conversationId && data.conversationId !== asserted) {
      // The server replaced the conversation (spec section 3.2): reset.
      this.#watermark = 0;
      this.#seen.clear();
    }
    this.#conversationId = data.conversationId || asserted;
    if (data.userId) this.#userId = data.userId;
    if (typeof data.limits?.maxInFlight === "number" && data.limits.maxInFlight > 0) {
      this.#maxInFlight = data.limits.maxInFlight;
    }
    this.#tokens.setExpiry(data.expiresAt);
    this.#lastWelcome = data;
    this.#welcomed = true;
    this.#attempt = 0;
    this.#failuresOnTransport = 0;
    this.#authRejections = 0;
    this.#saveState();
    this.#scheduleRefresh();

    const head = data.watermark;
    if (typeof head === "number" && head > this.#watermark) {
      // Resend unacked turns only after the replay: a turn the server stored
      // before the connection dropped shows up in it (with its clientId) and
      // needs no resend.
      this.#replaying = true;
      this.#replayTarget = head;
      this.#armReplayTimer();
    } else {
      this.#replaying = false;
    }

    const id = this.#conversationId;
    const attach = id ? this.#deps.store.attach(id) : Promise.resolve();
    this.#setState("open", {});
    this.emit("welcome", data);
    this.#ready?.resolve(data);
    void attach.then(() => {
      this.#saveState();
      this.#flush();
    });
  }

  #armReplayTimer(): void {
    if (this.#replayTimer) clearTimeout(this.#replayTimer);
    this.#replayTimer = setTimeout(() => this.#endReplay(true), this.#deps.replayWaitMs);
  }

  #endReplay(flush: boolean): void {
    if (this.#replayTimer) clearTimeout(this.#replayTimer);
    this.#replayTimer = undefined;
    if (!this.#replaying) return;
    this.#replaying = false;
    if (flush) this.#flush();
  }

  #onPersistent(frame: ActivityFrame): void {
    const seq = frame.seq;
    const duplicate = seq <= this.#watermark || this.#seen.has(seq);
    if (!duplicate) {
      this.#markSeen(seq);
      const own = this.#ownTurn(frame);
      if (!own && !this.#ownSeqs.has(seq) && !(typeof frame.id === "string" && this.#ownIds.has(frame.id))) {
        if (frame.type === "typing") this.emit("typing", frame as unknown as TypingFrame);
        else this.emit("activity", frame);
      }
    }
    if (this.#replaying && seq >= this.#replayTarget) this.#endReplay(true);
    if (seq > this.#watermark) this.#checkGap(seq);
  }

  /** A replayed own turn whose ack was lost: settle the send instead of resending it. */
  #ownTurn(frame: ActivityFrame): boolean {
    const clientId = (frame as { clientId?: unknown }).clientId;
    if (typeof clientId !== "string" || frame.from !== "user") return false;
    if (!this.#deps.store.get(clientId)) return false;
    this.#settle({ type: "ack", clientId, id: String(frame.id), seq: frame.seq, duplicate: true });
    return true;
  }

  #onAck(frame: AckFrame): void {
    if (typeof frame.seq === "number") this.#markSeen(frame.seq);
    this.#settle(frame);
    this.#flush();
  }

  #settle(frame: AckFrame): void {
    if (frame.seq > this.#watermark) this.#ownSeqs.add(frame.seq);
    this.#ownIds.add(frame.id);
    // Only recent ids matter (an echo arrives right after its ack); keep the set bounded.
    if (this.#ownIds.size > 1_000) this.#ownIds.delete(this.#ownIds.values().next().value as string);
    this.#inFlight.delete(frame.clientId);
    this.#retryAt.delete(frame.clientId);
    const entry = this.#deps.store.remove(frame.clientId);
    const wait = this.#waiting.get(frame.clientId);
    this.#waiting.delete(frame.clientId);
    if (!entry && !wait) return; // an ack for a send another session already settled
    const result: SendResult = {
      clientId: frame.clientId,
      id: frame.id,
      seq: frame.seq,
      duplicate: frame.duplicate === true,
    };
    if (frame.timestamp !== undefined) result.timestamp = frame.timestamp;
    wait?.resolve(result);
    this.emit("sent", result);
  }

  #markSeen(seq: number): void {
    if (seq <= this.#watermark) return;
    this.#seen.add(seq);
    let advanced = false;
    while (this.#seen.has(this.#watermark + 1)) {
      this.#seen.delete(this.#watermark + 1);
      this.#watermark += 1;
      // Frames at or below the watermark are dropped as duplicates anyway.
      this.#ownSeqs.delete(this.#watermark);
      advanced = true;
    }
    if (advanced) this.#saveState();
  }

  /**
   * Seqs above the watermark that never arrived (spec section 6.3): wait a
   * moment (an ack or a gap fill may be on its way), then `sync`.
   */
  #checkGap(highest: number): void {
    if (this.#gapTimer || this.#replaying || this.#inFlight.size > 0) return;
    if (!this.#transport?.capabilities.sync) return;
    if (highest <= this.#watermark) return;
    this.#gapTimer = setTimeout(() => {
      this.#gapTimer = undefined;
      const missing = highest > this.#watermark && this.#inFlight.size === 0;
      if (missing && this.#state === "open") this.#transport?.send({ type: "sync", watermark: this.#watermark });
    }, this.#deps.gapWaitMs);
  }

  #onError(frame: ErrorFrame): void {
    const error = new ConvergerProtocolError(frame);
    const clientId = frame.data.clientId;
    const entry = clientId ? this.#deps.store.get(clientId) : undefined;

    if (clientId && entry) {
      this.#inFlight.delete(clientId);
      if (RETRYABLE_SEND_ERRORS.has(error.code) || (error.retryable && error.code !== "token_expired")) {
        this.#retryAt.set(clientId, Date.now() + (error.retryAfterMs ?? 1_000));
        this.#scheduleRetry();
        return;
      }
      this.#deps.store.remove(clientId);
      this.#retryAt.delete(clientId);
      const wait = this.#waiting.get(clientId);
      this.#waiting.delete(clientId);
      wait?.reject(error);
      this.emit("sendFailed", { clientId, error });
      this.#flush();
      return;
    }

    switch (error.code) {
      case "replay_unavailable": {
        this.#endReplay(true);
        const from = typeof error.details?.["watermark"] === "number" ? (error.details["watermark"] as number) : this.#watermark;
        if (this.#syncTimer) clearTimeout(this.#syncTimer);
        this.#syncTimer = setTimeout(() => {
          this.#syncTimer = undefined;
          if (this.#state === "open") this.#transport?.send({ type: "sync", watermark: Math.min(from, this.#watermark) });
        }, error.retryAfterMs ?? 1_000);
        break;
      }
      case "invalid_watermark":
        if (error.frameType === undefined || error.frameType === "hello" || error.frameType === "sync") {
          // Our watermark is above the server's head (e.g. a restored database):
          // start over from 0 (spec section 6.5).
          this.#watermark = 0;
          this.#seen.clear();
          this.#saveState();
          this.#endReplay(true);
          this.#transport?.send({ type: "sync", watermark: 0 });
        }
        break;
      case "token_expired":
        void this.#tokens.fetch("refresh").catch(() => undefined);
        break;
      default:
        break;
    }
    this.emit("error", error);
  }

  // -------------------------------------------------------------------------
  // Outbox
  // -------------------------------------------------------------------------

  #flush(): void {
    const transport = this.#transport;
    if (this.#state !== "open" || !transport || this.#replaying) return;
    const now = Date.now();
    for (const entry of this.#deps.store.entries) {
      if (this.#inFlight.size >= this.#maxInFlight) break;
      if (this.#inFlight.has(entry.clientId)) continue;
      const retryAt = this.#retryAt.get(entry.clientId);
      if (retryAt !== undefined && retryAt > now) continue;
      this.#retryAt.delete(entry.clientId);
      if (!transport.send(entry.frame as ClientFrame)) break;
      this.#inFlight.add(entry.clientId);
      this.#deps.store.touch(entry.clientId);
    }
  }

  #scheduleRetry(): void {
    if (this.#retryTimer) clearTimeout(this.#retryTimer);
    const next = Math.min(...this.#retryAt.values());
    if (!Number.isFinite(next)) return;
    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = undefined;
      this.#flush();
      if (this.#retryAt.size > 0) this.#scheduleRetry();
    }, Math.max(0, next - Date.now()));
  }

  // -------------------------------------------------------------------------
  // Token refresh and state
  // -------------------------------------------------------------------------

  #scheduleRefresh(): void {
    if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
    const delay = this.#tokens.refreshDelay();
    if (delay === undefined) return;
    // setTimeout overflows above ~24.8 days.
    this.#refreshTimer = setTimeout(() => void this.#refresh(), Math.min(delay, 2 ** 31 - 1));
  }

  async #refresh(): Promise<void> {
    try {
      const fresh = await this.#tokens.fetch("refresh");
      const transport = this.#transport;
      if (transport?.capabilities.auth && this.#state === "open") {
        // The server answers `tokenRefreshed`, which reschedules.
        transport.send({ type: "auth", token: fresh.token });
      } else {
        // Used on the next connection.
        this.#scheduleRefresh();
      }
    } catch (error) {
      this.emit("error", error instanceof ConvergerError ? error : new ConvergerError("token_provider_failed", "token refresh failed", { cause: error }));
      // Try again shortly; at expiry the server closes with 4401 and the
      // reconnect asks the provider again.
      if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
      this.#refreshTimer = setTimeout(() => void this.#refresh(), 10_000);
    }
  }

  #saveState(): void {
    if (!this.#conversationId) return;
    const state: { conversationId: string; watermark: number; userId?: string } = {
      conversationId: this.#conversationId,
      watermark: this.#watermark,
    };
    if (this.#userId) state.userId = this.#userId;
    this.#deps.store.setState(state);
  }
}
