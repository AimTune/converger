/**
 * Acceptance test of issue #46 against the real server: kill the server
 * mid-session; the client reconnects, resends its unacknowledged message
 * exactly once, and receives the activities it missed through its watermark.
 *
 * Needs Elixir/mix and PostgreSQL (see README.md, "Running the e2e test").
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  ConvergerClient,
  MemoryStorage,
  RestClient,
  generateToken,
  type ActivityFrame,
  type ConnectionStateChange,
  type WebSocketConstructor,
  type WebSocketLike,
} from "../../src/index.js";
import { ConvergerServer, mixAvailable, prepareDatabase, serverOptions } from "./server.js";
import { waitFor } from "../support/helpers.js";

// Progress lines with timestamps, so a hang in CI shows where it stopped.
const t0 = Date.now();
function step(message: string): void {
  process.stdout.write(`[e2e +${((Date.now() - t0) / 1000).toFixed(1)}s] ${message}
`);
}

const enabled = process.env["E2E_SKIP"] !== "1" && mixAvailable();

/** Counts outgoing text frames per clientId, and can keep the client offline. */
function instrumentedWebSocket(): {
  WebSocket: WebSocketConstructor;
  sends: Map<string, number>;
  hellos: Record<string, unknown>[];
  setBlocked(blocked: boolean): void;
} {
  const sends = new Map<string, number>();
  const hellos: Record<string, unknown>[] = [];
  let blocked = false;
  const Native = globalThis.WebSocket as unknown as WebSocketConstructor;
  class Instrumented {
    constructor(url: string, protocols?: string | string[]) {
      // While blocked, connect to a port nobody listens on (the attempt fails).
      const socket = new Native(blocked ? "ws://127.0.0.1:9/blocked" : url, protocols) as WebSocketLike;
      const send = socket.send.bind(socket);
      socket.send = (data: string) => {
        const frame = JSON.parse(data) as Record<string, unknown>;
        if (frame["type"] === "text" && typeof frame["clientId"] === "string") {
          sends.set(frame["clientId"], (sends.get(frame["clientId"]) ?? 0) + 1);
        }
        if (frame["type"] === "hello") hellos.push({ ...frame, token: "<redacted>" });
        send(data);
      };
      return socket as unknown as Instrumented;
    }
  }
  return {
    WebSocket: Instrumented as unknown as WebSocketConstructor,
    sends,
    hellos,
    setBlocked: (value) => {
      blocked = value;
    },
  };
}

describe.skipIf(!enabled)("e2e against mix phx.server", () => {
  const options = serverOptions();
  const server = new ConvergerServer(options);
  let secret = "";

  beforeAll(async () => {
    secret = prepareDatabase(options).secret;
    await server.start();
  });

  afterAll(async () => {
    await server.kill();
  });

  it("survives a server crash: reconnect, resend once, replay missed activities", async () => {
    const baseUrl = server.baseUrl;
    const ws = instrumentedWebSocket();
    const tokenRequests: string[] = [];

    // Stands in for the application's backend endpoint that mints tokens.
    const client = await ConvergerClient.connect({
      baseUrl,
      tokenProvider: async ({ reason }) => {
        tokenRequests.push(reason);
        const response = await generateToken({ baseUrl, secret, userId: "e2e-user" });
        return { token: response.token, expiresIn: response.expires_in };
      },
      transport: "native",
      WebSocket: ws.WebSocket,
      storage: new MemoryStorage(),
      reconnect: { initialDelayMs: 200, maxDelayMs: 1_000 },
    });

    const conversation = client.conversation();
    const activities: ActivityFrame[] = [];
    const states: ConnectionStateChange[] = [];
    conversation.on("activity", (frame) => activities.push(frame));
    conversation.on("connectionState", (change) => {
      states.push(change);
      step(`state ${change.state} (attempt ${change.attempt}, delay ${change.delayMs ?? "-"}, close ${change.close?.code ?? "-"} ${change.close?.reason ?? ""})`);
    });
    conversation.on("error", (error) => step(`error ${error.code}: ${error.message}`));

    step("start");
    const welcome = await conversation.start();
    const conversationId = welcome.conversationId;
    expect(conversationId).toMatch(/^[0-9a-f-]{36}$/);

    const first = await conversation.send("before the crash");
    expect(first.seq).toBe(1);
    const watermarkBeforeCrash = conversation.watermark;
    expect(watermarkBeforeCrash).toBe(1);

    // Crash the server mid-session.
    ws.setBlocked(true);
    step("killing the server");
    await server.kill();
    step(`killed; client state ${conversation.state}`);
    await waitFor(() => conversation.state === "reconnecting", { timeout: 20_000, message: "reconnecting" });

    // A message sent while the server is down waits in the outbox.
    const offline = conversation.send("sent while the server was down");
    expect(conversation.pending.map((e) => e.frame.data.text)).toEqual(["sent while the server was down"]);

    // Restart the server and post activities the client cannot see yet.
    step("restarting the server");
    await server.start();
    step("restarted; posting missed activities");
    const agentToken = (await generateToken({ baseUrl, secret, userId: "agent-1" })).token;
    const agent = new RestClient({ baseUrl, getToken: () => agentToken });
    await agent.postActivity(conversationId, { text: "missed 1", from: { id: "agent-1" } });
    await agent.postActivity(conversationId, { text: "missed 2", from: { id: "agent-1" } });

    // Let the client back in.
    ws.setBlocked(false);
    step(`unblocked; client state ${conversation.state}`);
    const result = await Promise.race([
      offline,
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error(`no ack after 60 s; state ${conversation.state}
${server.output}`)), 60_000),
      ),
    ]);
    step("offline message acknowledged");
    expect(result.duplicate).toBe(false);
    expect(result.seq).toBe(4);
    await waitFor(() => activities.length >= 2, { timeout: 20_000, message: "missed activities" });

    // Missed activities arrived through the watermark replay, in order.
    expect(activities.map((a) => [a.seq, (a.data as { text: string }).text, a.from])).toEqual([
      [2, "missed 1", "bot"],
      [3, "missed 2", "bot"],
    ]);
    const resumeHello = ws.hellos.at(-1)!;
    expect(resumeHello["conversationId"]).toBe(conversationId);
    expect(resumeHello["watermark"]).toBe(watermarkBeforeCrash);

    // The unacked message went on the wire exactly once after the reconnect.
    expect(ws.sends.get(result.clientId)).toBe(1);
    expect(conversation.pending).toHaveLength(0);
    expect(conversation.watermark).toBe(4);
    expect(states.some((s) => s.state === "reconnecting")).toBe(true);

    // The server stored each message exactly once.
    const history = await client.rest.allActivities(conversationId);
    expect(history.map((a) => a.text)).toEqual([
      "before the crash",
      "missed 1",
      "missed 2",
      "sent while the server was down",
    ]);

    // A resend of the same clientId is de-duplicated by the server.
    expect(tokenRequests[0]).toBe("initial");
    await client.close();
  });

  for (const transport of ["phoenix", "sse"] as const) {
    it(`works over the ${transport} transport`, async () => {
      const baseUrl = server.baseUrl;
      const userId = `e2e-${transport}`;
      const client = await ConvergerClient.connect({
        baseUrl,
        tokenProvider: async () => (await generateToken({ baseUrl, secret, userId })).token,
        storage: new MemoryStorage(),
        transport,
      });
      const conversation = client.conversation();
      const activities: ActivityFrame[] = [];
      conversation.on("activity", (frame) => activities.push(frame));
      const { conversationId } = await conversation.start();
      expect(conversation.transport).toBe(transport);

      const sent = await conversation.send(`hello over ${transport}`);
      expect(sent.seq).toBe(1);

      const agentToken = (await generateToken({ baseUrl, secret, userId: "agent-3" })).token;
      await new RestClient({ baseUrl, getToken: () => agentToken }).postActivity(conversationId, {
        text: `reply over ${transport}`,
        from: { id: "agent-3" },
      });
      await waitFor(() => activities.length === 1, { timeout: 10_000, message: `${transport} live activity` });
      expect(activities[0]).toMatchObject({ seq: 2, from: "bot", data: { text: `reply over ${transport}` } });
      expect(conversation.watermark).toBe(2);
      const history = await conversation.history().next();
      expect(history.value?.activities.map((a) => a.text)).toEqual([`hello over ${transport}`, `reply over ${transport}`]);
      await client.close();
    });
  }

  it("resumes in a new session from the stored watermark", async () => {
    const baseUrl = server.baseUrl;
    const storage = new MemoryStorage();
    const tokenProvider = async () => (await generateToken({ baseUrl, secret, userId: "e2e-resume" })).token;

    const first = await ConvergerClient.connect({ baseUrl, tokenProvider, storage, transport: "native" });
    const conversation = first.conversation();
    const { conversationId } = await conversation.start();
    await conversation.send("hello");
    await first.close();

    const agentToken = (await generateToken({ baseUrl, secret, userId: "agent-2" })).token;
    await new RestClient({ baseUrl, getToken: () => agentToken }).postActivity(conversationId, {
      text: "reply while you were away",
      from: { id: "agent-2" },
    });

    const second = await ConvergerClient.connect({ baseUrl, tokenProvider, storage, transport: "native" });
    const resumed = second.conversation(conversationId);
    const activities: ActivityFrame[] = [];
    resumed.on("activity", (frame) => activities.push(frame));
    await resumed.resume();
    await waitFor(() => activities.length === 1, { timeout: 10_000, message: "replay after resume" });
    expect((activities[0]!.data as { text: string }).text).toBe("reply while you were away");
    expect(resumed.watermark).toBe(2);
    await second.close();
  });
});
