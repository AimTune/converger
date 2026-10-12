import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ConvergerClient,
  ConvergerProtocolError,
  MemoryStorage,
  type ActivityFrame,
  type ConnectionStateChange,
  type ConvergerClientOptions,
} from "../../src/index.js";
import { MockServer, fakeToken } from "../support/mock-server.js";
import { sleep, waitFor } from "../support/helpers.js";

let server: MockServer;
const clients: ConvergerClient[] = [];

beforeEach(async () => {
  server = await MockServer.start();
});

afterEach(async () => {
  await Promise.all(clients.splice(0).map((c) => c.close()));
  await server.stop();
});

async function makeClient(overrides: Partial<ConvergerClientOptions> = {}): Promise<ConvergerClient> {
  const client = await ConvergerClient.connect({
    baseUrl: server.baseUrl,
    tokenProvider: () => fakeToken(),
    transport: "native",
    storage: new MemoryStorage(),
    reconnect: { initialDelayMs: 20, maxDelayMs: 100 },
    replayWaitMs: 500,
    gapWaitMs: 100,
    ...overrides,
  });
  clients.push(client);
  return client;
}

function texts(frames: ActivityFrame[]): string[] {
  return frames.map((f) => (f.data as { text: string }).text);
}

describe("handshake and sending", () => {
  it("starts a conversation, sends with an ack and receives activities", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    const activities: ActivityFrame[] = [];
    conversation.on("activity", (f) => activities.push(f));

    const welcome = await conversation.start();
    expect(welcome.conversationId).toBe(server.conversationId);
    expect(conversation.conversationId).toBe(server.conversationId);
    expect(conversation.state).toBe("open");

    const hello = server.received("hello")[0]!;
    expect(hello["protocol"]).toBe("converger/1");
    expect(typeof hello["token"]).toBe("string");
    expect(hello["conversationId"]).toBeUndefined();

    const result = await conversation.send("hi there");
    expect(result).toMatchObject({ seq: 1, duplicate: false });
    expect(conversation.pending).toHaveLength(0);
    expect(conversation.watermark).toBe(1);

    server.inject("hello from the agent");
    await waitFor(() => activities.length === 1, { message: "activity" });
    expect(texts(activities)).toEqual(["hello from the agent"]);
    expect(conversation.watermark).toBe(2);
  });

  it("queues sends made before the connection is open", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    const started = conversation.start();
    const sent = conversation.send("early");
    await started;
    await expect(sent).resolves.toMatchObject({ seq: 1 });
  });

  it("resumes from a watermark and replays only what is missing", async () => {
    server.inject("one");
    server.inject("two");
    server.inject("three");
    const client = await makeClient();
    const conversation = client.conversation(server.conversationId);
    const activities: ActivityFrame[] = [];
    conversation.on("activity", (f) => activities.push(f));
    await conversation.resume(1);
    await waitFor(() => activities.length === 2, { message: "replay" });
    expect(texts(activities)).toEqual(["two", "three"]);
    expect(server.received("hello")[0]!["watermark"]).toBe(1);
    expect(conversation.watermark).toBe(3);
  });

  it("rejects a send on a non-retryable error and drops it from the outbox", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    await conversation.start();
    server.sendErrors.push({ code: "invalid_message", message: "bad", retryable: false });
    const failed = vi.fn();
    conversation.on("sendFailed", failed);
    await expect(conversation.send("x")).rejects.toBeInstanceOf(ConvergerProtocolError);
    expect(conversation.pending).toHaveLength(0);
    expect(failed).toHaveBeenCalledOnce();
  });

  it("retries a send after retryAfterMs on a retryable error, with the same clientId", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    await conversation.start();
    server.sendErrors.push({ code: "rate_limited", message: "slow down", retryable: true, retryAfterMs: 150 });
    const startedAt = Date.now();
    const result = await conversation.send("retry me");
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(140);
    const texts = server.received("text");
    expect(texts).toHaveLength(2);
    expect(texts[0]!["clientId"]).toBe(texts[1]!["clientId"]);
    expect(result.clientId).toBe(texts[0]!["clientId"]);
  });
});

describe("reconnect, watermark resume and the outbox", () => {
  it("reconnects after a crash, resends the unacked message once and receives missed activities", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    const activities: ActivityFrame[] = [];
    conversation.on("activity", (f) => activities.push(f));
    await conversation.start();
    await conversation.send("before the crash");

    // The server dies; a send made meanwhile waits in the outbox.
    server.down = true;
    server.kill();
    await waitFor(() => conversation.state === "reconnecting", { message: "reconnecting" });
    const pending = conversation.send("while offline");
    await sleep(80);
    expect(conversation.pending).toHaveLength(1);

    // Activities committed while the client was away.
    server.injectSilently("missed 1");
    server.injectSilently("missed 2");
    server.down = false;

    const result = await pending;
    expect(result.duplicate).toBe(false);
    await waitFor(() => activities.length === 2, { message: "missed activities" });
    expect(texts(activities)).toEqual(["missed 1", "missed 2"]);

    const resumeHello = server.received("hello").at(-1)!;
    expect(resumeHello["conversationId"]).toBe(server.conversationId);
    expect(resumeHello["watermark"]).toBe(1);
    expect(resumeHello["userId"]).toBe(conversation.userId);

    // "while offline" went on the wire exactly once, and is stored once.
    expect(server.received("text").filter((f) => (f["data"] as { text: string }).text === "while offline")).toHaveLength(1);
    expect(server.log.filter((a) => a.text === "while offline")).toHaveLength(1);
    expect(conversation.watermark).toBe(server.head);
  });

  it("resends a message whose ack was lost, and the server de-duplicates it", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    await conversation.start();
    server.inject("context"); // seq 1 so the resend happens without replay of the own turn
    server.swallowAcks = true;
    const pending = conversation.send("ack lost");
    await waitFor(() => server.log.length === 2, { message: "stored" });
    server.swallowAcks = false;
    // Make the own turn invisible to the replay so the client has to resend.
    server.log[1]!.clientId = undefined;
    server.kill();
    const result = await pending;
    expect(result.duplicate).toBe(true);
    expect(server.log.filter((a) => a.text === "ack lost")).toHaveLength(1);
    expect(server.received("text")).toHaveLength(2);
  });

  it("settles a send from the replay when the server stored it but the ack was lost", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    await conversation.start();
    server.swallowAcks = true;
    const pending = conversation.send("stored, no ack");
    await waitFor(() => server.log.length === 1, { message: "stored" });
    server.swallowAcks = false;
    server.kill();
    const result = await pending;
    expect(result).toMatchObject({ seq: 1, duplicate: true });
    // No resend: the replayed frame carried the clientId.
    expect(server.received("text")).toHaveLength(1);
  });

  it("restores a persisted outbox in a new session and resends it", async () => {
    const storage = new MemoryStorage();
    server.down = true;
    const first = await makeClient({ storage });
    const conversation = first.conversation(server.conversationId);
    void conversation.resume(0).catch(() => undefined);
    const lost = conversation.send("survives a reload");
    lost.catch(() => undefined);
    await sleep(50);
    await conversation.disconnect();
    await expect(lost).rejects.toMatchObject({ code: "disconnected" });

    server.down = false;
    const second = await makeClient({ storage });
    const restored = second.conversation(server.conversationId);
    expect(restored.pending).toHaveLength(0);
    const sent = vi.fn();
    restored.on("sent", sent);
    await restored.resume();
    expect(restored.pending.length + sent.mock.calls.length).toBe(1);
    await waitFor(() => sent.mock.calls.length === 1, { message: "restored send" });
    expect(server.log.map((a) => a.text)).toEqual(["survives a reload"]);
  });

  it("honours retryAfterMs from a JSON close reason", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    const states: ConnectionStateChange[] = [];
    conversation.on("connectionState", (s) => states.push(s));
    await conversation.start();
    server.closeAll(1012, JSON.stringify({ reason: "unavailable", retryAfterMs: 400 }));
    const reconnecting = await waitFor(() => states.find((s) => s.state === "reconnecting"), { message: "reconnecting" });
    expect(reconnecting.delayMs).toBeGreaterThanOrEqual(400);
    expect(reconnecting.close?.retryAfterMs).toBe(400);
    await waitFor(() => conversation.state === "open", { timeout: 3_000, message: "reopen" });
  });

  it("gets a new token after close 4401 and reconnects", async () => {
    const provider = vi.fn((_ctx: { reason: string }) => fakeToken());
    const client = await makeClient({ tokenProvider: provider });
    const conversation = client.conversation();
    await conversation.start();
    server.closeAll(4401, "token expired");
    await waitFor(() => provider.mock.calls.some(([ctx]) => ctx.reason === "rejected"), { message: "rejected refresh" });
    await waitFor(() => server.connectionCount === 2 && conversation.state === "open", { message: "reconnect" });
  });

  it("stops on close 4400 and rejects start()", async () => {
    server.rejectHello = { code: 4400, reason: "unsupported protocol", error: "unsupported_protocol" };
    const client = await makeClient();
    const conversation = client.conversation();
    await expect(conversation.start()).rejects.toMatchObject({ code: "unsupported_protocol" });
    expect(conversation.state).toBe("closed");
    await sleep(100);
    expect(server.connectionCount).toBe(1);
  });

  it("fills a seq gap with sync", async () => {
    const client = await makeClient();
    const conversation = client.conversation();
    const activities: ActivityFrame[] = [];
    conversation.on("activity", (f) => activities.push(f));
    await conversation.start();
    server.injectSilently("lost in pubsub");
    server.inject("after the gap");
    await waitFor(() => activities.length === 2, { message: "gap fill" });
    expect(server.received("sync")[0]).toEqual({ type: "sync", watermark: 0 });
    expect(conversation.watermark).toBe(2);
    expect(texts(activities).sort()).toEqual(["after the gap", "lost in pubsub"]);
  });

  it("starts over from 0 when its watermark is above the head", async () => {
    server.inject("only one");
    const client = await makeClient();
    const conversation = client.conversation(server.conversationId);
    const activities: ActivityFrame[] = [];
    conversation.on("activity", (f) => activities.push(f));
    conversation.on("error", () => undefined);
    await conversation.resume(10);
    await waitFor(() => activities.length === 1, { message: "resync" });
    expect(conversation.watermark).toBe(1);
  });
});

describe("token refresh", () => {
  it("refreshes before expiry and sends auth on the live connection", async () => {
    const provider = vi.fn((_ctx: { reason: string }) => fakeToken());
    server.expiresAt = Date.now() + 400;
    const client = await makeClient({ tokenProvider: provider, refreshSkewMs: 200 });
    const conversation = client.conversation();
    await conversation.start();
    await waitFor(() => server.received("auth").length === 1, { timeout: 2_000, message: "auth frame" });
    expect(provider.mock.calls.at(-1)?.[0].reason).toBe("refresh");
    // tokenRefreshed moved the expiry 30 min ahead: no second refresh soon.
    await sleep(300);
    expect(server.received("auth")).toHaveLength(1);
  });
});
