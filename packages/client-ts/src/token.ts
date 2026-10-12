/**
 * Token handling: a user-supplied `tokenProvider`, JWT expiry, and refresh
 * ahead of expiry.
 *
 * @module
 */

import { ConvergerError } from "./errors.js";
import { refreshToken, type FetchLike } from "./rest/client.js";

/** A token plus, optionally, when it expires. */
export interface TokenInfo {
  token: string;
  /** Expiry in ms since the epoch. */
  expiresAt?: number;
  /** Lifetime in seconds from now (as `expires_in` of the token endpoints). */
  expiresIn?: number;
}

/** Why the provider is asked for a token. */
export type TokenRequestReason = "initial" | "refresh" | "rejected";

/**
 * Returns a Converger token (`type: "converger"`), typically by calling your
 * backend, which calls `POST /api/v1/converger/tokens/generate` with the channel
 * secret. Called once at connect, again before the token expires, and after the
 * server rejected it (close 4401).
 */
export type TokenProvider = (context: {
  reason: TokenRequestReason;
  /** The token being replaced, if any. */
  previous?: string;
}) => Promise<string | TokenInfo> | string | TokenInfo;

/** Claims of a Converger token the client reads (it never verifies the signature). */
export interface TokenClaims {
  exp?: number;
  tenant_id?: string;
  channel_id?: string;
  conversation_id?: string;
  user_id?: string;
  scope?: string;
  [key: string]: unknown;
}

/** Decode a JWT's payload without verifying it. Returns `null` when it is not a JWT. */
export function decodeToken(token: string): TokenClaims | null {
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const padded = part.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
    const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    const json = JSON.parse(new TextDecoder().decode(bytes)) as unknown;
    return typeof json === "object" && json !== null ? (json as TokenClaims) : null;
  } catch {
    return null;
  }
}

/** @internal */
export interface ActiveToken {
  token: string;
  /** ms since the epoch, when known. */
  expiresAt: number | undefined;
  claims: TokenClaims | null;
  /** ms since the epoch when the client got it. */
  receivedAt: number;
}

function normalise(value: string | TokenInfo, now: number): ActiveToken {
  const info = typeof value === "string" ? { token: value } : value;
  if (!info || typeof info.token !== "string" || info.token === "") {
    throw new ConvergerError("invalid_token", "the tokenProvider returned no token");
  }
  const claims = decodeToken(info.token);
  let expiresAt = info.expiresAt;
  if (expiresAt === undefined && typeof info.expiresIn === "number") expiresAt = now + info.expiresIn * 1000;
  if (expiresAt === undefined && typeof claims?.exp === "number") expiresAt = claims.exp * 1000;
  return { token: info.token, expiresAt, claims, receivedAt: now };
}

/**
 * Caches the current token, de-duplicates concurrent refreshes and tells
 * when the next refresh is due.
 *
 * @internal
 */
export class TokenManager {
  readonly #provider: TokenProvider;
  readonly #skewMs: number;
  #current: ActiveToken | undefined;
  #pending: Promise<ActiveToken> | undefined;

  constructor(provider: TokenProvider, refreshSkewMs: number, initial?: string | TokenInfo) {
    this.#provider = provider;
    this.#skewMs = refreshSkewMs;
    if (initial !== undefined) this.#current = normalise(initial, Date.now());
  }

  get current(): ActiveToken | undefined {
    return this.#current;
  }

  /** The current token, fetching one when there is none or it is (nearly) expired. */
  async get(): Promise<ActiveToken> {
    const current = this.#current;
    if (current && !this.#needsRefresh(current, Date.now())) return current;
    return this.fetch(current ? "refresh" : "initial");
  }

  /** Ask the provider for a new token (one request at a time). */
  fetch(reason: TokenRequestReason): Promise<ActiveToken> {
    if (this.#pending) return this.#pending;
    const previous = this.#current?.token;
    const context: { reason: TokenRequestReason; previous?: string } = { reason };
    if (previous !== undefined) context.previous = previous;
    const pending = (async () => {
      try {
        const value = await this.#provider(context);
        const token = normalise(value, Date.now());
        this.#current = token;
        return token;
      } catch (error) {
        if (error instanceof ConvergerError) throw error;
        throw new ConvergerError("token_provider_failed", "the tokenProvider failed", { cause: error });
      } finally {
        this.#pending = undefined;
      }
    })();
    this.#pending = pending;
    return pending;
  }

  /** The server told us the real expiry (`welcome.expiresAt`, `tokenRefreshed`). */
  setExpiry(expiresAt: number | undefined): void {
    if (this.#current && typeof expiresAt === "number") this.#current = { ...this.#current, expiresAt };
  }

  /** ms from now until the refresh is due, or `undefined` when the expiry is unknown. */
  refreshDelay(now = Date.now()): number | undefined {
    const expiresAt = this.#current?.expiresAt;
    if (expiresAt === undefined) return undefined;
    return Math.max(0, expiresAt - this.#skewFor(this.#current) - now);
  }

  #skewFor(token: ActiveToken | undefined): number {
    // Never more than half the lifetime, so short-lived tokens are not refreshed constantly.
    if (!token?.expiresAt) return this.#skewMs;
    const lifetime = token.expiresAt - token.receivedAt;
    return lifetime > 0 ? Math.min(this.#skewMs, lifetime / 2) : this.#skewMs;
  }

  #needsRefresh(token: ActiveToken, now: number): boolean {
    return token.expiresAt !== undefined && token.expiresAt - now <= Math.min(this.#skewMs, 5_000);
  }
}

/**
 * A provider that starts from a token you already have and renews it with
 * `POST /api/v1/converger/tokens/refresh`. Refresh only works while the current
 * token is still valid; after a long offline period you need a provider that
 * can mint a new token (your backend).
 */
export function createRefreshingTokenProvider(options: {
  baseUrl: string;
  token: string | TokenInfo;
  fetch?: FetchLike;
}): TokenProvider {
  let latest: string | TokenInfo = options.token;
  return async ({ reason }) => {
    if (reason === "initial") return latest;
    const token = typeof latest === "string" ? latest : latest.token;
    const refreshOptions: { baseUrl: string; token: string; fetch?: FetchLike } = { baseUrl: options.baseUrl, token };
    if (options.fetch) refreshOptions.fetch = options.fetch;
    const response = await refreshToken(refreshOptions);
    latest = { token: response.token, expiresIn: response.expires_in };
    return latest;
  };
}
