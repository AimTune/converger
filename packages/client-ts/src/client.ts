/**
 * `ConvergerClient`: the entry point.
 *
 * @module
 */

import { resolveReconnect, type ReconnectOptions } from "./backoff.js";
import { Conversation } from "./conversation.js";
import { TypedEmitter } from "./emitter.js";
import { ConvergerError } from "./errors.js";
import { RestClient, trimBaseUrl, type FetchLike } from "./rest/client.js";
import { ConversationStore } from "./storage/outbox.js";
import { defaultStorage, type KeyValueStorage } from "./storage/storage.js";
import { TokenManager, type TokenProvider } from "./token.js";
import { nativeTransport } from "./transport/native.js";
import { phoenixTransport } from "./transport/phoenix.js";
import { sseTransport } from "./transport/sse.js";
import type { TransportEnvironment, TransportFactory, WebSocketConstructor } from "./transport/types.js";

/** A built-in transport name, or a custom factory. */
export type TransportOption = "native" | "phoenix" | "sse" | TransportFactory;

/** Options of {@link ConvergerClient.connect}. */
export interface ConvergerClientOptions {
  /** Server base URL, e.g. `https://converger.example.com`. */
  baseUrl: string;
  /** Supplies tokens: at connect, before expiry and after a rejection. */
  tokenProvider: TokenProvider;
  /**
   * Transport, or transports in fallback order. Default `["native", "sse"]`:
   * the native WebSocket endpoint, falling back to Server-Sent Events when the
   * WebSocket cannot connect `fallbackAfterAttempts` times in a row.
   */
  transport?: TransportOption | TransportOption[];
  /** Consecutive failed attempts (never connected) before trying the next transport. Default 2. */
  fallbackAfterAttempts?: number;
  /** Reconnect policy, or `false` to never reconnect. */
  reconnect?: ReconnectOptions | false;
  /** Outbox and resume-state storage. Default: `localStorage` in browsers, memory elsewhere. */
  storage?: KeyValueStorage;
  /** Prefix of the storage keys. Default `converger`. */
  storageKey?: string;
  /** Refresh tokens this long before they expire (capped at half their lifetime). Default 60000. */
  refreshSkewMs?: number;
  /** WebSocket implementation (default: the global one; Node 22+ and browsers have it). */
  WebSocket?: WebSocketConstructor;
  /** fetch implementation (default: the global one). */
  fetch?: FetchLike;
  /** @internal How long to wait for the replay before resending anyway. Default 5000. */
  replayWaitMs?: number;
  /** @internal How long a seq gap may stay open before `sync`. Default 1500. */
  gapWaitMs?: number;
}

/** Options of {@link ConvergerClient.conversation}. */
export interface ConversationOptions {
  /** Override the client's transport choice for this conversation. */
  transport?: TransportOption | TransportOption[];
}

/** Events of a {@link ConvergerClient}. */
export interface ClientEvents {
  [key: string]: unknown;
  /** Storage failures and other problems outside a conversation. */
  error: ConvergerError;
}

function resolveTransport(option: TransportOption): TransportFactory {
  if (typeof option === "function") return option;
  switch (option) {
    case "native":
      return nativeTransport();
    case "phoenix":
      return phoenixTransport();
    case "sse":
      return sseTransport();
    default:
      throw new ConvergerError("invalid_option", `unknown transport ${String(option)}`);
  }
}

function resolveTransports(option: TransportOption | TransportOption[] | undefined): TransportFactory[] {
  const list = option === undefined ? ["native", "sse"] : Array.isArray(option) ? option : [option];
  if (list.length === 0) throw new ConvergerError("invalid_option", "at least one transport is needed");
  return list.map((t) => resolveTransport(t as TransportOption));
}

/**
 * A Converger client. One client serves any number of conversations, each with
 * its own connection.
 *
 * ```ts
 * const client = await ConvergerClient.connect({
 *   baseUrl: "https://converger.example.com",
 *   tokenProvider: async () => (await fetch("/my-backend/converger-token")).text(),
 * });
 * const conversation = client.conversation();
 * conversation.on("activity", (frame) => render(frame));
 * await conversation.start();
 * await conversation.send("Where is my order?");
 * ```
 */
export class ConvergerClient extends TypedEmitter<ClientEvents> {
  /** REST helpers authenticated with the client's token. */
  readonly rest: RestClient;
  readonly baseUrl: string;

  readonly #options: ConvergerClientOptions;
  readonly #tokens: TokenManager;
  readonly #storage: KeyValueStorage;
  readonly #conversations = new Set<Conversation>();
  readonly #env: TransportEnvironment;

  private constructor(options: ConvergerClientOptions, tokens: TokenManager) {
    super();
    this.#options = options;
    this.#tokens = tokens;
    this.baseUrl = trimBaseUrl(options.baseUrl);
    this.#storage = options.storage ?? defaultStorage();
    const g = globalThis as { WebSocket?: WebSocketConstructor; fetch?: FetchLike };
    this.#env = {
      WebSocket: options.WebSocket ?? g.WebSocket,
      fetch: options.fetch ?? (typeof g.fetch === "function" ? g.fetch.bind(globalThis) : undefined),
    };
    this.rest = this.#restFor(async () => (await this.#tokens.get()).token);
  }

  /**
   * Create a client and fetch the first token (so a misconfigured
   * `tokenProvider` fails here, not on the first send). No socket is opened
   * until a conversation is started or resumed.
   */
  static async connect(options: ConvergerClientOptions): Promise<ConvergerClient> {
    if (!options || typeof options.baseUrl !== "string" || !/^https?:\/\//i.test(options.baseUrl)) {
      throw new ConvergerError("invalid_option", "baseUrl must be an http(s) URL");
    }
    if (typeof options.tokenProvider !== "function") {
      throw new ConvergerError("invalid_option", "tokenProvider must be a function");
    }
    resolveTransports(options.transport); // validate early
    const tokens = new TokenManager(options.tokenProvider, options.refreshSkewMs ?? 60_000);
    await tokens.get();
    return new ConvergerClient(options, tokens);
  }

  /** The current token's decoded claims (unverified). */
  get claims(): Record<string, unknown> | null {
    return this.#tokens.current?.claims ?? null;
  }

  /**
   * A conversation session. Without an id, call `start()` to begin a new
   * conversation; with one, call `resume()`.
   */
  conversation(conversationId?: string, options: ConversationOptions = {}): Conversation {
    const storageKey = this.#options.storageKey ?? "converger";
    const store = new ConversationStore(this.#storage, storageKey, conversationId ?? null, (error) =>
      this.emit("error", new ConvergerError("storage_error", "the outbox storage failed", { cause: error })),
    );
    const conversation = new Conversation({
      conversationId: conversationId ?? null,
      tokens: this.#tokens,
      restFor: (getToken) => this.#restFor(getToken),
      baseUrl: this.baseUrl,
      transports: resolveTransports(options.transport ?? this.#options.transport),
      fallbackAfterAttempts: Math.max(1, this.#options.fallbackAfterAttempts ?? 2),
      reconnect: resolveReconnect(this.#options.reconnect),
      env: this.#env,
      store,
      refreshSkewMs: this.#options.refreshSkewMs ?? 60_000,
      replayWaitMs: this.#options.replayWaitMs ?? 5_000,
      gapWaitMs: this.#options.gapWaitMs ?? 1_500,
      onDispose: (c) => this.#conversations.delete(c),
    });
    this.#conversations.add(conversation);
    return conversation;
  }

  /** Disconnect every conversation (their outboxes are kept). */
  async close(): Promise<void> {
    await Promise.all([...this.#conversations].map((c) => c.disconnect()));
  }

  #restFor(getToken: () => Promise<string>): RestClient {
    const options: { baseUrl: string; getToken: () => Promise<string>; fetch?: FetchLike } = {
      baseUrl: this.baseUrl,
      getToken,
    };
    if (this.#env.fetch) options.fetch = this.#env.fetch;
    return new RestClient(options);
  }
}
