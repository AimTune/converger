/**
 * A small in-process imitation of the native Protocol v1 endpoint
 * (`/socket/converger/v1`), enough to drive the client through handshakes,
 * replays, acks with clientId de-duplication, crashes and close codes.
 */
import { WebSocketServer, type WebSocket } from "ws";
import type { AddressInfo } from "node:net";

export interface StoredActivity {
  id: string;
  seq: number;
  sender: string;
  text: string;
  key?: string;
  clientId?: string;
}

export interface MockConnection {
  socket: WebSocket;
  userId: string;
  hello: Record<string, unknown> | undefined;
  received: Record<string, unknown>[];
  own: Set<number>;
  lastSeq: number;
}

export function fakeToken(claims: Record<string, unknown> = {}): string {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${enc({ alg: "HS256", typ: "JWT" })}.${enc({ type: "converger", exp: Math.floor(Date.now() / 1000) + 1800, ...claims })}.sig`;
}

export class MockServer {
  readonly wss: WebSocketServer;
  readonly conversationId = "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70";
  readonly log: StoredActivity[] = [];
  readonly connections: MockConnection[] = [];
  readonly frames: Record<string, unknown>[] = [];
  /** Refuse connections (simulates a dead server). */
  down = false;
  /** Do not answer `text` frames with an ack (simulates a crash after commit). */
  swallowAcks = false;
  /** Do not persist `text` frames at all (simulates a crash before commit). */
  dropSends = false;
  /** Close every new connection after hello with this code (and reason). */
  rejectHello: { code: number; reason: string; error?: string } | undefined;
  /** Answer the next text frames with this error instead of storing them. */
  sendErrors: Record<string, unknown>[] = [];
  expiresAt = Date.now() + 1_800_000;
  connectionCount = 0;
  #nextId = 1;

  private constructor(wss: WebSocketServer) {
    this.wss = wss;
    wss.on("connection", (socket, request) => this.#onConnection(socket, request.url ?? ""));
  }

  static async start(): Promise<MockServer> {
    const wss = new WebSocketServer({ port: 0, handleProtocols: (protocols) => (protocols.has("converger.v1") ? "converger.v1" : false) });
    await new Promise<void>((resolve) => wss.once("listening", () => resolve()));
    return new MockServer(wss);
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${(this.wss.address() as AddressInfo).port}`;
  }

  get head(): number {
    return this.log.length;
  }

  /** Frames of a type the server received, across connections. */
  received(type: string): Record<string, unknown>[] {
    return this.frames.filter((f) => f["type"] === type);
  }

  /** Append an activity from someone else and push it to every live connection. */
  inject(text: string, sender = "agent-7"): StoredActivity {
    const activity = this.#store({ sender, text });
    for (const c of this.connections) this.#deliver(c, activity);
    return activity;
  }

  /** Append an activity without pushing it (a lost PubSub message). */
  injectSilently(text: string, sender = "agent-7"): StoredActivity {
    return this.#store({ sender, text });
  }

  /** Drop every connection abruptly (no close frame), like a killed server. */
  kill(): void {
    for (const c of this.connections.splice(0)) c.socket.terminate();
  }

  closeAll(code: number, reason = ""): void {
    for (const c of this.connections.splice(0)) c.socket.close(code, reason);
  }

  send(frame: Record<string, unknown>): void {
    for (const c of this.connections) c.socket.send(JSON.stringify(frame));
  }

  async stop(): Promise<void> {
    for (const c of this.connections.splice(0)) c.socket.terminate();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
  }

  #store(attrs: { sender: string; text: string; key?: string; clientId?: string }): StoredActivity {
    const activity: StoredActivity = { id: `a-${this.#nextId++}`, seq: this.log.length + 1, ...attrs };
    this.log.push(activity);
    return activity;
  }

  #frame(activity: StoredActivity, userId: string): Record<string, unknown> {
    const own = activity.sender === userId;
    const frame: Record<string, unknown> = {
      type: "text",
      id: activity.id,
      seq: activity.seq,
      from: own ? "user" : "bot",
      sender: { id: activity.sender, role: own ? "user" : "bot" },
      data: { text: activity.text },
      timestamp: Date.now(),
    };
    if (own && activity.clientId) frame["clientId"] = activity.clientId;
    return frame;
  }

  #deliver(c: MockConnection, activity: StoredActivity): void {
    if (activity.seq <= c.lastSeq) return;
    c.lastSeq = activity.seq;
    if (c.own.has(activity.seq)) return; // echo rule
    c.socket.send(JSON.stringify(this.#frame(activity, c.userId)));
  }

  #onConnection(socket: WebSocket, _url: string): void {
    if (this.down) {
      socket.terminate();
      return;
    }
    this.connectionCount += 1;
    const c: MockConnection = { socket, userId: "", hello: undefined, received: [], own: new Set(), lastSeq: 0 };
    socket.on("message", (raw) => {
      const frame = JSON.parse(String(raw)) as Record<string, unknown>;
      c.received.push(frame);
      this.frames.push(frame);
      this.#handle(c, frame);
    });
    socket.on("close", () => {
      const index = this.connections.indexOf(c);
      if (index !== -1) this.connections.splice(index, 1);
    });
  }

  #handle(c: MockConnection, frame: Record<string, unknown>): void {
    const send = (f: Record<string, unknown>) => c.socket.send(JSON.stringify(f));
    switch (frame["type"]) {
      case "hello": {
        if (this.rejectHello) {
          if (this.rejectHello.error) send({ type: "error", data: { code: this.rejectHello.error, message: this.rejectHello.error } });
          c.socket.close(this.rejectHello.code, this.rejectHello.reason);
          return;
        }
        c.hello = frame;
        c.userId = typeof frame["userId"] === "string" ? frame["userId"] : `user-${this.connectionCount}`;
        this.connections.push(c);
        const watermark = typeof frame["watermark"] === "number" ? frame["watermark"] : 0;
        send({
          type: "welcome",
          data: {
            protocol: "converger/1",
            compat: ["mekik/1"],
            scope: "conversation",
            conversationId: this.conversationId,
            userId: c.userId,
            connectionId: `conn-${this.connectionCount}`,
            watermark: this.head,
            pending: [],
            expiresAt: this.expiresAt,
            capabilities: { acks: true, receipts: true, presence: true, typing: true, regenerate: false, edit: false },
            limits: { maxFrameBytes: 131072, maxTextBytes: 65536, maxMetadataBytes: 16384, maxInFlight: 32, heartbeatIntervalMs: 30000, idleTimeoutMs: 60000, replayBatch: 100, replayMax: 10000 },
          },
        });
        if (watermark > this.head) {
          send({ type: "error", data: { code: "invalid_watermark", message: "above head", retryable: false } });
          c.lastSeq = this.head;
          return;
        }
        c.lastSeq = watermark;
        for (const a of this.log) this.#deliver(c, a);
        return;
      }
      case "text": {
        const clientId = frame["clientId"] as string | undefined;
        const error = this.sendErrors.shift();
        if (error) {
          send({ type: "error", data: { ...error, clientId, frameType: "text" } });
          return;
        }
        if (this.dropSends) return;
        const key = clientId ? `ws:${c.userId}:${clientId}` : undefined;
        const existing = key ? this.log.find((a) => a.key === key) : undefined;
        if (existing) {
          send({ type: "ack", clientId, id: existing.id, seq: existing.seq, duplicate: true });
          return;
        }
        const data = frame["data"] as { text: string };
        const stored: { sender: string; text: string; key?: string; clientId?: string } = { sender: c.userId, text: data.text };
        if (key) stored.key = key;
        if (clientId) stored.clientId = clientId;
        const activity = this.#store(stored);
        c.own.add(activity.seq);
        if (clientId && !this.swallowAcks) send({ type: "ack", clientId, id: activity.id, seq: activity.seq, timestamp: Date.now() });
        for (const other of this.connections) this.#deliver(other, activity);
        return;
      }
      case "sync": {
        const watermark = frame["watermark"] as number;
        for (const a of this.log) if (a.seq > watermark && !c.own.has(a.seq)) send(this.#frame(a, c.userId));
        c.lastSeq = Math.max(c.lastSeq, this.head);
        return;
      }
      case "ping":
        send({ type: "heartbeat", timestamp: Date.now(), nonce: frame["nonce"], headSeq: this.head });
        return;
      case "auth":
        this.expiresAt = Date.now() + 1_800_000;
        send({ type: "tokenRefreshed", data: { expiresAt: this.expiresAt } });
        return;
      default:
        return;
    }
  }
}
