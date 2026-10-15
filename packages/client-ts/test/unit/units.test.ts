import { describe, expect, it, vi } from "vitest";
import {
  ConvergerApiError,
  ConvergerClient,
  MemoryStorage,
  WebStorage,
  apiErrorFrom,
  backoffDelay,
  createRefreshingTokenProvider,
  decodeToken,
  defaultStorage,
  encodeOpaqueWatermark,
  isPersistent,
  parseRetryAfter,
  parseWatermark,
  resolveReconnect,
} from "../../src/index.js";
import { ConversationStore } from "../../src/storage/outbox.js";
import { TokenManager } from "../../src/token.js";
import { fakeToken } from "../support/mock-server.js";

describe("backoff", () => {
  const policy = resolveReconnect({ initialDelayMs: 1000, maxDelayMs: 30_000, jitter: 0.5 });

  it("grows exponentially, capped, with equal jitter", () => {
    expect(backoffDelay(1, policy, undefined, () => 0)).toBe(500);
    expect(backoffDelay(1, policy, undefined, () => 1)).toBe(1000);
    expect(backoffDelay(3, policy, undefined, () => 1)).toBe(4000);
    expect(backoffDelay(20, policy, undefined, () => 1)).toBe(30_000);
    expect(backoffDelay(20, policy, undefined, () => 0)).toBe(15_000);
  });

  it("never goes below retryAfterMs", () => {
    expect(backoffDelay(1, policy, 5_000, () => 0)).toBe(5_000);
    expect(backoffDelay(10, policy, 5_000, () => 1)).toBe(30_000);
  });

  it("caps the default policy at 10 s, unless the server asks for longer", () => {
    const defaults = resolveReconnect(undefined);
    expect(defaults.maxDelayMs).toBe(10_000);
    expect(backoffDelay(20, defaults, undefined, () => 1)).toBe(10_000);
    expect(backoffDelay(20, defaults, 12_000, () => 1)).toBe(12_000);
  });

  it("can be disabled", () => {
    expect(resolveReconnect(false).enabled).toBe(false);
  });
});

describe("watermarks", () => {
  it("parses integers, decimal strings and the opaque seq form", () => {
    expect(parseWatermark(12)).toBe(12);
    expect(parseWatermark("12")).toBe(12);
    expect(parseWatermark(encodeOpaqueWatermark(42))).toBe(42);
    expect(encodeOpaqueWatermark(42)).toBe("c2VxOjQy");
  });

  it("rejects everything else", () => {
    expect(parseWatermark(-1)).toBeNull();
    expect(parseWatermark(1.5)).toBeNull();
    expect(parseWatermark("")).toBeNull();
    expect(parseWatermark("not-a-watermark")).toBeNull();
    expect(parseWatermark(null)).toBeNull();
    // A legacy activity-id watermark has no seq.
    expect(parseWatermark(btoa("c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70"))).toBeNull();
  });
});

describe("frames", () => {
  it("tells persistent frames from control frames", () => {
    expect(isPersistent({ type: "text", seq: 3 })).toBe(true);
    expect(isPersistent({ type: "tool_call", seq: 3 })).toBe(true);
    expect(isPersistent({ type: "ack", seq: 3 })).toBe(false);
    expect(isPersistent({ type: "typing" })).toBe(false);
    expect(isPersistent({ type: "text" })).toBe(false);
  });
});

describe("REST errors", () => {
  it("reads the standard envelope (#45)", () => {
    const error = apiErrorFrom(404, {
      error: { code: "conversation_not_found", message: "no such conversation", details: { id: "x" }, request_id: "req-1" },
    });
    expect(error).toBeInstanceOf(ConvergerApiError);
    expect(error).toMatchObject({ status: 404, code: "conversation_not_found", message: "no such conversation", requestId: "req-1" });
    expect(error.details).toEqual({ id: "x" });
  });

  it("reads today's shapes", () => {
    expect(apiErrorFrom(400, { error: "Missing file in upload" })).toMatchObject({ code: "bad_request", message: "Missing file in upload" });
    expect(apiErrorFrom(409, { error: "conversation_closed", detail: "Conversation is closed" })).toMatchObject({
      code: "conversation_closed",
      message: "Conversation is closed",
    });
    expect(apiErrorFrom(401, { errors: { detail: "Unauthorized" } })).toMatchObject({ code: "unauthorized", message: "Unauthorized" });
    const validation = apiErrorFrom(422, { errors: { text: ["is too long"] } });
    expect(validation).toMatchObject({ code: "invalid_message", details: { text: ["is too long"] } });
    expect(apiErrorFrom(502, "<html>bad gateway</html>")).toMatchObject({ code: "bad_gateway" });
  });

  it("parses Retry-After", () => {
    expect(apiErrorFrom(429, { error: "slow down" }, "2").retryAfterMs).toBe(2000);
    expect(parseRetryAfter(new Date(10_000).toUTCString(), 4_000)).toBe(6_000);
    expect(parseRetryAfter(undefined)).toBeUndefined();
  });
});

describe("tokens", () => {
  it("decodes JWT claims without verifying", () => {
    const token = fakeToken({ user_id: "alice", conversation_id: "c-1" });
    expect(decodeToken(token)).toMatchObject({ type: "converger", user_id: "alice", conversation_id: "c-1" });
    expect(decodeToken("opaque")).toBeNull();
  });

  it("refreshes ahead of expiry, capped at half the lifetime", () => {
    const now = Date.now();
    const manager = new TokenManager(() => "x", 60_000, { token: "t", expiresAt: now + 1_800_000 });
    expect(manager.refreshDelay(now)).toBe(1_740_000);
    const short = new TokenManager(() => "x", 60_000, { token: "t", expiresAt: now + 10_000 });
    expect(short.refreshDelay(now)).toBeGreaterThanOrEqual(4_990);
    expect(short.refreshDelay(now)).toBeLessThanOrEqual(5_010);
  });

  it("de-duplicates concurrent fetches", async () => {
    let calls = 0;
    const manager = new TokenManager(async () => {
      calls += 1;
      return fakeToken();
    }, 60_000);
    await Promise.all([manager.fetch("refresh"), manager.fetch("refresh"), manager.get()]);
    expect(calls).toBe(1);
  });

  it("renews with POST /tokens/refresh", async () => {
    const fetch = vi.fn(async () => new Response(JSON.stringify({ token: "fresh", expires_in: 1800, conversationId: null }), { status: 200 }));
    const provider = createRefreshingTokenProvider({ baseUrl: "https://x.test/", token: "old", fetch });
    expect(await provider({ reason: "initial" })).toBe("old");
    expect(await provider({ reason: "refresh" })).toMatchObject({ token: "fresh", expiresIn: 1800 });
    expect(fetch).toHaveBeenCalledWith("https://x.test/api/v1/converger/tokens/refresh", expect.objectContaining({ method: "POST" }));
  });

  it("connect() fails fast when the provider fails", async () => {
    await expect(
      ConvergerClient.connect({ baseUrl: "http://localhost:1", tokenProvider: () => Promise.reject(new Error("nope")) }),
    ).rejects.toMatchObject({ code: "token_provider_failed" });
    await expect(ConvergerClient.connect({ baseUrl: "ws://x", tokenProvider: () => "t" })).rejects.toMatchObject({ code: "invalid_option" });
  });
});

describe("storage", () => {
  it("defaults to memory outside browsers", () => {
    expect(defaultStorage()).toBeInstanceOf(MemoryStorage);
  });

  it("persists the outbox and resume state per conversation", async () => {
    const backing = new Map<string, string>();
    const storage = new WebStorage({
      getItem: (k) => backing.get(k) ?? null,
      setItem: (k, v) => void backing.set(k, v),
      removeItem: (k) => void backing.delete(k),
    });
    const errors: unknown[] = [];
    const store = new ConversationStore(storage, "app", null, (e) => errors.push(e));
    store.add({ clientId: "c1", frame: { type: "text", clientId: "c1", data: { text: "hi" } }, createdAt: 1, attempts: 0 });
    await store.flush();
    expect(backing.size).toBe(0); // no conversation id yet
    await store.attach("conv-1");
    store.setState({ conversationId: "conv-1", watermark: 7, userId: "u" });
    await store.flush();
    const restored = new ConversationStore(storage, "app", "conv-1", (e) => errors.push(e));
    await restored.load();
    expect(restored.entries.map((e) => e.clientId)).toEqual(["c1"]);
    expect(restored.state).toEqual({ conversationId: "conv-1", watermark: 7, userId: "u" });
    restored.remove("c1");
    await restored.clear();
    expect(backing.size).toBe(0);
    expect(errors).toEqual([]);
  });

  it("reports storage failures instead of throwing", async () => {
    const errors: unknown[] = [];
    const store = new ConversationStore(
      { getItem: () => null, setItem: () => Promise.reject(new Error("quota")), removeItem: () => undefined },
      "app",
      "c",
      (e) => errors.push(e),
    );
    store.add({ clientId: "c1", frame: { type: "text", data: { text: "x" } }, createdAt: 1, attempts: 0 });
    await store.flush();
    expect(errors).toHaveLength(1);
  });
});
