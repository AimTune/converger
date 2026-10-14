/**
 * The agent SDK against a real Converger server (see README.md in this
 * folder). Skipped unless CONVERGER_URL, CONVERGER_CHANNEL_SECRET (the bot
 * channel the agent serves) and CONVERGER_USER_CHANNEL_SECRET (the widget
 * channel routed to it) are set.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { channelTokenProvider, createAgent, type Agent } from "../../src/index.js";

const URL_ = process.env["CONVERGER_URL"];
const BOT_SECRET = process.env["CONVERGER_CHANNEL_SECRET"];
const USER_SECRET = process.env["CONVERGER_USER_CHANNEL_SECRET"];
const enabled = Boolean(URL_ && BOT_SECRET && USER_SECRET);

type Frame = Record<string, unknown>;

// The server de-duplicates an end user's sends by (sender, clientId) per channel,
// so every run uses fresh clientIds.
const run = Date.now().toString(36);

/** An end user on the widget channel, over the native endpoint. */
class User {
  readonly frames: Frame[] = [];
  readonly #socket: WebSocket;
  readonly #waiters = new Set<() => void>();

  private constructor(socket: WebSocket) {
    this.#socket = socket;
    socket.onmessage = (event) => {
      this.frames.push(JSON.parse(String(event.data)) as Frame);
      for (const waiter of [...this.#waiters]) waiter();
    };
  }

  static async open(baseUrl: string, secret: string): Promise<{ user: User; conversationId: string }> {
    // A plain (not channel-scoped) token creates a conversation on the widget channel.
    const generated = await fetch(`${baseUrl}/api/v1/converger/tokens/generate`, {
      method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
      body: JSON.stringify({ user: { id: "e2e-user" } }),
    }).then((r) => r.json() as Promise<{ token: string }>);
    const created = await fetch(`${baseUrl}/api/v1/converger/conversations`, {
      method: "POST",
      headers: { authorization: `Bearer ${generated.token}` },
    }).then((r) => r.json() as Promise<{ conversationId: string; token: string }>);
    const socket = new WebSocket(`${baseUrl.replace(/^http/, "ws")}/socket/converger/v1`, ["converger.v1"]);
    await new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new Error("user socket failed"));
    });
    const user = new User(socket);
    user.send({ type: "hello", protocol: "converger/1", token: created.token, conversationId: created.conversationId });
    await user.waitFor((f) => f["type"] === "welcome");
    return { user, conversationId: created.conversationId };
  }

  send(frame: Frame): void {
    this.#socket.send(JSON.stringify(frame));
  }

  waitFor(predicate: (frame: Frame) => boolean, timeoutMs = 15_000, from = 0): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const check = (): boolean => {
        const found = this.frames.slice(from).find(predicate);
        if (found) {
          clearTimeout(timer);
          this.#waiters.delete(check);
          resolve(found);
          return true;
        }
        return false;
      };
      const timer = setTimeout(() => {
        this.#waiters.delete(check);
        reject(new Error(`user did not receive the expected frame; got ${JSON.stringify(this.frames.map((f) => f["type"]))}`));
      }, timeoutMs);
      if (!check()) this.#waiters.add(check);
    });
  }

  close(): void {
    this.#socket.close();
  }
}

describe.skipIf(!enabled)("agent against a real server", () => {
  const baseUrl = (URL_ ?? "").replace(/\/+$/, "");
  let agent: Agent;
  const turns: string[] = [];

  beforeAll(async () => {
    agent = createAgent({
      url: baseUrl,
      getToken: channelTokenProvider({ url: baseUrl, secret: BOT_SECRET ?? "", userId: "e2e-agent" }),
      group: "e2e",
    });
    agent.onTurn(async (turn, reply) => {
      turns.push(turn.text);
      if (turn.text === "refund") {
        await reply.toolCall("t1", "running", { name: "lookup_order", params: { id: "ORD-42" } });
        await reply.toolCall("t1", "completed", { result: { total: 249.9 } });
        const answer = await reply.ask<{ approved: boolean }>("Refund 249.90 TRY?", {
          id: "approve#0",
          actions: [
            { label: "Approve", value: { approved: true } },
            { label: "Reject", value: { approved: false } },
          ],
        });
        await reply.text(answer.approved ? "Refunded." : "Cancelled.");
        return;
      }
      const stream = reply.stream();
      for (const word of ["Hello", " from", " the", " agent"]) stream.write(word);
      await stream.end();
      await reply.text(`You said: ${turn.text}`, { actions: [{ label: "Refund", value: "refund" }] });
    });
    await agent.start();
  });

  afterAll(async () => {
    await agent?.stop();
  });

  it("answers a user turn with a stream and a text message with chips", async () => {
    const { user, conversationId } = await User.open(baseUrl, USER_SECRET ?? "");
    try {
      user.send({ type: "text", clientId: `u-${run}-1`, data: { text: "hi there" } });
      const text = await user.waitFor((f) => f["type"] === "text" && f["from"] === "bot");
      expect(text["data"]).toEqual({ text: "You said: hi there" });
      expect(text["actions"]).toEqual([{ label: "Refund", value: "refund" }]);
      const streamed = user.frames
        .filter((f) => f["type"] === "genui" && (f["chunk"] as Frame)["type"] === "text")
        .map((f) => (f["chunk"] as Frame)["content"])
        .join("");
      expect(streamed).toBe("Hello from the agent");
      expect(user.frames.some((f) => f["type"] === "run" && (f["data"] as Frame)["status"] === "started")).toBe(true);
      expect(turns).toContain("hi there");
      expect(agent.watermarks()[conversationId]).toBeGreaterThan(0);
    } finally {
      user.close();
    }
  });

  it("pauses on ask and continues when the user answers with resume", async () => {
    const { user } = await User.open(baseUrl, USER_SECRET ?? "");
    try {
      user.send({ type: "text", clientId: `u-${run}-2`, data: { text: "refund" } });
      const tool = await user.waitFor((f) => f["type"] === "tool_call" && (f["data"] as Frame)["status"] === "completed");
      expect((tool["data"] as Frame)["name"]).toBe("lookup_order");
      const interrupt = await user.waitFor((f) => f["type"] === "interrupt");
      expect(interrupt["id"]).toBe("approve#0");
      user.send({ type: "resume", answers: { "approve#0": { approved: true } } });
      await user.waitFor((f) => f["type"] === "interrupt_resolved");
      const done = await user.waitFor((f) => f["type"] === "text" && f["from"] === "bot" && (f["data"] as Frame)["text"] === "Refunded.");
      expect(done).toBeDefined();
    } finally {
      user.close();
    }
  });
});
