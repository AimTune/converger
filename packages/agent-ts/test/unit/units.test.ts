import { describe, expect, it } from "vitest";
import { AgentError, backoffDelay, channelTokenProvider, generateChannelToken, resolveReconnect, type FetchLike } from "../../src/index.js";
import { endpointUrl, httpBase, retryAfterFromReason } from "../../src/socket.js";
import { WatermarkTracker } from "../../src/watermarks.js";

describe("WatermarkTracker", () => {
  it("tracks the highest seq and tells duplicates from late frames", () => {
    const t = new WatermarkTracker(10);
    expect(t.record("c", 6)).toBe(true); // the agent's own ack
    expect(t.record("c", 5)).toBe(true); // a user turn committed just before, delivered late
    expect(t.record("c", 5)).toBe(false);
    expect(t.get("c")).toBe(6);
  });

  it("treats everything up to an initial watermark as seen", () => {
    const t = new WatermarkTracker(10, { c: 4 });
    expect(t.seen("c", 4)).toBe(true);
    expect(t.record("c", 3)).toBe(false);
    expect(t.record("c", 5)).toBe(true);
  });

  it("forgets the least recently active conversation beyond capacity", () => {
    const t = new WatermarkTracker(2);
    t.record("a", 1);
    t.record("b", 1);
    t.record("a", 2);
    t.record("c", 1);
    expect(Object.keys(t.snapshot())).toEqual(["a", "c"]);
  });

  it("keeps a bounded window of seen seqs", () => {
    const t = new WatermarkTracker(1);
    for (let seq = 1; seq <= 2000; seq += 1) t.record("c", seq);
    expect(t.seen("c", 1)).toBe(true);
    expect(t.get("c")).toBe(2000);
  });
});

describe("URLs", () => {
  it("derives the endpoint URL", () => {
    expect(endpointUrl("https://c.example.com", "/socket/converger/v1")).toBe("wss://c.example.com/socket/converger/v1");
    expect(endpointUrl("http://127.0.0.1:4000/", "/socket/converger/v1")).toBe("ws://127.0.0.1:4000/socket/converger/v1");
    expect(endpointUrl("wss://c.example.com/custom/v1", "/socket/converger/v1")).toBe("wss://c.example.com/custom/v1");
    expect(httpBase("wss://c.example.com/socket/converger/v1")).toBe("https://c.example.com");
  });

  it("reads retryAfterMs from a JSON close reason", () => {
    expect(retryAfterFromReason('{"reason":"unavailable","retryAfterMs":1500}')).toBe(1500);
    expect(retryAfterFromReason("bye")).toBeUndefined();
  });
});

describe("backoff", () => {
  it("never retries earlier than retryAfterMs and caps the delay", () => {
    const policy = resolveReconnect({ initialDelayMs: 100, maxDelayMs: 1000, jitter: 0 });
    expect(backoffDelay(1, policy)).toBe(100);
    expect(backoffDelay(10, policy)).toBe(1000);
    expect(backoffDelay(1, policy, 5000)).toBe(5000);
  });
});

describe("AgentError", () => {
  it("maps an error frame, defaulting retryable from the code table", () => {
    const error = AgentError.fromFrame({ type: "error", data: { code: "unavailable", message: "draining", retryAfterMs: 900 } }, "c");
    expect(error).toMatchObject({ code: "unavailable", retryable: true, retryAfterMs: 900, conversationId: "c" });
    expect(AgentError.fromFrame({ data: { code: "forbidden", message: "" } }).message).toBe("forbidden");
  });
});

describe("channel tokens", () => {
  function fakeFetch(calls: { url: string; body: unknown; auth: string | undefined }[]): FetchLike {
    return (url, init) => {
      calls.push({ url, body: JSON.parse(init?.body ?? "{}"), auth: init?.headers?.["authorization"] });
      return Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ token: `t${calls.length}`, expires_in: 1800 }),
        text: () => Promise.resolve(""),
      });
    };
  }

  it("generates a channel-scoped token with the secret", async () => {
    const calls: { url: string; body: unknown; auth: string | undefined }[] = [];
    const token = await generateChannelToken({ url: "wss://c.example.com/socket/converger/v1", secret: "s3cret", userId: "faq-bot", fetch: fakeFetch(calls) });
    expect(token).toEqual({ token: "t1", expiresIn: 1800 });
    expect(calls[0]).toEqual({
      url: "https://c.example.com/api/v1/converger/tokens/generate",
      body: { scope: "channel", user: { id: "faq-bot" } },
      auth: "Bearer s3cret",
    });
  });

  it("caches tokens and drops the cache when the server rejected one", async () => {
    const calls: { url: string; body: unknown; auth: string | undefined }[] = [];
    const provider = channelTokenProvider({ url: "https://c.example.com", secret: "s", fetch: fakeFetch(calls) });
    expect(await provider({ reason: "connect" })).toBe("t1");
    expect(await provider({ reason: "connect" })).toBe("t1");
    expect(await provider({ reason: "rejected" })).toBe("t2");
    expect(calls).toHaveLength(2);
  });

  it("maps HTTP failures to AgentError", async () => {
    const failing: FetchLike = () =>
      Promise.resolve({ ok: false, status: 429, json: () => Promise.resolve({}), text: () => Promise.resolve("slow down") });
    await expect(generateChannelToken({ url: "https://c.example.com", secret: "s", fetch: failing })).rejects.toMatchObject({
      code: "rate_limited",
      retryable: true,
    });
  });
});
