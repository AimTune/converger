/**
 * The agent: one channel-scoped WebSocket that serves every conversation of
 * the channel (Protocol v1 section 10), with `onTurn(async (turn, reply) => ...)`.
 *
 * - Handlers of different conversations run concurrently; the turns of one
 *   conversation are serialised (a queue per conversation).
 * - `run` frames are sent around every handler (`started`, then `finished`,
 *   `error` or `aborted`), as a mekik bot does.
 * - Reconnects with jittered exponential backoff, honouring `retryAfterMs`
 *   and the close codes of section 12.3, and resumes with per-conversation
 *   watermarks in `hello.watermarks`.
 * - Message sends carry a `clientId`, are resolved by their `ack`, re-sent
 *   with the same `clientId` after a reconnect or an ack timeout (the server
 *   de-duplicates), and at most `maxInFlight` are unacknowledged at once.
 *   Outbound frames are paced below the server's per-connection rate limit.
 *
 * @module
 */

import { backoffDelay, resolveReconnect, type ReconnectOptions, type ResolvedReconnect } from "./backoff.js";
import { TypedEmitter } from "./emitter.js";
import { AgentError } from "./errors.js";
import {
  DEFAULT_PATH,
  PROTOCOL_VERSION,
  UNACKED_TYPES,
  isMessageFrame,
  type AckFrame,
  type Envelope,
  type ErrorFrame,
  type HelloFrame,
  type InboundFrame,
  type JsonObject,
  type MessageFrame,
  type ResumeFrame,
  type WelcomeFrame,
} from "./frames.js";
import { ReplyImpl, type Reply, type ReplyCore, type StreamMode } from "./reply.js";
import { AgentSocket, endpointUrl, type SocketClose, type WebSocketConstructor } from "./socket.js";
import type { TokenRequest } from "./token.js";
import { buildTurn, type HistoryOptions, type Turn } from "./turn.js";
import { WatermarkTracker } from "./watermarks.js";

/** A logger (`console` works). Every method is optional. */
export interface Logger {
  debug?(message: string, ...args: unknown[]): void;
  info?(message: string, ...args: unknown[]): void;
  warn?(message: string, ...args: unknown[]): void;
  error?(message: string, ...args: unknown[]): void;
}

/** Options of {@link createAgent}. */
export interface AgentOptions {
  /** Converger base URL (`https://converger.example.com`) or the endpoint URL (`wss://.../socket/converger/v1`). */
  url: string;
  /** A channel-scoped token (`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`). */
  token?: string;
  /**
   * Called for a token on every (re)connect and before the token expires; use
   * {@link channelTokenProvider} to generate them from the channel secret.
   * Preferred over `token`, which cannot be renewed.
   */
  getToken?: (request: TokenRequest) => Promise<string> | string;
  /** Agent group (`hello.group`): the members of a group share the channel's conversations, one member per conversation. */
  group?: string;
  /** `hello.userId`: the sender of the agent's replies when the token has no `user_id`. Default `agent`. */
  userId?: string;
  logger?: Logger;
  /** A WebSocket constructor (e.g. `WebSocket` from the `ws` package on Node 20). Default: the global one. */
  WebSocket?: WebSocketConstructor;
  /** Reconnect policy, or `false` to never reconnect. */
  reconnect?: ReconnectOptions | false;
  /** Endpoint path, used when `url` has none. Default `/socket/converger/v1`. */
  path?: string;
  /** Resume positions to start from (e.g. persisted from {@link Agent.watermarks}). */
  watermarks?: Record<string, number>;
  /** Conversations whose resume position is tracked and sent in `hello.watermarks`. Default 1000. */
  maxTrackedConversations?: number;
  /** Unacknowledged message sends at once. Default 32 (`limits.maxInFlight`). */
  maxInFlight?: number;
  /** Outbound frames per second (the server allows 20 per connection). Default 15. */
  maxFramesPerSecond?: number;
  /** Re-send an unacknowledged message (same `clientId`) after this long. Default 10000. */
  ackTimeoutMs?: number;
  /** Reject a send that is still not acknowledged after this long. Default 120000. */
  sendTimeoutMs?: number;
  /** Handlers running at once across conversations. Default 64. */
  maxConcurrentTurns?: number;
  /** Also dispatch message frames with `from: "bot"` (other agents, human agents) to `onTurn`. Default false. */
  includeBotTurns?: boolean;
  /** How `reply.stream()` is delivered. Default `genui`. */
  streamMode?: StreamMode;
  /** Coalesce stream deltas into one frame per this many ms. Default 150. */
  streamFlushMs?: number;
  /** Refresh a typing indicator this often while on. Default 4000; 0 disables. */
  typingRefreshMs?: number;
  /** Give up on a connection without `welcome` after this long. Default 15000. */
  connectTimeoutMs?: number;
  /** Extra time beyond `idleTimeoutMs` before a silent connection is dropped. Default 15000. */
  livenessGraceMs?: number;
  /** Send `run` frames around handlers. Default true. */
  runFrames?: boolean;
}

/** An `onTurn` handler. */
export type TurnHandler = (turn: Turn, reply: Reply) => Promise<void> | void;

/** A raw frame handler: every bare frame (no `conversationId`) and every enveloped frame. */
export type FrameHandler = (frame: InboundFrame, conversationId: string | undefined) => void;

/** Why the connection closed. */
export interface DisconnectInfo {
  code: number;
  reason: string;
  /** Whether the agent will reconnect. */
  willReconnect: boolean;
  /** Delay before the next attempt. */
  retryInMs?: number;
}

/** A `resume` frame received from an end user. */
export interface ResumeInfo {
  conversationId: string;
  answers: Record<string, unknown>;
  /** Interrupt ids that answered a pending `reply.ask`. */
  matched: string[];
}

/** Events of an {@link Agent}. */
export interface AgentEvents {
  [key: string]: unknown;
  /** A `welcome` arrived: the agent is serving the channel. */
  connected: WelcomeFrame;
  /** The connection closed. */
  disconnected: DisconnectInfo;
  /** A protocol error, a failed send that nobody awaits, or a handler that threw. */
  error: AgentError;
  /** An end user's `resume`. */
  resume: ResumeInfo;
}

interface Outgoing {
  conversationId: string;
  frame: JsonObject;
  clientId: string | undefined;
  resolve(ack: AckFrame | undefined): void;
  reject(error: AgentError): void;
  deadline: number;
  sentAt: number;
  attempts: number;
}

interface Lane {
  tail: Promise<void>;
  queued: number;
  controller: AbortController | undefined;
}

interface PendingAsk {
  resolve(value: unknown): void;
  reject(error: AgentError): void;
}

interface HistoryCollector {
  until: number;
  frames: InboundFrame[];
  done(): void;
  promise: Promise<InboundFrame[]>;
}

const TRANSIENT = new Set(["typing", "run", "read", "sync", "error", "genui_components", "skills"]);
const RESEND_CODES = new Set(["rate_limited", "too_many_in_flight", "unavailable", "internal"]);
const MAX_SEND_ATTEMPTS = 6;

function randomHex(bytes: number): string {
  const array = new Uint8Array(bytes);
  if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(array);
  else for (let i = 0; i < bytes; i += 1) array[i] = Math.floor(Math.random() * 256);
  return Array.from(array, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Create an agent. Call {@link Agent.onTurn}, then {@link Agent.start}. */
export function createAgent(options: AgentOptions): Agent {
  return new Agent(options);
}

/** A channel-scoped agent connection. Create it with {@link createAgent}. */
export class Agent extends TypedEmitter<AgentEvents> {
  readonly #options: AgentOptions;
  readonly #logger: Logger;
  readonly #reconnect: ResolvedReconnect;
  readonly #tracker: WatermarkTracker;
  readonly #frameHandlers = new Set<FrameHandler>();
  readonly #lanes = new Map<string, Lane>();
  readonly #asks = new Map<string, PendingAsk>();
  readonly #histories = new Map<string, HistoryCollector>();
  readonly #queue: Outgoing[] = [];
  readonly #inflight = new Map<string, Outgoing>();
  readonly #clientPrefix = `ag${randomHex(6)}`;
  readonly #core: ReplyCore;
  readonly #maxInFlight: number;
  readonly #fps: number;
  readonly #ackTimeoutMs: number;
  readonly #sendTimeoutMs: number;
  readonly #maxConcurrent: number;
  #handler: TurnHandler | undefined;
  #socket: AgentSocket | undefined;
  #welcome: WelcomeFrame | undefined;
  #running = false;
  #stopping = false;
  #everConnected = false;
  #attempt = 0;
  #clientCounter = 0;
  #reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  #refreshTimer: ReturnType<typeof setTimeout> | undefined;
  #tickTimer: ReturnType<typeof setInterval> | undefined;
  #pumpTimer: ReturnType<typeof setTimeout> | undefined;
  #tokens: number;
  #tokensAt = Date.now();
  #pausedUntil = 0;
  #active = 0;
  #waiters: (() => void)[] = [];
  #start: { promise: Promise<void>; resolve(): void; reject(error: unknown): void } | undefined;
  #rejected = false;

  constructor(options: AgentOptions) {
    super();
    if (!options.token && !options.getToken) throw new AgentError("token_error", "createAgent needs `token` or `getToken`", { retryable: false });
    this.#options = options;
    this.#logger = options.logger ?? {};
    this.#reconnect = resolveReconnect(options.reconnect);
    this.#tracker = new WatermarkTracker(options.maxTrackedConversations ?? 1000, options.watermarks);
    this.#maxInFlight = Math.max(1, options.maxInFlight ?? 32);
    this.#fps = Math.max(1, options.maxFramesPerSecond ?? 15);
    this.#tokens = this.#fps;
    this.#ackTimeoutMs = options.ackTimeoutMs ?? 10_000;
    this.#sendTimeoutMs = options.sendTimeoutMs ?? 120_000;
    this.#maxConcurrent = Math.max(1, options.maxConcurrentTurns ?? 64);
    this.#core = {
      send: (conversationId, frame) => this.#enqueue(conversationId, frame),
      nextClientId: () => this.#nextClientId(),
      randomId: (prefix) => `${prefix}-${randomHex(8)}`,
      waitForAnswer: (conversationId, interruptId, signal, timeoutMs) => this.#waitForAnswer(conversationId, interruptId, signal, timeoutMs),
      streamMode: options.streamMode ?? "genui",
      streamFlushMs: options.streamFlushMs ?? 150,
      typingRefreshMs: options.typingRefreshMs ?? 4_000,
    };
    this.setListenerErrorHandler((error) => this.#logger.error?.("[converger-agent] listener threw", error));
  }

  /** Register the turn handler (one per agent; a second call replaces it). */
  onTurn(handler: TurnHandler): this {
    this.#handler = handler;
    return this;
  }

  /** Observe every inbound frame (bare and enveloped), before the SDK handles it. Returns an unsubscribe function. */
  onFrame(handler: FrameHandler): () => void {
    this.#frameHandlers.add(handler);
    return () => this.#frameHandlers.delete(handler);
  }

  /** Whether a `welcome` was received on the current connection. */
  get connected(): boolean {
    return this.#welcome !== undefined && this.#socket?.welcomed === true;
  }

  /** The channel the token belongs to (from `welcome`). */
  get channelId(): string | undefined {
    return this.#welcome?.data.channelId;
  }

  /** The last `welcome`. */
  get welcome(): WelcomeFrame | undefined {
    return this.#welcome;
  }

  /** The resume position (highest seq seen) of every tracked conversation; persist it to resume after a restart. */
  watermarks(): Record<string, number> {
    return this.#tracker.snapshot();
  }

  /**
   * Connect. Resolves at the first `welcome`; rejects when the first
   * connection is refused for good (4400, 4401 without `getToken`, 4403) or
   * reconnecting is disabled and it fails.
   */
  start(): Promise<void> {
    if (this.#start) return this.#start.promise;
    let resolve!: () => void;
    let reject!: (error: unknown) => void;
    const promise = new Promise<void>((res, rej) => {
      resolve = res;
      reject = rej;
    });
    this.#start = { promise, resolve, reject };
    this.#running = true;
    this.#tickTimer = setInterval(() => this.#tick(), 1_000);
    void this.#connect("connect");
    return promise;
  }

  /**
   * Disconnect for good: running turns are aborted, pending asks and sends are
   * rejected with code `closed`. Resolves when the running handlers returned
   * (or after `timeoutMs`, default 5000).
   */
  async stop(options: { timeoutMs?: number } = {}): Promise<void> {
    if (!this.#running || this.#stopping) return;
    this.#stopping = true;
    const closed = new AgentError("closed", "the agent was stopped", { retryable: false });
    for (const lane of this.#lanes.values()) lane.controller?.abort(closed);
    for (const [key, ask] of this.#asks) {
      this.#asks.delete(key);
      ask.reject(closed);
    }
    for (const collector of this.#histories.values()) collector.done();
    // Let the handlers finish (their last sends still go out), then close.
    const tails = [...this.#lanes.values()].map((lane) => lane.tail);
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      Promise.all(tails),
      new Promise((resolve) => {
        timer = setTimeout(resolve, options.timeoutMs ?? 5_000);
      }),
    ]);
    if (timer) clearTimeout(timer);
    await this.#drain(options.timeoutMs ?? 5_000);
    this.#running = false;
    if (this.#reconnectTimer) clearTimeout(this.#reconnectTimer);
    if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
    if (this.#tickTimer) clearInterval(this.#tickTimer);
    if (this.#pumpTimer) clearTimeout(this.#pumpTimer);
    this.#pumpTimer = undefined;
    for (const entry of [...this.#queue.splice(0), ...this.#inflight.values()]) entry.reject(closed);
    this.#inflight.clear();
    this.#socket?.close(1000, "agent stopped");
    this.#socket = undefined;
    this.#welcome = undefined;
    this.#start?.reject(closed);
  }

  /** Wait (while connected) until the outbox is empty, at most `timeoutMs`. */
  async #drain(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while ((this.#queue.length > 0 || this.#inflight.size > 0) && this.connected && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }

  /**
   * A {@link Reply} for a conversation outside a turn (proactive messages).
   * It sends no `run` frames.
   */
  reply(conversationId: string): Reply {
    return new ReplyImpl(conversationId, this.#core, { run: false });
  }

  /**
   * Send a raw agent frame to a conversation. Message frames get a `clientId`
   * (unless they have one) and resolve with their ack; other frames resolve
   * when written.
   */
  send(conversationId: string, frame: JsonObject): Promise<AckFrame | undefined> {
    return this.#enqueue(conversationId, frame);
  }

  // -------------------------------------------------------------------------
  // Connection
  // -------------------------------------------------------------------------

  async #connect(reason: TokenRequest["reason"]): Promise<void> {
    if (!this.#running) return;
    this.#attempt += 1;
    let token: string;
    try {
      token = this.#options.getToken ? await this.#options.getToken({ reason }) : (this.#options.token as string);
    } catch (cause) {
      const error = cause instanceof AgentError ? cause : new AgentError("token_error", "getToken failed", { retryable: true, cause });
      this.#emitError(error);
      if (!error.retryable && !this.#everConnected) {
        // e.g. a wrong channel secret: retrying cannot help.
        this.#running = false;
        if (this.#tickTimer) clearInterval(this.#tickTimer);
        this.#start?.reject(error);
        return;
      }
      this.#scheduleReconnect({ code: 1006, reason: "token_error", opened: false }, error.retryAfterMs);
      return;
    }
    if (!this.#running) return;
    const WS = this.#options.WebSocket ?? (globalThis as { WebSocket?: WebSocketConstructor }).WebSocket;
    if (!WS) {
      const error = new AgentError("connect_failed", "no WebSocket implementation: use Node 22+, or pass `WebSocket` from the `ws` package", { retryable: false });
      this.#running = false;
      this.#start?.reject(error);
      return;
    }
    const hello: HelloFrame = { type: "hello", protocol: PROTOCOL_VERSION, token };
    if (this.#options.group) hello.group = this.#options.group;
    if (this.#options.userId) hello.userId = this.#options.userId;
    const watermarks = this.#tracker.snapshot();
    if (Object.keys(watermarks).length > 0) hello.watermarks = watermarks;

    const socket = new AgentSocket(
      {
        url: endpointUrl(this.#options.url, this.#options.path ?? DEFAULT_PATH),
        WebSocket: WS,
        hello,
        connectTimeoutMs: this.#options.connectTimeoutMs ?? 15_000,
        livenessGraceMs: this.#options.livenessGraceMs ?? 15_000,
      },
      {
        onOpen: () => this.#logger.debug?.("[converger-agent] socket open"),
        onMessage: (message) => {
          if (this.#socket === socket) this.#onMessage(message);
        },
        onClose: (close) => {
          if (this.#socket === socket) this.#onClose(close);
        },
      },
    );
    this.#socket = socket;
    socket.connect();
  }

  #onWelcome(welcome: WelcomeFrame): void {
    this.#welcome = welcome;
    this.#attempt = 0;
    this.#everConnected = true;
    this.#rejected = false;
    this.#logger.info?.(`[converger-agent] connected to channel ${welcome.data.channelId ?? "?"}`);
    // Unacknowledged sends go out again, first, with their original clientIds.
    const resend = [...this.#inflight.values()].sort((a, b) => a.sentAt - b.sentAt);
    this.#inflight.clear();
    this.#queue.unshift(...resend);
    this.#scheduleRefresh(welcome.data.expiresAt);
    this.emit("connected", welcome);
    this.#start?.resolve();
    this.#pump();
  }

  #onClose(close: SocketClose): void {
    this.#socket = undefined;
    this.#welcome = undefined;
    if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
    // Transient frames are pointless after a reconnect; drop them.
    for (let i = this.#queue.length - 1; i >= 0; i -= 1) {
      const entry = this.#queue[i] as Outgoing;
      if (TRANSIENT.has(String(entry.frame["type"]))) {
        this.#queue.splice(i, 1);
        entry.resolve(undefined);
      }
    }
    if (!this.#running) return;
    const { code } = close;
    const fatal =
      code === 4400 ||
      (code === 4401 && !this.#options.getToken) ||
      (code === 4401 && this.#rejected) ||
      ((code === 4403 || code === 1008) && !this.#everConnected);
    if (fatal || !this.#reconnect.enabled) {
      const error = new AgentError(code === 4401 ? "unauthorized" : code === 4400 ? "unsupported_protocol" : code === 4403 ? "forbidden" : "connect_failed", `connection closed (${code} ${close.reason})`, {
        retryable: false,
      });
      this.#running = false;
      if (this.#tickTimer) clearInterval(this.#tickTimer);
      this.emit("disconnected", { code, reason: close.reason, willReconnect: false });
      if (this.#everConnected) this.#emitError(error);
      this.#start?.reject(error);
      for (const entry of [...this.#queue.splice(0), ...this.#inflight.values()]) entry.reject(error);
      this.#inflight.clear();
      return;
    }
    if (code === 4401) this.#rejected = true;
    this.#scheduleReconnect(close, close.retryAfterMs);
  }

  #scheduleReconnect(close: SocketClose, retryAfterMs: number | undefined): void {
    if (!this.#running) return;
    if (this.#attempt >= this.#reconnect.maxAttempts) {
      const error = new AgentError("connect_failed", `gave up after ${this.#attempt} attempts`, { retryable: false });
      this.#running = false;
      this.emit("disconnected", { code: close.code, reason: close.reason, willReconnect: false });
      this.#start?.reject(error);
      return;
    }
    const delay = backoffDelay(Math.max(1, this.#attempt), this.#reconnect, retryAfterMs);
    this.emit("disconnected", { code: close.code, reason: close.reason, willReconnect: true, retryInMs: delay });
    this.#logger.warn?.(`[converger-agent] disconnected (${close.code} ${close.reason}), reconnecting in ${delay} ms`);
    const reason = close.code === 4401 ? "rejected" : "connect";
    this.#reconnectTimer = setTimeout(() => void this.#connect(reason), delay);
  }

  #scheduleRefresh(expiresAt: number | undefined): void {
    if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
    if (!this.#options.getToken || typeof expiresAt !== "number") return;
    // Refresh a minute before expiry (at least halfway through a short token).
    const remaining = expiresAt - Date.now();
    const delay = Math.max(1_000, Math.min(remaining - 60_000, remaining / 2));
    this.#refreshTimer = setTimeout(() => {
      const getToken = this.#options.getToken;
      if (!getToken || !this.connected) return;
      Promise.resolve(getToken({ reason: "refresh" })).then(
        (token) => this.#socket?.send({ type: "auth", token }),
        (cause: unknown) => this.#emitError(new AgentError("token_error", "getToken failed during refresh", { retryable: true, cause })),
      );
    }, delay);
  }

  // -------------------------------------------------------------------------
  // Inbound
  // -------------------------------------------------------------------------

  #onMessage(message: Record<string, unknown>): void {
    if (typeof message["type"] === "string") {
      this.#onBare(message as InboundFrame);
      return;
    }
    const conversationId = message["conversationId"];
    const frame = message["frame"];
    if (typeof conversationId !== "string" || typeof frame !== "object" || frame === null) return;
    if (typeof (frame as { type?: unknown }).type !== "string") return;
    this.#onEnveloped({ conversationId, frame: frame as InboundFrame });
  }

  #notify(frame: InboundFrame, conversationId: string | undefined): void {
    for (const handler of this.#frameHandlers) {
      try {
        handler(frame, conversationId);
      } catch (error) {
        this.#logger.error?.("[converger-agent] onFrame handler threw", error);
      }
    }
  }

  #onBare(frame: InboundFrame): void {
    this.#notify(frame, undefined);
    switch (frame.type) {
      case "welcome":
        this.#onWelcome(frame as unknown as WelcomeFrame);
        break;
      case "tokenRefreshed": {
        const expiresAt = (frame as { data?: { expiresAt?: unknown } }).data?.expiresAt;
        if (typeof expiresAt === "number") this.#scheduleRefresh(expiresAt);
        break;
      }
      case "error": {
        const error = AgentError.fromFrame(frame as unknown as ErrorFrame);
        if (error.code === "rate_limited") {
          // The frame that drew it was dropped and is not named: pause, and
          // let the ack timeout re-send unacknowledged messages.
          this.#pausedUntil = Date.now() + (error.retryAfterMs ?? 1_000);
        }
        if (error.clientId) this.#onSendError(error);
        else this.#emitError(error);
        break;
      }
      default:
        break;
    }
  }

  #onEnveloped(envelope: Envelope<InboundFrame>): void {
    const { conversationId, frame } = envelope;
    this.#notify(frame, conversationId);
    switch (frame.type) {
      case "ack": {
        const ack = frame as AckFrame;
        if (typeof ack.seq === "number") this.#tracker.record(conversationId, ack.seq);
        const entry = this.#inflight.get(`${conversationId}\u0000${ack.clientId}`);
        if (entry) {
          this.#inflight.delete(`${conversationId}\u0000${ack.clientId}`);
          entry.resolve(ack);
          this.#pump();
        }
        return;
      }
      case "error": {
        const error = AgentError.fromFrame(frame as ErrorFrame, conversationId);
        if (error.code === "replay_unavailable") {
          const watermark = (error.details?.["watermark"] as number | undefined) ?? this.#tracker.get(conversationId);
          setTimeout(() => void this.#enqueue(conversationId, { type: "sync", watermark }).catch(() => undefined), error.retryAfterMs ?? 1_000);
        }
        if (error.clientId && this.#inflight.has(`${conversationId}\u0000${error.clientId}`)) this.#onSendError(error);
        else this.#emitError(error);
        return;
      }
      case "replayTruncated": {
        const watermark = (frame as { data?: { watermark?: unknown } }).data?.watermark;
        const history = this.#histories.get(conversationId);
        if (history) history.done();
        else if (typeof watermark === "number") void this.#enqueue(conversationId, { type: "sync", watermark }).catch(() => undefined);
        return;
      }
      case "resume":
        this.#onResume(conversationId, frame as ResumeFrame);
        return;
      case "abort": {
        const lane = this.#lanes.get(conversationId);
        lane?.controller?.abort(new AgentError("aborted", "the end user aborted the run", { retryable: false, conversationId }));
        return;
      }
      default:
        break;
    }

    const seq = (frame as { seq?: unknown }).seq;
    if (typeof seq === "number") {
      const history = this.#histories.get(conversationId);
      if (history && seq <= history.until) {
        history.frames.push(frame);
        this.#tracker.record(conversationId, seq);
        if (seq >= history.until) history.done();
        return;
      }
      // Already seen (a replay overlapping what was delivered live): not a new turn.
      if (!this.#tracker.record(conversationId, seq)) return;
    }

    if (!isMessageFrame(frame)) return;
    const from = (frame as MessageFrame).from;
    if (from === "user" || (from === "bot" && this.#options.includeBotTurns)) {
      this.#dispatch({ conversationId, frame: frame as MessageFrame });
    }
  }

  #onResume(conversationId: string, frame: ResumeFrame): void {
    const answers = typeof frame.answers === "object" && frame.answers !== null ? frame.answers : {};
    const matched: string[] = [];
    for (const [id, value] of Object.entries(answers)) {
      const key = `${conversationId}\u0000${id}`;
      const ask = this.#asks.get(key);
      if (ask) {
        this.#asks.delete(key);
        matched.push(id);
        ask.resolve(value);
      }
    }
    if (matched.length === 0) this.#logger.debug?.(`[converger-agent] resume for no pending ask in ${conversationId}`);
    this.emit("resume", { conversationId, answers, matched });
  }

  // -------------------------------------------------------------------------
  // Turns
  // -------------------------------------------------------------------------

  #dispatch(envelope: Envelope<MessageFrame>): void {
    const { conversationId } = envelope;
    let lane = this.#lanes.get(conversationId);
    if (!lane) {
      lane = { tail: Promise.resolve(), queued: 0, controller: undefined };
      this.#lanes.set(conversationId, lane);
    }
    const current = lane;
    current.queued += 1;
    current.tail = current.tail
      .then(() => this.#runTurn(current, envelope))
      .catch((error: unknown) => this.#logger.error?.("[converger-agent] turn failed", error))
      .finally(() => {
        current.queued -= 1;
        if (current.queued === 0 && this.#lanes.get(conversationId) === current) this.#lanes.delete(conversationId);
      });
  }

  async #runTurn(lane: Lane, envelope: Envelope<MessageFrame>): Promise<void> {
    const handler = this.#handler;
    if (!handler || !this.#running || this.#stopping) return;
    await this.#acquire();
    const controller = new AbortController();
    lane.controller = controller;
    const { conversationId } = envelope;
    const reply = new ReplyImpl(conversationId, this.#core, { run: this.#options.runFrames !== false, signal: controller.signal });
    const turn = buildTurn(envelope, controller.signal, (options) => this.#history(conversationId, options));
    try {
      await handler(turn, reply);
      if (controller.signal.aborted) reply.setStatus("aborted");
    } catch (cause) {
      if (controller.signal.aborted) {
        reply.setStatus("aborted");
      } else {
        reply.setStatus("error");
        this.#emitError(
          cause instanceof AgentError && cause.code !== "handler_error"
            ? cause
            : new AgentError("handler_error", `onTurn handler failed: ${cause instanceof Error ? cause.message : String(cause)}`, {
                retryable: false,
                conversationId,
                cause,
              }),
        );
      }
    } finally {
      lane.controller = undefined;
      // Reject asks the handler left behind.
      for (const [key, ask] of this.#asks) {
        if (key.startsWith(`${conversationId}\u0000`)) {
          this.#asks.delete(key);
          ask.reject(new AgentError("aborted", "the turn ended", { retryable: false, conversationId }));
        }
      }
      await reply.end().catch(() => undefined);
      this.#release();
    }
  }

  #acquire(): Promise<void> {
    if (this.#active < this.#maxConcurrent) {
      this.#active += 1;
      return Promise.resolve();
    }
    return new Promise((resolve) => this.#waiters.push(() => resolve()));
  }

  #release(): void {
    const next = this.#waiters.shift();
    if (next) next();
    else this.#active -= 1;
  }

  #history(conversationId: string, options: HistoryOptions = {}): Promise<InboundFrame[]> {
    const existing = this.#histories.get(conversationId);
    const limit = options.limit;
    const slice = (frames: InboundFrame[]) => (limit !== undefined && limit >= 0 ? frames.slice(-limit) : frames);
    if (existing) return existing.promise.then(slice);
    const until = this.#tracker.get(conversationId);
    if (until === 0) return Promise.resolve([]);
    let finish!: () => void;
    const collector: HistoryCollector = {
      until,
      frames: [],
      done: () => finish(),
      promise: undefined as unknown as Promise<InboundFrame[]>,
    };
    collector.promise = new Promise<InboundFrame[]>((resolve) => {
      let settled = false;
      const timer = setTimeout(() => finish(), options.timeoutMs ?? 5_000);
      finish = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (this.#histories.get(conversationId) === collector) this.#histories.delete(conversationId);
        resolve([...collector.frames].sort((a, b) => ((a as { seq?: number }).seq ?? 0) - ((b as { seq?: number }).seq ?? 0)));
      };
    });
    this.#histories.set(conversationId, collector);
    this.#enqueue(conversationId, { type: "sync", watermark: Math.max(0, options.since ?? 0) }).catch(() => collector.done());
    return collector.promise.then(slice);
  }

  // -------------------------------------------------------------------------
  // Outbound
  // -------------------------------------------------------------------------

  #nextClientId(): string {
    this.#clientCounter += 1;
    return `${this.#clientPrefix}-${this.#clientCounter}`;
  }

  #waitForAnswer(conversationId: string, interruptId: string, signal: AbortSignal | undefined, timeoutMs: number | undefined): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const key = `${conversationId}\u0000${interruptId}`;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const cleanup = () => {
        if (timer) clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
      };
      const onAbort = () => {
        if (this.#asks.get(key) !== entry) return;
        this.#asks.delete(key);
        cleanup();
        const reason: unknown = signal?.reason;
        reject(reason instanceof AgentError ? reason : new AgentError("aborted", "ask was aborted", { retryable: false, conversationId }));
      };
      const entry: PendingAsk = {
        resolve: (value) => {
          cleanup();
          resolve(value);
        },
        reject: (error) => {
          cleanup();
          reject(error);
        },
      };
      if (signal?.aborted) {
        onAbort();
        reject(signal.reason instanceof AgentError ? signal.reason : new AgentError("aborted", "ask was aborted", { retryable: false, conversationId }));
        return;
      }
      this.#asks.set(key, entry);
      signal?.addEventListener("abort", onAbort, { once: true });
      if (timeoutMs !== undefined) {
        timer = setTimeout(() => {
          if (this.#asks.get(key) !== entry) return;
          this.#asks.delete(key);
          cleanup();
          reject(new AgentError("timeout", `no answer to ${interruptId} within ${timeoutMs} ms`, { retryable: false, conversationId }));
        }, timeoutMs);
      }
    });
  }

  #enqueue(conversationId: string, frame: JsonObject): Promise<AckFrame | undefined> {
    if (!this.#running && !this.#start) {
      return Promise.reject(new AgentError("closed", "the agent is not started", { retryable: false, conversationId }));
    }
    if (!this.#running) return Promise.reject(new AgentError("closed", "the agent was stopped", { retryable: false, conversationId }));
    const type = String(frame["type"]);
    // Transient frames are not worth queueing while disconnected.
    if (TRANSIENT.has(type) && type !== "sync" && !this.connected) return Promise.resolve(undefined);
    const acked = !UNACKED_TYPES.has(type);
    let clientId: string | undefined;
    if (acked) {
      clientId = typeof frame["clientId"] === "string" ? frame["clientId"] : typeof frame["id"] === "string" ? frame["id"] : this.#nextClientId();
      if (frame["clientId"] === undefined && frame["id"] === undefined) frame = { ...frame, clientId };
    }
    return new Promise((resolve, reject) => {
      this.#queue.push({ conversationId, frame, clientId, resolve, reject, deadline: Date.now() + this.#sendTimeoutMs, sentAt: 0, attempts: 0 });
      this.#tracker.touch(conversationId);
      this.#pump();
    });
  }

  #pump(): void {
    if (this.#pumpTimer) return;
    const socket = this.#socket;
    if (!socket || !this.connected) return;
    const now = Date.now();
    if (now < this.#pausedUntil) {
      this.#pumpTimer = setTimeout(() => {
        this.#pumpTimer = undefined;
        this.#pump();
      }, this.#pausedUntil - now);
      return;
    }
    // Token bucket: `fps` frames per second, bursts up to `fps`.
    this.#tokens = Math.min(this.#fps, this.#tokens + ((now - this.#tokensAt) / 1000) * this.#fps);
    this.#tokensAt = now;
    while (this.#queue.length > 0) {
      const head = this.#queue[0] as Outgoing;
      if (head.clientId && this.#inflight.size >= this.#maxInFlight) return; // resumed by an ack
      if (this.#tokens < 1) {
        const wait = Math.ceil(((1 - this.#tokens) / this.#fps) * 1000);
        this.#pumpTimer = setTimeout(() => {
          this.#pumpTimer = undefined;
          this.#pump();
        }, wait);
        return;
      }
      this.#queue.shift();
      const written = socket.send({ conversationId: head.conversationId, frame: head.frame });
      if (!written) {
        this.#queue.unshift(head);
        return;
      }
      this.#tokens -= 1;
      head.attempts += 1;
      head.sentAt = Date.now();
      if (head.clientId) this.#inflight.set(`${head.conversationId}\u0000${head.clientId}`, head);
      else head.resolve(undefined);
    }
  }

  #onSendError(error: AgentError): void {
    const key = `${error.conversationId ?? ""}\u0000${error.clientId ?? ""}`;
    const entry = this.#inflight.get(key);
    if (!entry) {
      this.#emitError(error);
      return;
    }
    this.#inflight.delete(key);
    if (error.retryable && RESEND_CODES.has(error.code) && entry.attempts < MAX_SEND_ATTEMPTS) {
      // Section 7: retryable errors may be retried with the same clientId.
      const delay = error.retryAfterMs ?? backoffDelay(entry.attempts, this.#reconnect);
      setTimeout(() => {
        if (!this.#running) return;
        this.#queue.unshift(entry);
        this.#pump();
      }, delay);
    } else {
      entry.reject(error);
    }
    this.#pump();
  }

  #tick(): void {
    const now = Date.now();
    for (let i = this.#queue.length - 1; i >= 0; i -= 1) {
      const entry = this.#queue[i] as Outgoing;
      if (entry.deadline < now) {
        this.#queue.splice(i, 1);
        entry.reject(new AgentError("timeout", "the send was not delivered in time", { retryable: true, conversationId: entry.conversationId, clientId: entry.clientId }));
      }
    }
    for (const [key, entry] of this.#inflight) {
      if (entry.deadline < now) {
        this.#inflight.delete(key);
        entry.reject(new AgentError("timeout", "no ack in time", { retryable: true, conversationId: entry.conversationId, clientId: entry.clientId }));
      } else if (this.connected && now - entry.sentAt > this.#ackTimeoutMs) {
        // Lost (e.g. dropped by the rate limit): send again, same clientId.
        this.#inflight.delete(key);
        this.#queue.unshift(entry);
      }
    }
    this.#pump();
  }

  #emitError(error: AgentError): void {
    this.#logger.warn?.(`[converger-agent] ${error.code}: ${error.message}`);
    this.emit("error", error);
  }
}
