/**
 * REST helpers for the Converger client API (`/api/v1/converger`, see
 * docs/api/client-api.md): tokens, conversations, history paging and uploads.
 *
 * @module
 */

import { apiErrorFrom, ConvergerError } from "../errors.js";
import type {
  ActivitySet,
  ConversationResponse,
  ConversationStatusResponse,
  PostActivityRequest,
  ResourceResponse,
  RestActivity,
  TokenResponse,
  UploadResponse,
} from "./types.js";

/** A `fetch` implementation (the global one by default). */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** Options of {@link RestClient}. */
export interface RestClientOptions {
  /** `https://converger.example.com` (no trailing path). */
  baseUrl: string;
  /** Returns the bearer token for a request. */
  getToken: () => Promise<string> | string;
  fetch?: FetchLike;
}

/** Options of {@link RestClient.history}. */
export interface HistoryOptions {
  /** Start after this watermark (the integer seq, or a legacy opaque string, passed as is); absent starts at the beginning. */
  watermark?: number | string;
  /** Page size (the server clamps it). */
  limit?: number;
  signal?: AbortSignal;
}

/** Options of {@link RestClient.upload}. */
export interface UploadOptions {
  /** File name sent in the multipart part (defaults to the `File` name or `upload`). */
  filename?: string;
  /** Text and metadata of the activity that carries the attachment. */
  activity?: { text?: string; channelData?: Record<string, unknown>; from?: { id: string }; replyToId?: string };
  signal?: AbortSignal;
}

/** @internal */
export function trimBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "");
}

function globalFetch(): FetchLike {
  if (typeof globalThis.fetch !== "function") {
    throw new ConvergerError(
      "no_fetch",
      "no global fetch: pass the `fetch` option (Node 18+ and every modern browser have one)",
    );
  }
  return globalThis.fetch.bind(globalThis) as FetchLike;
}

async function readBody(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text === "") return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

async function request<T>(
  fetchImpl: FetchLike,
  url: string,
  init: RequestInit,
): Promise<T> {
  let response: Response;
  try {
    response = await fetchImpl(url, init);
  } catch (error) {
    throw new ConvergerError("network_error", `request to ${url} failed`, { cause: error });
  }
  const body = await readBody(response);
  if (!response.ok) {
    throw apiErrorFrom(response.status, body, response.headers.get("retry-after"));
  }
  return body as T;
}

/**
 * Exchange a channel secret for a token: `POST /api/v1/converger/tokens/generate`.
 *
 * **Server-side only.** A channel secret must never reach a browser or app;
 * call this from your backend and hand the token to the client through your
 * `tokenProvider`.
 */
export async function generateToken(options: {
  baseUrl: string;
  secret: string;
  userId?: string;
  scope?: "channel";
  fetch?: FetchLike;
}): Promise<TokenResponse> {
  const body: Record<string, unknown> = {};
  if (options.userId !== undefined) body["user"] = { id: options.userId };
  if (options.scope !== undefined) body["scope"] = options.scope;
  return request<TokenResponse>(
    options.fetch ?? globalFetch(),
    `${trimBaseUrl(options.baseUrl)}/api/v1/converger/tokens/generate`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${options.secret}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify(body),
    },
  );
}

/**
 * Renew a token before it expires: `POST /api/v1/converger/tokens/refresh`.
 * The new token keeps the conversation, user and scope claims.
 */
export async function refreshToken(options: {
  baseUrl: string;
  token: string;
  fetch?: FetchLike;
}): Promise<TokenResponse> {
  return request<TokenResponse>(
    options.fetch ?? globalFetch(),
    `${trimBaseUrl(options.baseUrl)}/api/v1/converger/tokens/refresh`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${options.token}`, accept: "application/json" },
    },
  );
}

/** Typed wrapper over the client REST API, authenticated with the session's token. */
export class RestClient {
  readonly baseUrl: string;
  readonly #getToken: () => Promise<string> | string;
  readonly #fetch: FetchLike;

  constructor(options: RestClientOptions) {
    this.baseUrl = trimBaseUrl(options.baseUrl);
    this.#getToken = options.getToken;
    this.#fetch = options.fetch ?? globalFetch();
  }

  async #call<T>(
    method: string,
    path: string,
    init: { body?: BodyInit; json?: unknown; headers?: Record<string, string>; signal?: AbortSignal; token?: string } = {},
  ): Promise<T> {
    const token = init.token ?? (await this.#getToken());
    const headers: Record<string, string> = {
      authorization: `Bearer ${token}`,
      accept: "application/json",
      ...init.headers,
    };
    let body = init.body;
    if (init.json !== undefined) {
      headers["content-type"] = "application/json";
      body = JSON.stringify(init.json);
    }
    const requestInit: RequestInit = { method, headers };
    if (body !== undefined) requestInit.body = body;
    if (init.signal) requestInit.signal = init.signal;
    return request<T>(this.#fetch, `${this.baseUrl}/api/v1/converger${path}`, requestInit);
  }

  /** `POST /tokens/refresh` with the current (or the given) token. */
  refreshToken(token?: string): Promise<TokenResponse> {
    return this.#call("POST", "/tokens/refresh", token === undefined ? {} : { token });
  }

  /** `POST /conversations`: a new conversation and a token restricted to it. */
  createConversation(): Promise<ConversationResponse> {
    return this.#call("POST", "/conversations");
  }

  /** `GET /conversations/:id`: a fresh conversation token. */
  getConversation(conversationId: string): Promise<ConversationResponse> {
    return this.#call("GET", `/conversations/${encodeURIComponent(conversationId)}`);
  }

  /** `POST /conversations/:id/close`. */
  closeConversation(conversationId: string): Promise<ConversationStatusResponse> {
    return this.#call("POST", `/conversations/${encodeURIComponent(conversationId)}/close`);
  }

  /** `POST /conversations/:id/reopen`. */
  reopenConversation(conversationId: string): Promise<ConversationStatusResponse> {
    return this.#call("POST", `/conversations/${encodeURIComponent(conversationId)}/reopen`);
  }

  /**
   * `POST /conversations/:id/activities`. With `idempotencyKey` (sent as
   * `X-Idempotency-Key`) a retry is stored once. REST keys and WebSocket
   * clientIds live in different namespaces.
   */
  postActivity(
    conversationId: string,
    activity: PostActivityRequest,
    options: { idempotencyKey?: string; signal?: AbortSignal } = {},
  ): Promise<ResourceResponse> {
    const init: { json: unknown; headers?: Record<string, string>; signal?: AbortSignal } = { json: activity };
    if (options.idempotencyKey) init.headers = { "x-idempotency-key": options.idempotencyKey };
    if (options.signal) init.signal = options.signal;
    return this.#call("POST", `/conversations/${encodeURIComponent(conversationId)}/activities`, init);
  }

  /** One page of `GET /conversations/:id/activities?watermark=&limit=`. */
  listActivities(conversationId: string, options: HistoryOptions = {}): Promise<ActivitySet> {
    const query = new URLSearchParams();
    if (options.watermark !== undefined) query.set("watermark", String(options.watermark));
    if (options.limit !== undefined) query.set("limit", String(options.limit));
    const qs = query.toString();
    const init: { signal?: AbortSignal } = {};
    if (options.signal) init.signal = options.signal;
    return this.#call(
      "GET",
      `/conversations/${encodeURIComponent(conversationId)}/activities${qs ? `?${qs}` : ""}`,
      init,
    );
  }

  /**
   * Page through the history from a watermark until `has_more` is false.
   *
   * ```ts
   * for await (const page of rest.history(conversationId)) render(page.activities);
   * ```
   */
  async *history(conversationId: string, options: HistoryOptions = {}): AsyncGenerator<ActivitySet, void, void> {
    let watermark = options.watermark;
    for (;;) {
      const pageOptions: HistoryOptions = { ...options };
      if (watermark === undefined) delete pageOptions.watermark;
      else pageOptions.watermark = watermark;
      const page = await this.listActivities(conversationId, pageOptions);
      yield page;
      if (!page.has_more || page.activities.length === 0 || page.watermark === null) return;
      watermark = page.watermark;
    }
  }

  /** Every activity after a watermark, collected from {@link history}. */
  async allActivities(conversationId: string, options: HistoryOptions = {}): Promise<RestActivity[]> {
    const all: RestActivity[] = [];
    for await (const page of this.history(conversationId, options)) all.push(...page.activities);
    return all;
  }

  /**
   * `POST /conversations/:id/upload` (multipart): stores the file and posts an
   * activity carrying it. Max size and allowed types are server settings
   * (413 / 415 otherwise).
   */
  upload(conversationId: string, file: Blob, options: UploadOptions = {}): Promise<UploadResponse> {
    const form = new FormData();
    const named = (file as Blob & { name?: unknown }).name;
    const filename = options.filename ?? (typeof named === "string" && named !== "" ? named : "upload");
    form.append("file", file, filename);
    if (options.activity) form.append("activity", JSON.stringify(options.activity));
    const init: { body: BodyInit; signal?: AbortSignal } = { body: form };
    if (options.signal) init.signal = options.signal;
    return this.#call("POST", `/conversations/${encodeURIComponent(conversationId)}/upload`, init);
  }

  /**
   * Download an attachment (`GET /attachments/:id`, or the absolute
   * `contentUrl` of an activity). Returns the raw `Response`.
   */
  async downloadAttachment(idOrUrl: string, options: { signal?: AbortSignal } = {}): Promise<Response> {
    const url = /^https?:\/\//.test(idOrUrl)
      ? idOrUrl
      : `${this.baseUrl}/api/v1/converger/attachments/${encodeURIComponent(idOrUrl)}`;
    const init: RequestInit = { headers: { authorization: `Bearer ${await this.#getToken()}` } };
    if (options.signal) init.signal = options.signal;
    let response: Response;
    try {
      response = await this.#fetch(url, init);
    } catch (error) {
      throw new ConvergerError("network_error", `request to ${url} failed`, { cause: error });
    }
    if (!response.ok) {
      throw apiErrorFrom(response.status, await readBody(response), response.headers.get("retry-after"));
    }
    return response;
  }
}
