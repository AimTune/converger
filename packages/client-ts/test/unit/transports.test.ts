import { afterEach, describe, expect, it, vi } from "vitest";
import { WebSocketServer, type WebSocket } from "ws";
import type { AddressInfo } from "node:net";
import {
  ConvergerClient,
  MemoryStorage,
  RestClient,
  encodeOpaqueWatermark,
  phoenixTransport,
  sseTransport,
  type ActivityFrame,
  type FetchLike,
} from "../../src/index.js";
import { activityToFrame } from "../../src/transport/phoenix.js";
import { fakeToken } from "../support/mock-server.js";
import { waitFor } from "../support/helpers.js";

const CONVERSATION = "11111111-2222-3333-4444-555555555555";

function restActivity(id: string, sender: string, text: string) {
  return {
    id,
    type: "message",
    from: { id: sender },
    text,
    timestamp: "2026-10-12T10:00:00Z",
    attachments: [],
    conversationId: CONVERSATION,
    channelData: {},
  };
}

describe("phoenix activity mapping", () => {
  it("maps REST activities to v1 frames relative to the user", () => {
    const mine = activityToFrame(restActivity("a1", "alice", "hi"), 4, "alice");
    expect(mine).toMatchObject({ type: "text", id: "a1", seq: 4, from: "user", data: { text: "hi" }, sender: { id: "alice", role: "user" } });
    const theirs = activityToFrame({ ...restActivity("a2", "agent", "yo"), replyToId: "a1" }, 5, "alice");
    expect(theirs).toMatchObject({ from: "bot", replyTo: { id: "a1" } });
    const update = activityToFrame({ ...restActivity("a3", "system", ""), type: "conversationUpdate", channelData: { event: "conversation_closed" } }, 6, "alice");
    expect(update).toMatchObject({ type: "conversationUpdate", data: { event: "conversation_closed" }, sender: { role: "system" } });
    const reaction = activityToFrame({ ...restActivity("a4", "agent", "👍"), type: "messageReaction", replyToId: "a1" }, 7, "alice");
    expect(reaction).toMatchObject({ type: "event", data: { name: "messageReaction", value: { replyToId: "a1" } } });
  });
});

describe("phoenix transport", () => {
  let wss: WebSocketServer | undefined;
  afterEach(async () => {
    await new Promise<void>((resolve) => (wss ? wss.close(() => resolve()) : resolve()));
    wss = undefined;
  });

  it("joins with an opaque watermark, derives seqs and sends v1 frames", async () => {
    wss = new WebSocketServer({ port: 0 });
    await new Promise<void>((resolve) => wss!.once("listening", () => resolve()));
    const port = (wss.address() as AddressInfo).port;
    const received: unknown[][] = [];
    let url = "";
    let seq = 2;
    wss.on("connection", (socket: WebSocket, request) => {
      url = request.url ?? "";
      socket.on("message", (raw) => {
        const [joinRef, ref, topic, event, payload] = JSON.parse(String(raw)) as [string, string, string, string, Record<string, unknown>];
        received.push([joinRef, ref, topic, event, payload]);
        const push = (ev: string, body: unknown, r: string | null = null) => socket.send(JSON.stringify([joinRef, r, topic, ev, body]));
        if (event === "phx_join") {
          push("phx_reply", { status: "ok", response: {} }, ref);
          push("activitySet", {
            activities: [restActivity("a1", "agent", "one"), restActivity("a2", "agent", "two")],
            watermark: encodeOpaqueWatermark(2),
            has_more: false,
          });
        } else if (event === "frame") {
          seq += 1;
          push("phx_reply", { status: "ok", response: {} }, ref);
          push("frame", { type: "ack", clientId: payload["clientId"], id: `a${seq}`, seq });
          // The binding echoes the sender's own turn.
          push("activitySet", { activities: [restActivity(`a${seq}`, "alice", "mine")], watermark: encodeOpaqueWatermark(seq), has_more: false });
          push("typing", { type: "typing", isTyping: true, from: "bot", sender: { id: "agent", role: "agent" } });
        }
      });
    });

    const client = await ConvergerClient.connect({
      baseUrl: `http://127.0.0.1:${port}`,
      tokenProvider: () => fakeToken({ conversation_id: CONVERSATION, user_id: "alice" }),
      transport: phoenixTransport(),
      storage: new MemoryStorage(),
    });
    const conversation = client.conversation(CONVERSATION);
    const activities: ActivityFrame[] = [];
    const typing = vi.fn();
    conversation.on("activity", (f) => activities.push(f));
    conversation.on("typing", typing);
    await conversation.resume(0);
    expect(url).toContain("/socket/converger/websocket?token=");
    expect(url).toContain("vsn=2.0.0");
    const join = received.find((m) => m[3] === "phx_join")!;
    expect(join[2]).toBe(`converger:conversation:${CONVERSATION}`);
    expect(join[4]).toEqual({ watermark: encodeOpaqueWatermark(0) });

    await waitFor(() => activities.length === 2, { message: "replay" });
    expect(activities.map((a) => a.seq)).toEqual([1, 2]);

    const result = await conversation.send("mine");
    expect(result.seq).toBe(3);
    await waitFor(() => typing.mock.calls.length === 1, { message: "typing" });
    // The echoed own turn is not reported as a new activity.
    expect(activities).toHaveLength(2);
    expect(conversation.watermark).toBe(3);
    const frame = received.find((m) => m[3] === "frame")!;
    expect(frame[4]).toMatchObject({ type: "text", data: { text: "mine" } });
    await client.close();
  });
});

describe("sse transport", () => {
  it("receives frames from the stream and sends over REST with the WebSocket idempotency key", async () => {
    const calls: { url: string; init: RequestInit | undefined }[] = [];
    let streamController: ReadableStreamDefaultController<Uint8Array> | undefined;
    const encoder = new TextEncoder();
    const fetch: FetchLike = async (url, init) => {
      calls.push({ url, init });
      if (url.includes("/events")) {
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            streamController = controller;
            controller.enqueue(
              encoder.encode(
                `id: 1\nevent: text\ndata: ${JSON.stringify({ type: "text", id: "a1", seq: 1, from: "bot", data: { text: "replayed" } })}\n\n`,
              ),
            );
          },
        });
        return new Response(body, { status: 200 });
      }
      // POST activities
      queueMicrotask(() =>
        streamController!.enqueue(
          encoder.encode(
            `id: 2\nevent: text\ndata: ${JSON.stringify({ type: "text", id: "a2", seq: 2, from: "user", clientId: "c-1", data: { text: "sent" } })}\n\n`,
          ),
        ),
      );
      return new Response(JSON.stringify({ id: "a2" }), { status: 200 });
    };

    const client = await ConvergerClient.connect({
      baseUrl: "http://sse.test",
      tokenProvider: () => fakeToken({ user_id: "alice" }),
      transport: sseTransport(),
      storage: new MemoryStorage(),
      fetch,
    });
    const conversation = client.conversation(CONVERSATION);
    const activities: ActivityFrame[] = [];
    conversation.on("activity", (f) => activities.push(f));
    await conversation.resume(0);
    await waitFor(() => activities.length === 1, { message: "stream frame" });
    expect(calls[0]!.url).toBe(`http://sse.test/api/v1/converger/conversations/${CONVERSATION}/events?watermark=0`);
    expect((calls[0]!.init!.headers as Record<string, string>)["authorization"]).toMatch(/^Bearer /);

    const result = await conversation.send({ text: "sent", clientId: "c-1" });
    expect(result).toMatchObject({ clientId: "c-1", id: "a2", seq: 2 });
    const post = calls.find((c) => c.init?.method === "POST")!;
    expect((post.init!.headers as Record<string, string>)["x-idempotency-key"]).toBe("ws:alice:c-1");
    expect(JSON.parse(String(post.init!.body))).toMatchObject({ text: "sent", from: { id: "alice" } });
    expect(activities).toHaveLength(1);
    await client.close();
  });
});

describe("REST client", () => {
  it("pages the history until has_more is false", async () => {
    const pages = [
      { activities: [restActivity("a1", "u", "1"), restActivity("a2", "u", "2")], watermark: "w2", has_more: true },
      { activities: [restActivity("a3", "u", "3")], watermark: "w3", has_more: false },
    ];
    const urls: string[] = [];
    const fetch: FetchLike = async (url) => {
      urls.push(url);
      return new Response(JSON.stringify(pages.shift()), { status: 200 });
    };
    const rest = new RestClient({ baseUrl: "http://r.test", getToken: () => "tok", fetch });
    const all = await rest.allActivities(CONVERSATION, { limit: 2 });
    expect(all.map((a) => a.text)).toEqual(["1", "2", "3"]);
    expect(urls).toEqual([
      `http://r.test/api/v1/converger/conversations/${CONVERSATION}/activities?limit=2`,
      `http://r.test/api/v1/converger/conversations/${CONVERSATION}/activities?watermark=w2&limit=2`,
    ]);
  });

  it("uploads multipart with the activity JSON", async () => {
    let captured: RequestInit | undefined;
    const fetch: FetchLike = async (_url, init) => {
      captured = init;
      return new Response(JSON.stringify({ id: "a1", attachments: [{ id: "f1", contentType: "text/plain", contentUrl: "/x", size: 5 }] }), { status: 200 });
    };
    const rest = new RestClient({ baseUrl: "http://r.test", getToken: () => "tok", fetch });
    const response = await rest.upload(CONVERSATION, new Blob(["hello"], { type: "text/plain" }), { filename: "a.txt", activity: { text: "see file" } });
    expect(response.attachments[0]!.id).toBe("f1");
    const form = captured!.body as FormData;
    expect((form.get("file") as File).name).toBe("a.txt");
    expect(JSON.parse(String(form.get("activity")))).toEqual({ text: "see file" });
  });

  it("throws ConvergerApiError with the parsed body", async () => {
    const fetch: FetchLike = async () => new Response(JSON.stringify({ error: "conversation_closed", detail: "Conversation is closed" }), { status: 409 });
    const rest = new RestClient({ baseUrl: "http://r.test", getToken: () => "tok", fetch });
    await expect(rest.postActivity(CONVERSATION, { text: "x" }, { idempotencyKey: "k" })).rejects.toMatchObject({
      status: 409,
      code: "conversation_closed",
    });
  });
});
