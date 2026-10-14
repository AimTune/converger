/**
 * `@converger/agent/testing`: an in-process fake of the Converger native
 * endpoint for channel-scoped agents, so agent code can be unit-tested
 * without a server.
 *
 * It speaks the wire protocol of Protocol v1 section 10: `hello`/`welcome`,
 * `{conversationId, frame}` envelopes, a transcript with `seq` per
 * conversation, acks with `clientId` de-duplication, replay from
 * `hello.watermarks` and `sync`, and the end user's `resume` and `abort`.
 * It needs the `ws` package (a dev dependency of your tests).
 *
 * ```ts
 * import { createAgent } from "@converger/agent";
 * import { FakeConvergerServer } from "@converger/agent/testing";
 *
 * const server = await FakeConvergerServer.start();
 * const agent = createAgent({ url: server.url, token: "test" });
 * agent.onTurn(async (turn, reply) => { await reply.text(`echo: ${turn.text}`); });
 * await agent.start();
 * const result = await server.turn("conv-1", "hi");
 * // result.texts == ["echo: hi"]
 * await agent.stop();
 * await server.stop();
 * ```
 *
 * @module
 */

import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";

/** Any JSON object. */
export type FakeFrame = Record<string, unknown>;

/** A frame an agent sent, with the conversation of its envelope (none for bare frames). */
export interface ReceivedFrame {
  conversationId: string | undefined;
  frame: FakeFrame;
  /** Index of the connection it arrived on (0-based, in connection order). */
  connection: number;
}

/** What an agent did in answer to one user turn ({@link FakeConvergerServer.turn}). */
export interface TurnResult {
  /** Every frame the agent sent for the conversation during the turn. */
  frames: FakeFrame[];
  /** Message frames (`text`, `buttons`, ...). */
  messages: FakeFrame[];
  /** `data.text` of every `text` message. */
  texts: string[];
  /** `tool_call` data, in order (one entry per update). */
  toolCalls: FakeFrame[];
  /** The joined content of `genui` text chunks. */
  streamed: string;
  /** `interrupt` frames. */
  interrupts: FakeFrame[];
  /** The last `run` status. */
  status: string | undefined;
}

/** A connected agent. */
export interface FakeConnection {
  readonly index: number;
  readonly socket: WebSocket;
  hello: FakeFrame | undefined;
}

const NATIVE = new Set(["tool_call", "skill", "genui", "interrupt", "interrupt_resolved"]);
const TRANSIENT = new Set(["run", "genui_components", "skills", "error", "typing", "read", "sync"]);

/** A fake channel-scoped Converger endpoint. */
export class FakeConvergerServer {
  readonly wss: WebSocketServer;
  readonly channelId = "fake-channel";
  /** Every frame received from agents. */
  readonly received: ReceivedFrame[] = [];
  /** Live connections. */
  readonly connections: FakeConnection[] = [];
  /** Every `hello` received, in order. */
  readonly hellos: FakeFrame[] = [];
  /** Tokens to refuse with `unauthorized` and close 4401. */
  readonly rejectedTokens = new Set<string>();
  /** Answer the next agent message sends with these errors instead of storing them (FIFO). */
  readonly sendErrors: FakeFrame[] = [];
  /** Do not answer message sends with an ack (a lost ack). */
  swallowAcks = false;
  /** `welcome.data.expiresAt`; undefined omits it. */
  expiresAt: number | undefined = Date.now() + 1_800_000;
  readonly #transcripts = new Map<string, FakeFrame[]>();
  readonly #keys = new Map<string, FakeFrame>();
  readonly #listeners = new Set<() => void>();
  #connectionCount = 0;
  #nextId = 1;

  private constructor(wss: WebSocketServer) {
    this.wss = wss;
    wss.on("connection", (socket) => this.#onConnection(socket));
  }

  /** Start on a random local port. */
  static async start(options: { port?: number } = {}): Promise<FakeConvergerServer> {
    const wss = new WebSocketServer({
      port: options.port ?? 0,
      handleProtocols: (protocols) => (protocols.has("converger.v1") ? "converger.v1" : false),
    });
    await new Promise<void>((resolve) => wss.once("listening", () => resolve()));
    return new FakeConvergerServer(wss);
  }

  /** `http://127.0.0.1:PORT`, for `createAgent({url})`. */
  get url(): string {
    return `http://127.0.0.1:${(this.wss.address() as AddressInfo).port}`;
  }

  /** Number of connections accepted so far. */
  get connectionCount(): number {
    return this.#connectionCount;
  }

  /** The stored frames of a conversation, as the agent sees them. */
  transcript(conversationId: string): FakeFrame[] {
    return [...(this.#transcripts.get(conversationId) ?? [])];
  }

  /** Frames received from agents for a conversation (optionally of one type). */
  framesFor(conversationId: string, type?: string): FakeFrame[] {
    return this.received
      .filter((r) => r.conversationId === conversationId && (type === undefined || r.frame["type"] === type))
      .map((r) => r.frame);
  }

  /**
   * An end-user turn: stored with the next seq and delivered to every agent.
   * `message` is the text, or a whole message frame (`{type, data, metadata?, meta?, replyTo?}`).
   */
  userSays(conversationId: string, message: string | FakeFrame, options: { deliver?: boolean; sender?: string } = {}): FakeFrame {
    const base: FakeFrame = typeof message === "string" ? { type: "text", data: { text: message } } : { ...message };
    const frame: FakeFrame = {
      id: `act-${this.#nextId++}`,
      from: "user",
      sender: { id: options.sender ?? "user-1", role: "user" },
      timestamp: Date.now(),
      ...base,
    };
    const meta = frame["meta"];
    delete frame["meta"];
    const stored = this.#store(conversationId, frame);
    if (options.deliver !== false) this.deliver(conversationId, meta === undefined ? stored : { ...stored, meta });
    return stored;
  }

  /** Store a frame from another bot or agent (`from: "bot"`) and deliver it. */
  botSays(conversationId: string, text: string): FakeFrame {
    const stored = this.#store(conversationId, {
      type: "text",
      id: `act-${this.#nextId++}`,
      from: "bot",
      sender: { id: "other-bot", role: "bot" },
      data: { text },
      timestamp: Date.now(),
    });
    this.deliver(conversationId, stored);
    return stored;
  }

  /** The end user answers interrupts (`resume {answers}`), as the hub forwards it. */
  resume(conversationId: string, answers: Record<string, unknown>): void {
    this.deliver(conversationId, { type: "resume", answers });
  }

  /** The end user aborts the current run. */
  abort(conversationId: string): void {
    this.deliver(conversationId, { type: "abort" });
  }

  /** Send an enveloped frame to every connected agent. */
  deliver(conversationId: string, frame: FakeFrame): void {
    for (const c of this.connections) this.#send(c.socket, { conversationId, frame });
  }

  /** Send a bare frame to every connected agent. */
  broadcast(frame: FakeFrame): void {
    for (const c of this.connections) this.#send(c.socket, frame);
  }

  /** Wait until `predicate` holds (checked after every received frame, and every 10 ms). */
  waitFor<T>(predicate: () => T | undefined | false, timeoutMs = 5_000): Promise<T> {
    return new Promise((resolve, reject) => {
      const check = (): boolean => {
        const value = predicate();
        if (value !== undefined && value !== false) {
          cleanup();
          resolve(value);
          return true;
        }
        return false;
      };
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`FakeConvergerServer.waitFor timed out after ${timeoutMs} ms`));
      }, timeoutMs);
      const poll = setInterval(() => check(), 10);
      const cleanup = () => {
        clearTimeout(timer);
        clearInterval(poll);
        this.#listeners.delete(listener);
      };
      const listener = () => {
        check();
      };
      if (check()) return;
      this.#listeners.add(listener);
    });
  }

  /** Wait for the next agent frame matching `predicate` after now. */
  nextFrame(predicate: (r: ReceivedFrame) => boolean, timeoutMs = 5_000): Promise<ReceivedFrame> {
    const from = this.received.length;
    return this.waitFor(() => this.received.slice(from).find(predicate), timeoutMs);
  }

  /** Wait until at least `count` agents are connected and welcomed. */
  waitForConnections(count = 1, timeoutMs = 5_000): Promise<number> {
    return this.waitFor(() => (this.connections.filter((c) => c.hello).length >= count ? this.connections.length : undefined), timeoutMs);
  }

  /**
   * A user turn, then wait until the agent's run for it ends (`run finished`,
   * `error`, `aborted` or `interrupted`) and summarise what it sent.
   */
  async turn(conversationId: string, message: string | FakeFrame, options: { timeoutMs?: number; until?: string[] } = {}): Promise<TurnResult> {
    const from = this.received.length;
    this.userSays(conversationId, message);
    return this.collect(conversationId, from, options);
  }

  /** Summarise what the agent sent for a conversation since `received[from]`, once its run ends. */
  async collect(conversationId: string, from: number, options: { timeoutMs?: number; until?: string[] } = {}): Promise<TurnResult> {
    const until = new Set(options.until ?? ["finished", "error", "aborted", "interrupted"]);
    const ended = () =>
      this.received
        .slice(from)
        .some((r) => r.conversationId === conversationId && r.frame["type"] === "run" && until.has(String((r.frame["data"] as FakeFrame | undefined)?.["status"])));
    await this.waitFor(() => ended() || undefined, options.timeoutMs ?? 5_000);
    // Let acks of the last sends settle.
    await new Promise((resolve) => setTimeout(resolve, 10));
    return summarise(this.received.slice(from).filter((r) => r.conversationId === conversationId).map((r) => r.frame));
  }

  /** Close every connection with a close code (e.g. 1012 draining). */
  closeAll(code: number, reason = ""): void {
    for (const c of this.connections.splice(0)) c.socket.close(code, reason);
  }

  /** Drop every connection without a close frame (a crashed server). */
  kill(): void {
    for (const c of this.connections.splice(0)) c.socket.terminate();
  }

  async stop(): Promise<void> {
    for (const c of this.connections.splice(0)) c.socket.terminate();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
  }

  #store(conversationId: string, frame: FakeFrame): FakeFrame {
    let transcript = this.#transcripts.get(conversationId);
    if (!transcript) {
      transcript = [];
      this.#transcripts.set(conversationId, transcript);
    }
    const stored = { ...frame, seq: transcript.length + 1 };
    transcript.push(stored);
    return stored;
  }

  #send(socket: WebSocket, message: unknown): void {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
  }

  #onConnection(socket: WebSocket): void {
    this.#connectionCount += 1;
    const connection: FakeConnection = { index: this.#connectionCount - 1, socket, hello: undefined };
    this.connections.push(connection);
    socket.on("close", () => {
      const i = this.connections.indexOf(connection);
      if (i >= 0) this.connections.splice(i, 1);
    });
    socket.on("message", (raw) => {
      let message: FakeFrame;
      try {
        message = JSON.parse(String(raw)) as FakeFrame;
      } catch {
        return;
      }
      this.#onMessage(connection, message);
      for (const listener of [...this.#listeners]) listener();
    });
  }

  #onMessage(connection: FakeConnection, message: FakeFrame): void {
    const { socket } = connection;
    if (typeof message["type"] === "string") {
      this.received.push({ conversationId: undefined, frame: message, connection: connection.index });
      switch (message["type"]) {
        case "hello": {
          this.hellos.push(message);
          const token = message["token"];
          if (typeof token !== "string" || this.rejectedTokens.has(token)) {
            this.#send(socket, { type: "error", data: { code: "unauthorized", message: "invalid token", number: 2000, retryable: false } });
            socket.close(4401, "unauthorized");
            return;
          }
          connection.hello = message;
          const data: FakeFrame = {
            protocol: "converger/1",
            compat: ["mekik/1"],
            connectionId: `conn-${connection.index}`,
            scope: "channel",
            channelId: this.channelId,
            limits: { maxConversations: 5000, idleTimeoutMs: 60000 },
          };
          if (this.expiresAt !== undefined) data["expiresAt"] = this.expiresAt;
          this.#send(socket, { type: "welcome", data });
          const watermarks = (message["watermarks"] ?? {}) as Record<string, number>;
          for (const [id, watermark] of Object.entries(watermarks)) this.#replay(socket, id, watermark);
          return;
        }
        case "ping":
          this.#send(socket, { type: "heartbeat", timestamp: Date.now(), nonce: message["nonce"] });
          return;
        case "auth":
          this.#send(socket, { type: "tokenRefreshed", data: { expiresAt: Date.now() + 1_800_000 } });
          return;
        default:
          this.#send(socket, { type: "error", data: { code: "bad_request", message: "conversation frames need an envelope", number: 1000, retryable: false } });
          return;
      }
    }
    const conversationId = message["conversationId"];
    const frame = message["frame"] as FakeFrame | undefined;
    if (typeof conversationId !== "string" || !frame || typeof frame["type"] !== "string") return;
    this.received.push({ conversationId, frame, connection: connection.index });
    const type = frame["type"];
    if (type === "sync") {
      this.#replay(socket, conversationId, Number(frame["watermark"] ?? 0));
      return;
    }
    if (TRANSIENT.has(type)) return;
    if (NATIVE.has(type)) {
      const { seq: _ignored, ...rest } = frame;
      this.#store(conversationId, rest);
      return;
    }
    // A message frame: the agent's reply, acked when it has a clientId (or an id).
    const clientId = typeof frame["clientId"] === "string" ? frame["clientId"] : typeof frame["id"] === "string" ? frame["id"] : undefined;
    const error = this.sendErrors.shift();
    if (error) {
      this.#send(socket, { conversationId, frame: { type: "error", data: { ...error, clientId, frameType: type } } });
      return;
    }
    const key = clientId === undefined ? undefined : `${conversationId}:${clientId}`;
    const existing = key === undefined ? undefined : this.#keys.get(key);
    let stored: FakeFrame;
    if (existing) {
      stored = existing;
    } else {
      const { clientId: _c, ...rest } = frame;
      stored = this.#store(conversationId, {
        ...rest,
        id: typeof frame["id"] === "string" ? frame["id"] : `act-${this.#nextId++}`,
        from: "bot",
        sender: { id: "agent", role: "bot" },
        timestamp: Date.now(),
      });
      if (key !== undefined) this.#keys.set(key, stored);
    }
    if (clientId !== undefined && !this.swallowAcks) {
      const ack: FakeFrame = { type: "ack", clientId, id: stored["id"], seq: stored["seq"], timestamp: Date.now() };
      if (existing) ack["duplicate"] = true;
      this.#send(socket, { conversationId, frame: ack });
    }
  }

  #replay(socket: WebSocket, conversationId: string, watermark: number): void {
    for (const frame of this.#transcripts.get(conversationId) ?? []) {
      if ((frame["seq"] as number) > watermark) this.#send(socket, { conversationId, frame });
    }
  }
}

/** Summarise agent frames (see {@link TurnResult}). */
export function summarise(frames: FakeFrame[]): TurnResult {
  const messages = frames.filter((f) => !NATIVE.has(String(f["type"])) && !TRANSIENT.has(String(f["type"])) && typeof f["data"] === "object");
  const texts = messages.filter((f) => f["type"] === "text").map((f) => String((f["data"] as FakeFrame)["text"]));
  const toolCalls = frames.filter((f) => f["type"] === "tool_call").map((f) => f["data"] as FakeFrame);
  const streamed = frames
    .filter((f) => f["type"] === "genui" && (f["chunk"] as FakeFrame | undefined)?.["type"] === "text")
    .map((f) => String((f["chunk"] as FakeFrame)["content"]))
    .join("");
  const interrupts = frames.filter((f) => f["type"] === "interrupt");
  const runs = frames.filter((f) => f["type"] === "run");
  const last = runs[runs.length - 1];
  const status = last ? String((last["data"] as FakeFrame)["status"]) : undefined;
  return { frames, messages, texts, toolCalls, streamed, interrupts, status };
}
