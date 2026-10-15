/**
 * Mekik client authentication — port + adapters.
 *
 * The client-side mirror of mekik's server-side auth (PROTOCOL.md §2.1): the
 * `Authenticator` port lives in `@mekik/core` and decides whether a connection
 * may open; reference adapters (`StaticTokenAuthenticator`, `HmacJwtAuthenticator`,
 * `CookieAuthenticator`) live in `@mekik/authentication`. This file is the other
 * half of that handshake — the port decides *what credential the client presents*,
 * and the adapters are the ready-made ways of presenting one.
 *
 * The split matters because the credential's shape is the app's business, not the
 * connector's: a cookie session, a static API key and a short-lived JWT all reach
 * the same server through the same wire fields, but they are obtained — and
 * refreshed — in completely different ways. Passing a provider keeps that
 * variation out of MekikConnector.
 *
 * No external dependencies allowed in this file.
 */

/** Auth rejection surfaced from the server's `error` frame (PROTOCOL.md §2.1). */
export interface MekikAuthError {
  code: string;
  message: string;
}

/** Everything the connector knows about a connection attempt. */
export interface MekikAuthContext {
  /** The endpoint being connected to (without any credential query params). */
  url: string;
  /** 0 on the first attempt; incremented once per auth retry. */
  attempt: number;
  /** The rejection that caused this retry — null on a first attempt. */
  previousError: MekikAuthError | null;
}

/**
 * What a provider contributes to the mekik/1 handshake.
 *
 * Both fields are optional: a cookie-session provider returns `{}` because the
 * browser attaches the credential to the handshake on its own.
 */
export interface MekikCredential {
  /** Sent as the `hello` frame's `token`. */
  token?: string;
  /** Merged into the socket URL's query string before the handshake opens. */
  query?: Record<string, string>;
}

/** What the connector should do after the server rejects a connection. */
export type MekikAuthDecision = "retry" | "fail";

/**
 * The client auth port: produce the credential for a (re)connect attempt.
 *
 * `authenticate()` is called before every socket is created — never once and
 * cached — so a provider is free to return a freshly minted credential per
 * attempt. Throwing from it fails `connect()` with that error rather than
 * degrading to an anonymous connection, which would surface a credential
 * outage as a misleading "unauthorized".
 */
export interface MekikAuthProvider {
  /** Identifies the adapter (diagnostics only). */
  readonly name: string;

  /** Resolve the credential for this attempt. */
  authenticate(ctx: MekikAuthContext): MekikCredential | Promise<MekikCredential>;

  /**
   * Decide what happens after the server rejects the connection. `"retry"` runs
   * `authenticate()` again (with `attempt` incremented and `previousError` set)
   * and reconnects; `"fail"` leaves the connection down. Omit to never retry.
   */
  onReject?(
    error: MekikAuthError,
    ctx: MekikAuthContext,
  ): MekikAuthDecision | Promise<MekikAuthDecision>;
}

/** Where a token rides on the handshake. */
export type MekikTokenTransport = "hello" | "query";

export interface TokenAuthOptions {
  /**
   * The credential. A string for a long-lived one; a function to mint a fresh
   * one per attempt (a short-lived JWT), which is what makes a reconnect after
   * a long sleep work — a token captured at page load has expired by then.
   */
  token: string | ((ctx: MekikAuthContext) => string | Promise<string>);
  /**
   * `"hello"` (default) sends the token in the handshake frame. `"query"` puts
   * it in the socket URL, which is the only thing an edge proxy or gateway
   * authenticating at the HTTP upgrade can see — but it also lands in server
   * and proxy access logs, so prefer `"hello"` unless something upstream of
   * mekik needs to read it.
   */
  transport?: MekikTokenTransport;
  /** Query param name for `transport: "query"`. */
  queryParam?: string;
  /** How many times a *function* token may be re-minted after a rejection. */
  maxRetries?: number;
}

/**
 * Token credential — pairs with mekik's `StaticTokenAuthenticator` (a string)
 * or `HmacJwtAuthenticator` (a function returning a short-lived JWT).
 */
export class TokenAuth implements MekikAuthProvider {
  readonly name = "token";

  private readonly token: TokenAuthOptions["token"];
  private readonly transport: MekikTokenTransport;
  private readonly queryParam: string;
  private readonly maxRetries: number;

  constructor(options: TokenAuthOptions) {
    this.token = options.token;
    this.transport = options.transport ?? "hello";
    this.queryParam = options.queryParam ?? "token";
    this.maxRetries = options.maxRetries ?? 1;
  }

  async authenticate(ctx: MekikAuthContext): Promise<MekikCredential> {
    const token = typeof this.token === "function" ? await this.token(ctx) : this.token;
    if (!token) return {};
    return this.transport === "query"
      ? { query: { [this.queryParam]: token } }
      : { token };
  }

  onReject(_error: MekikAuthError, ctx: MekikAuthContext): MekikAuthDecision {
    // A static string cannot become valid by being sent again — only a supplier
    // function can produce a different credential, so only it is worth retrying.
    if (typeof this.token !== "function") return "fail";
    return ctx.attempt < this.maxRetries ? "retry" : "fail";
  }
}

export interface CookieAuthOptions {
  /**
   * Renew the session after a rejection (e.g. POST a refresh endpoint). The
   * connector retries once it resolves. Omit to never retry.
   */
  refresh?: () => void | Promise<void>;
  /** How many times `refresh` may run for one connection. */
  maxRetries?: number;
}

/**
 * Cookie session — pairs with mekik's `CookieAuthenticator`.
 *
 * Contributes no credential on purpose: browsers attach cookies to the
 * WebSocket handshake themselves, and mekik forwards request headers to its
 * authenticator. That is the point of cookie auth — the credential stays
 * `HttpOnly` and never touches JavaScript. This adapter exists to declare that
 * intent in app code and to give an expiring session somewhere to refresh from.
 */
export class CookieAuth implements MekikAuthProvider {
  readonly name = "cookie";

  private readonly refresh: CookieAuthOptions["refresh"];
  private readonly maxRetries: number;

  constructor(options: CookieAuthOptions = {}) {
    this.refresh = options.refresh;
    this.maxRetries = options.maxRetries ?? 1;
  }

  authenticate(): MekikCredential {
    return {};
  }

  async onReject(_error: MekikAuthError, ctx: MekikAuthContext): Promise<MekikAuthDecision> {
    if (!this.refresh || ctx.attempt >= this.maxRetries) return "fail";
    try {
      await this.refresh();
      return "retry";
    } catch {
      return "fail"; // the session cannot be renewed — reconnecting is pointless
    }
  }
}
