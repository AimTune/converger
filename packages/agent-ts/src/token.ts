/**
 * Channel-scoped tokens from the channel secret
 * (`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`).
 *
 * Run this on the agent's backend only: the channel secret must never reach a
 * browser.
 *
 * @module
 */

import { AgentError } from "./errors.js";
import { httpBase } from "./socket.js";

/** A `fetch` implementation (the global one by default). */
export type FetchLike = (input: string, init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
  text(): Promise<string>;
}>;

/** Why the agent asks for a token. */
export interface TokenRequest {
  /**
   * `connect`: a (re)connect; `refresh`: a mid-session refresh before the
   * token expires; `rejected`: the server closed the connection with 4401
   * (expired or revoked token), so a cached token must not be returned again.
   */
  reason: "connect" | "refresh" | "rejected";
}

/** Options of {@link generateChannelToken}. */
export interface ChannelTokenOptions {
  /** Converger base URL (`https://converger.example.com`; a `wss://` URL works too). */
  url: string;
  /** The channel secret of the agent's `websocket` channel. */
  secret: string;
  /** Optional identity of the agent: the `user_id` claim, used as the sender of its replies. */
  userId?: string;
  /** Optional permission restriction (`read`, `write`, `typing`). */
  permissions?: string[];
  fetch?: FetchLike;
}

/** A generated token. */
export interface ChannelToken {
  token: string;
  /** Lifetime in seconds. */
  expiresIn: number;
}

/** Issue a channel-scoped token from the channel secret. */
export async function generateChannelToken(options: ChannelTokenOptions): Promise<ChannelToken> {
  const doFetch = options.fetch ?? (globalThis.fetch as unknown as FetchLike | undefined);
  if (!doFetch) throw new AgentError("token_error", "no fetch implementation: pass the `fetch` option");
  const body: Record<string, unknown> = { scope: "channel" };
  if (options.userId) body["user"] = { id: options.userId };
  if (options.permissions) body["permissions"] = options.permissions;
  const response = await doFetch(`${httpBase(options.url)}/api/v1/converger/tokens/generate`, {
    method: "POST",
    headers: { authorization: `Bearer ${options.secret}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new AgentError(response.status === 429 ? "rate_limited" : "http_error", `tokens/generate failed with HTTP ${response.status}: ${text.slice(0, 300)}`, {
      retryable: response.status === 429 || response.status >= 500,
    });
  }
  const json = (await response.json()) as { token?: unknown; expires_in?: unknown };
  if (typeof json.token !== "string") throw new AgentError("http_error", "tokens/generate returned no token");
  return { token: json.token, expiresIn: typeof json.expires_in === "number" ? json.expires_in : 1800 };
}

/**
 * A `getToken` for {@link createAgent} that generates channel-scoped tokens
 * from the channel secret and caches each one until shortly before it expires
 * (`tokens/generate` is rate limited to 10 per minute per channel).
 */
export function channelTokenProvider(options: ChannelTokenOptions & { refreshBeforeMs?: number }): (context?: TokenRequest) => Promise<string> {
  let cached: { token: string; expiresAt: number } | undefined;
  let inflight: Promise<string> | undefined;
  const margin = options.refreshBeforeMs ?? 120_000;
  return (context) => {
    // The server refused the cached token (expired or revoked): never offer it again.
    if (context?.reason === "rejected") cached = undefined;
    if (cached && cached.expiresAt - margin > Date.now()) return Promise.resolve(cached.token);
    inflight ??= generateChannelToken(options)
      .then((result) => {
        cached = { token: result.token, expiresAt: Date.now() + result.expiresIn * 1000 };
        return result.token;
      })
      .finally(() => {
        inflight = undefined;
      });
    return inflight;
  };
}
