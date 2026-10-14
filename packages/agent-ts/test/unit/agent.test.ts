import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as WsWebSocket } from "ws";
import { createAgent, isAgentError, type Agent, type AgentError, type AgentOptions, type Turn, type WebSocketConstructor } from "../../src/index.js";
import { FakeConvergerServer } from "../../src/testing/index.js";
import { clientEnvelopeErrors, helloErrors, serverEnvelopeErrors, serverFrameErrors } from "../support/schema.js";

const CONV = "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70";
const OTHER = "9b1d2c3e-0000-4000-8000-00000000abcd";

let server: FakeConvergerServer;
let agents: Agent[] = [];

function agentFor(options: Partial<AgentOptions> = {}): Agent {
  const agent = createAgent({
    url: server.url,
    token: "token-1",
    reconnect: { initialDelayMs: 20, maxDelayMs: 50 },
    streamFlushMs: 10,
    ...options,
  });
  agents.push(agent);
  return agent;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Every frame the agents sent must be a valid hello or client envelope. */
function expectSchemaValid(): void {
  for (const received of server.received) {
    if (received.conversationId === undefined) {
      if (received.frame["type"] === "hello") expect(helloErrors(received.frame)).toBeUndefined();
      continue;
    }
    const envelope = { conversationId: received.conversationId, frame: received.frame };
    expect(clientEnvelopeErrors(envelope), JSON.stringify(envelope)).toBeUndefined();
  }
}

beforeEach(async () => {
  server = await FakeConvergerServer.start();
});

afterEach(async () => {
  for (const agent of agents) await agent.stop({ timeoutMs: 200 });
  agents = [];
  await server.stop();
});

describe("handshake", () => {
  it("sends a channel hello with the token, group and protocol, and resolves start() at welcome", async () => {
    const agent = agentFor({ group: "faq-bot", userId: "faq-agent" });
    const connected: unknown[] = [];
    agent.on("connected", (welcome) => connected.push(welcome));
    await agent.start();
    expect(agent.connected).toBe(true);
    expect(agent.channelId).toBe("fake-channel");
    expect(connected).toHaveLength(1);
    expect(serverFrameErrors(agent.welcome)).toBeUndefined();
    expect(server.hellos[0]).toEqual({ type: "hello", protocol: "converger/1", token: "token-1", group: "faq-bot", userId: "faq-agent" });
    expectSchemaValid();
  });

  it("uses getToken and an injected WebSocket (the ws package)", async () => {
    const reasons: string[] = [];
    const agent = agentFor({
      token: undefined,
      getToken: (request) => {
        reasons.push(request.reason);
        return Promise.resolve("token-from-provider");
      },
      WebSocket: WsWebSocket as unknown as WebSocketConstructor,
    });
    await agent.start();
    expect(server.hellos[0]?.["token"]).toBe("token-from-provider");
    expect(reasons).toEqual(["connect"]);
  });

  it("rejects start() when the token is refused (4401) and there is no getToken", async () => {
    server.rejectedTokens.add("bad");
    const agent = agentFor({ token: "bad" });
    const error = await agent.start().then(
      () => undefined,
      (e: unknown) => e,
    );
    expect(isAgentError(error, "unauthorized")).toBe(true);
    expect((error as AgentError).retryable).toBe(false);
  });

  it("asks getToken again with reason `rejected` after a 4401", async () => {
    server.rejectedTokens.add("old");
    const reasons: string[] = [];
    const agent = agentFor({
      token: undefined,
      getToken: (request) => {
        reasons.push(request.reason);
        return reasons.length === 1 ? "old" : "new";
      },
    });
    await agent.start();
    expect(reasons).toEqual(["connect", "rejected"]);
    expect(server.hellos.map((h) => h["token"])).toEqual(["old", "new"]);
  });

  it("needs a token or getToken", () => {
    expect(() => createAgent({ url: server.url })).toThrow(/token/);
  });
});

describe("turns", () => {
  it("dispatches an enveloped user turn with its fields, and replies in the same envelope", async () => {
    const agent = agentFor();
    let seen: Turn | undefined;
    agent.onTurn(async (turn, reply) => {
      seen = turn;
      await reply.text(`echo: ${turn.text}`, { actions: [{ label: "More", value: "more" }] });
    });
    await agent.start();
    const result = await server.turn(CONV, {
      type: "text",
      data: { text: "hi" },
      meta: { locale: "tr-TR", channel: { type: "whatsapp" } },
      metadata: { action: { label: "Hi", value: "hi", source: "button" } },
      replyTo: { id: "m-1", seq: 1 },
    });
    expect(seen?.conversationId).toBe(CONV);
    expect(seen?.text).toBe("hi");
    expect(seen?.type).toBe("text");
    expect(seen?.participant).toEqual({ id: "user-1", role: "user" });
    expect(seen?.meta).toEqual({ locale: "tr-TR", channel: { type: "whatsapp" } });
    expect(seen?.channel).toEqual({ type: "whatsapp" });
    expect(seen?.action).toEqual({ label: "Hi", value: "hi", source: "button" });
    expect(seen?.replyTo).toEqual({ id: "m-1", seq: 1 });
    expect(seen?.seq).toBe(1);
    expect(seen?.raw.conversationId).toBe(CONV);
    expect(result.texts).toEqual(["echo: hi"]);
    expect(result.messages[0]?.["actions"]).toEqual([{ label: "More", value: "more" }]);
    expect(result.frames.map((f) => f["type"])).toEqual(["run", "text", "run"]);
    expect(result.status).toBe("finished");
    expectSchemaValid();
  });

  it("maps media turns to attachments", async () => {
    const agent = agentFor();
    let seen: Turn | undefined;
    agent.onTurn((turn) => {
      seen = turn;
    });
    await agent.start();
    await server.turn(CONV, { type: "image", data: { url: "https://example.com/a.png", caption: "receipt" } });
    expect(seen?.text).toBe("receipt");
    expect(seen?.attachments).toEqual([{ url: "https://example.com/a.png", caption: "receipt", contentType: "image" }]);
  });

  it("ignores frames from bots by default, and dispatches them with includeBotTurns", async () => {
    const texts: string[] = [];
    const agent = agentFor();
    agent.onTurn((turn) => {
      texts.push(turn.text);
    });
    await agent.start();
    server.botSays(CONV, "from another bot");
    await server.turn(CONV, "from the user");
    expect(texts).toEqual(["from the user"]);

    const second = agentFor({ includeBotTurns: true });
    const all: string[] = [];
    second.onTurn((turn) => {
      all.push(turn.text);
    });
    await second.start();
    server.botSays(OTHER, "bot turn");
    await server.waitFor(() => all.length === 1 || undefined);
    expect(all).toEqual(["bot turn"]);
  });

  it("serialises turns of one conversation and runs conversations concurrently", async () => {
    const agent = agentFor();
    const log: string[] = [];
    agent.onTurn(async (turn, reply) => {
      log.push(`start ${turn.text}`);
      await sleep(turn.text.startsWith("slow") ? 80 : 5);
      log.push(`end ${turn.text}`);
      await reply.text("ok");
    });
    await agent.start();
    server.userSays(CONV, "slow-1");
    server.userSays(CONV, "fast-2");
    server.userSays(OTHER, "fast-other");
    await server.waitFor(() => log.length === 6 || undefined);
    // fast-other ran while slow-1 was still running; fast-2 waited for slow-1.
    expect(log.indexOf("end fast-other")).toBeLessThan(log.indexOf("end slow-1"));
    expect(log.indexOf("start fast-2")).toBeGreaterThan(log.indexOf("end slow-1"));
  });

  it("reports a throwing handler as an error and ends the run with status error", async () => {
    const agent = agentFor();
    const errors: AgentError[] = [];
    agent.on("error", (e) => errors.push(e));
    agent.onTurn(() => {
      throw new Error("boom");
    });
    await agent.start();
    const result = await server.turn(CONV, "hi");
    expect(result.status).toBe("error");
    expect(errors[0]?.code).toBe("handler_error");
    expect(errors[0]?.conversationId).toBe(CONV);
  });

  it("aborts the running turn when the end user sends abort", async () => {
    const agent = agentFor();
    let aborted = false;
    agent.onTurn(async (turn) => {
      await new Promise<void>((resolve) => turn.signal.addEventListener("abort", () => resolve()));
      aborted = true;
    });
    await agent.start();
    const from = server.received.length;
    server.userSays(CONV, "long task");
    await server.nextFrame((r) => r.frame["type"] === "run");
    server.abort(CONV);
    const result = await server.collect(CONV, from);
    expect(aborted).toBe(true);
    expect(result.status).toBe("aborted");
  });

  it("passes every frame to onFrame", async () => {
    const agent = agentFor();
    const frames: string[] = [];
    agent.onFrame((frame, conversationId) => frames.push(`${conversationId ?? "-"}:${frame.type}`));
    await agent.start();
    server.userSays(CONV, "hi");
    await server.waitFor(() => frames.includes(`${CONV}:text`) || undefined);
    expect(frames[0]).toBe("-:welcome");
  });
});

describe("reply helpers", () => {
  it("produce schema-valid frames for every helper", async () => {
    const agent = agentFor();
    agent.onTurn(async (_turn, reply) => {
      await reply.typing();
      await reply.toolCall("t1", "running", { name: "get_order", params: { id: "ORD-42" } });
      await reply.toolCall("t1", "completed", { result: { total: 249.9 } });
      await reply.ui("order-card", { id: "ORD-42" });
      const stream = reply.stream();
      stream.write("Hel");
      stream.write("lo");
      await stream.end();
      await reply.message("buttons", { text: "Pick", buttons: [{ label: "Refund", value: "refund" }] });
      await reply.message("card", { title: "ORD-42", buttons: [{ label: "Open", url: "https://example.com/o/42" }] });
      await reply.typing(false);
      await reply.end();
      await reply.end(); // idempotent
    });
    await agent.start();
    const result = await server.turn(CONV, "order?");
    expectSchemaValid();
    expect(result.toolCalls.map((t) => [t["name"], t["status"]])).toEqual([
      ["get_order", "running"],
      ["get_order", "completed"],
    ]);
    expect(result.streamed).toBe("Hello");
    const genui = result.frames.filter((f) => f["type"] === "genui");
    const streamIds = new Set(genui.map((f) => f["streamId"]));
    expect(streamIds.size).toBe(1);
    // The ui chunk and the text chunks have different ids; text deltas share one id.
    const textIds = new Set(genui.filter((f) => (f["chunk"] as { type: string }).type === "text").map((f) => (f["chunk"] as { id: number }).id));
    expect(textIds.size).toBe(1);
    const last = genui[genui.length - 1];
    expect(last?.["done"]).toBe(true);
    expect(last?.["chunk"]).toMatchObject({ type: "event", name: "stream_done" });
    expect(result.frames.filter((f) => f["type"] === "run").map((f) => (f["data"] as { status: string }).status)).toEqual(["started", "finished"]);
  });

  it("coalesces stream deltas into few frames", async () => {
    const agent = agentFor({ streamFlushMs: 50 });
    agent.onTurn(async (_turn, reply) => {
      const stream = reply.stream();
      for (let i = 0; i < 100; i += 1) stream.write("x");
      await stream.end();
    });
    await agent.start();
    const result = await server.turn(CONV, "go");
    expect(result.streamed).toBe("x".repeat(100));
    expect(result.frames.filter((f) => f["type"] === "genui").length).toBeLessThanOrEqual(3);
  });

  it("stream mode text sends one text message at the end", async () => {
    const agent = agentFor({ streamMode: "text" });
    agent.onTurn(async (_turn, reply) => {
      const stream = reply.stream();
      stream.write("Hello ");
      stream.write("world");
      const ack = await stream.end();
      expect(ack?.type).toBe("ack");
    });
    await agent.start();
    const result = await server.turn(CONV, "go");
    expect(result.texts).toEqual(["Hello world"]);
    expect(result.frames.some((f) => f["type"] === "genui")).toBe(false);
  });

  it("text resolves with the ack; a proactive reply sends no run frames", async () => {
    const agent = agentFor();
    await agent.start();
    const ack = await agent.reply(OTHER).text("Your order shipped.");
    expect(ack).toMatchObject({ type: "ack", seq: 1 });
    expect(server.framesFor(OTHER).map((f) => f["type"])).toEqual(["text"]);
    expect(agent.watermarks()[OTHER]).toBe(1);
  });

  it("rejects an invalid message type and a nameless first toolCall", async () => {
    const agent = agentFor();
    await agent.start();
    const reply = agent.reply(CONV);
    await expect(reply.message("Not A Type", {})).rejects.toMatchObject({ code: "invalid_message" });
    await expect(reply.toolCall("t9", "running")).rejects.toMatchObject({ code: "invalid_message" });
  });
});

describe("ask and resume", () => {
  it("sends an interrupt, resolves with the resume answer and resolves the interrupt", async () => {
    const agent = agentFor();
    const answers: unknown[] = [];
    agent.onTurn(async (_turn, reply) => {
      const answer = await reply.ask<{ approved: boolean }>("Refund 249.90 TRY?", {
        id: "approve#0",
        actions: [
          { label: "Approve", value: { approved: true } },
          { label: "Reject", value: { approved: false } },
        ],
      });
      answers.push(answer);
      await reply.text(answer.approved ? "Refunded." : "Cancelled.");
    });
    await agent.start();
    const first = await server.turn(CONV, "refund please");
    expect(first.status).toBe("interrupted");
    expect(first.interrupts[0]).toEqual({
      type: "interrupt",
      id: "approve#0",
      data: {
        payload: { title: "Refund 249.90 TRY?" },
        actions: [
          { label: "Approve", value: { approved: true } },
          { label: "Reject", value: { approved: false } },
        ],
      },
    });
    const from = server.received.length;
    server.resume(CONV, { "approve#0": { approved: true } });
    const second = await server.collect(CONV, from, { until: ["finished"] });
    expect(answers).toEqual([{ approved: true }]);
    expect(second.frames[0]).toEqual({ type: "interrupt_resolved", id: "approve#0", data: { answer: { approved: true } } });
    expect(second.texts).toEqual(["Refunded."]);
    expect(second.frames.filter((f) => f["type"] === "run").map((f) => (f["data"] as { status: string }).status)).toEqual(["started", "finished"]);
    expectSchemaValid();
  });

  it("emits resume for answers no ask is waiting for", async () => {
    const agent = agentFor();
    const resumes: unknown[] = [];
    agent.on("resume", (info) => resumes.push(info));
    await agent.start();
    server.resume(CONV, { stale: 1 });
    await server.waitFor(() => resumes.length === 1 || undefined);
    expect(resumes[0]).toEqual({ conversationId: CONV, answers: { stale: 1 }, matched: [] });
  });

  it("rejects an ask on timeout", async () => {
    const agent = agentFor();
    let error: unknown;
    agent.onTurn(async (_turn, reply) => {
      try {
        await reply.ask({ title: "Sure?" }, { timeoutMs: 30 });
      } catch (e) {
        error = e;
      }
    });
    await agent.start();
    await server.turn(CONV, "x", { until: ["finished"] });
    expect(isAgentError(error, "timeout")).toBe(true);
  });
});

describe("reconnect and resume", () => {
  it("reconnects after 1012 with retryAfterMs and resumes with per-conversation watermarks", async () => {
    const agent = agentFor();
    const texts: string[] = [];
    const disconnects: unknown[] = [];
    agent.on("disconnected", (info) => disconnects.push(info));
    agent.onTurn(async (turn, reply) => {
      texts.push(turn.text);
      await reply.text(`re: ${turn.text}`);
    });
    await agent.start();
    await server.turn(CONV, "one");
    await server.turn(OTHER, "two");
    expect(agent.watermarks()).toEqual({ [CONV]: 2, [OTHER]: 2 });

    server.closeAll(1012, JSON.stringify({ reason: "unavailable", retryAfterMs: 30 }));
    // Missed while disconnected: stored, not delivered.
    server.userSays(CONV, "missed", { deliver: false });
    await server.waitFor(() => (server.hellos.length === 2 ? true : undefined));
    expect(server.hellos[1]?.["watermarks"]).toEqual({ [CONV]: 2, [OTHER]: 2 });
    await server.waitFor(() => (texts.includes("missed") ? true : undefined));
    await sleep(30);
    expect(texts).toEqual(["one", "two", "missed"]);
    expect(disconnects[0]).toMatchObject({ code: 1012, willReconnect: true });
    expect((disconnects[0] as { retryInMs: number }).retryInMs).toBeGreaterThanOrEqual(30);
  });

  it("does not dispatch a replayed turn twice", async () => {
    const agent = agentFor();
    const texts: string[] = [];
    agent.onTurn((turn) => {
      texts.push(turn.text);
    });
    await agent.start();
    const stored = server.userSays(CONV, "once");
    await server.waitFor(() => texts.length === 1 || undefined);
    server.deliver(CONV, stored); // a duplicate delivery
    server.deliver(CONV, { type: "sync-noise" });
    await sleep(30);
    expect(texts).toEqual(["once"]);
  });

  it("starts from the given watermarks and caps the tracked list", async () => {
    const agent = agentFor({ watermarks: { a: 3, b: 4, c: 5 }, maxTrackedConversations: 2 });
    await agent.start();
    expect(server.hellos[0]?.["watermarks"]).toEqual({ b: 4, c: 5 });
  });

  it("re-sends an unacknowledged message after a reconnect with the same clientId", async () => {
    const agent = agentFor();
    await agent.start();
    server.swallowAcks = true;
    const sent = agent.reply(CONV).text("important");
    await server.waitFor(() => server.framesFor(CONV, "text").length === 1 || undefined);
    server.swallowAcks = false;
    server.kill();
    const ack = await sent;
    const sends = server.framesFor(CONV, "text");
    expect(sends).toHaveLength(2);
    expect(sends[0]?.["clientId"]).toBe(sends[1]?.["clientId"]);
    expect(ack).toMatchObject({ duplicate: true, seq: 1 });
    expect(server.transcript(CONV)).toHaveLength(1);
  });

  it("re-sends a message whose ack does not arrive in time", async () => {
    const agent = agentFor({ ackTimeoutMs: 50 });
    await agent.start();
    server.swallowAcks = true;
    const sent = agent.reply(CONV).text("hello?");
    await server.waitFor(() => server.framesFor(CONV, "text").length === 1 || undefined);
    server.swallowAcks = false;
    const ack = await sent;
    expect(ack?.duplicate).toBe(true);
    expect(server.transcript(CONV)).toHaveLength(1);
  });

  it("gives up on 4400 without reconnecting", async () => {
    const agent = agentFor();
    await agent.start();
    const done = new Promise((resolve) => agent.on("disconnected", resolve));
    server.closeAll(4400, "unsupported protocol");
    expect(await done).toMatchObject({ code: 4400, willReconnect: false });
    await sleep(60);
    expect(server.connectionCount).toBe(1);
  });
});

describe("errors", () => {
  it("rejects a send with a non-retryable error as an AgentError", async () => {
    const agent = agentFor();
    await agent.start();
    server.sendErrors.push({ code: "invalid_message", message: "bad", number: 1004, retryable: false, details: { data: ["text is required"] } });
    const error = await agent
      .reply(CONV)
      .text("x")
      .then(
        () => undefined,
        (e: unknown) => e,
      );
    expect(isAgentError(error, "invalid_message")).toBe(true);
    expect(error).toMatchObject({ retryable: false, number: 1004, conversationId: CONV, frameType: "text", details: { data: ["text is required"] } });
  });

  it("retries a retryable send error with the same clientId after retryAfterMs", async () => {
    const agent = agentFor();
    await agent.start();
    server.sendErrors.push({ code: "rate_limited", message: "slow down", number: 3000, retryable: true, retryAfterMs: 20 });
    const ack = await agent.reply(CONV).text("x");
    const sends = server.framesFor(CONV, "text");
    expect(sends).toHaveLength(2);
    expect(sends[0]?.["clientId"]).toBe(sends[1]?.["clientId"]);
    expect(ack?.seq).toBe(1);
  });

  it("emits bare and conversation errors on the error event", async () => {
    const agent = agentFor();
    const errors: AgentError[] = [];
    agent.on("error", (e) => errors.push(e));
    await agent.start();
    server.broadcast({ type: "error", data: { code: "forbidden", message: "nope", number: 2002, retryable: false } });
    server.deliver(CONV, { type: "error", data: { code: "conversation_not_found", message: "unknown", number: 4001 } });
    await server.waitFor(() => errors.length === 2 || undefined);
    expect(errors.map((e) => [e.code, e.conversationId, e.retryable])).toEqual([
      ["forbidden", undefined, false],
      ["conversation_not_found", CONV, false],
    ]);
  });
});

describe("history", () => {
  it("reads the transcript with an enveloped sync, without dispatching it as turns", async () => {
    const agent = agentFor();
    const texts: string[] = [];
    let history: unknown[] = [];
    let limited: unknown[] = [];
    agent.onTurn(async (turn, reply) => {
      texts.push(turn.text);
      if (turn.text === "what did I say?") {
        history = await turn.history();
        limited = await turn.history({ limit: 2 });
      }
      await reply.text("ok");
    });
    await agent.start();
    await server.turn(CONV, "first");
    await server.turn(CONV, "what did I say?");
    expect(texts).toEqual(["first", "what did I say?"]);
    expect(history.map((f) => (f as { seq: number }).seq)).toEqual([1, 2, 3]);
    expect(limited.map((f) => (f as { seq: number }).seq)).toEqual([2, 3]);
    expect(server.framesFor(CONV, "sync")).toEqual([
      { type: "sync", watermark: 0 },
      { type: "sync", watermark: 0 },
    ]);
  });
});

describe("fake server fidelity", () => {
  it("sends schema-valid envelopes", async () => {
    const agent = agentFor();
    const envelopes: unknown[] = [];
    agent.onFrame((frame, conversationId) => {
      if (conversationId) envelopes.push({ conversationId, frame });
    });
    agent.onTurn(async (_turn, reply) => {
      await reply.text("ok");
    });
    await agent.start();
    await server.turn(CONV, "hi");
    expect(envelopes.length).toBeGreaterThan(1);
    for (const envelope of envelopes) expect(serverEnvelopeErrors(envelope), JSON.stringify(envelope)).toBeUndefined();
  });
});
