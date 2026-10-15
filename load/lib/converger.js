// Shared pieces of the k6 load scenarios: configuration, fixtures, metrics,
// a Protocol v1 subscriber and a REST sender. See docs/benchmarks/index.md.
//
// Environment:
//   APP_URLS    comma-separated node base URLs (default http://localhost:4000);
//               VUs and sockets are spread over them round-robin
//   SETUP_JSON  fixtures written by load/setup.exs (default /load/.run/out/setup.json)
import http from "k6/http";
import { WebSocket } from "k6/websockets";
import { Counter, Trend } from "k6/metrics";

export const APP_URLS = (__ENV.APP_URLS || "http://localhost:4000").split(",").map((u) => u.trim());
export const fixtures = JSON.parse(open(__ENV.SETUP_JSON || "/load/.run/out/setup.json"));

export const num = (name, fallback) => (__ENV[name] !== undefined ? Number(__ENV[name]) : fallback);
// Part of every idempotency key, so a second run against the same fixtures
// creates new activities instead of being answered as duplicates.
export const RUN_ID = __ENV.RUN_ID || Date.now().toString(36);
export const appUrl = (i) => APP_URLS[i % APP_URLS.length];
export const WS_URLS = APP_URLS.map((u) => u.replace(/^http/, "ws") + "/socket/converger/v1");

export const metrics = {
  // REST (or inbound) send -> text frame on a subscriber socket.
  e2e: new Trend("e2e_latency_ms", true),
  // Socket closed -> welcome on the new connection.
  reconnect: new Trend("ws_reconnect_ms", true),
  // First connect -> welcome.
  connect: new Trend("ws_connect_ms", true),
  connected: new Counter("ws_connected"),
  reconnects: new Counter("ws_reconnects"),
  unexpectedCloses: new Counter("ws_unexpected_closes"),
  connectErrors: new Counter("ws_connect_errors"),
  framesReceived: new Counter("frames_received"),
  replayed: new Counter("frames_replayed"),
  // Zero-loss accounting. Each subscriber must end up with every seq of its
  // conversation up to the head, each delivered once outside of resyncs.
  // Holes it saw and recovered with `sync` (server could not replay, #35).
  gapsResynced: new Counter("seq_gaps_resynced"),
  replayUnavailable: new Counter("replay_unavailable"),
  duplicates: new Counter("seq_duplicates"),
  lost: new Counter("lost_acked_messages"),
  unverified: new Counter("subscribers_unverified"),
  acked: new Counter("messages_acked"),
  sendRetries: new Counter("send_retries"),
  sendFailed: new Counter("messages_never_acked"),
};

// Trend statistics in the summaries (k6 omits p(99) by default).
export const TREND_STATS = ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)", "count"];

export const sleepMs = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Texts carry their send time so receivers (sockets, the mock provider) can
// measure latency: "load <unix ms> <key>".
export const loadText = (key) => `load ${Date.now()} ${key}`;
const sentAt = (text) => {
  const m = /^load (\d+) /.exec(text || "");
  return m ? Number(m[1]) : null;
};

// A Protocol v1 subscriber that resumes from its last seq on every reconnect.
//
//   const sub = new Subscriber({urls, start, token, label});
//   sub.start();        // connects, reconnects on close until stop()
//   sub.forceReconnect();
//   await sub.finish(); // pings for headSeq, records loss, closes
//
// `urls` are the nodes' socket URLs; a connection that fails or drops
// reconnects to the next one, as a client behind a load balancer would.
export class Subscriber {
  constructor({ urls, start = 0, token, label, measureLatency = true, pingEveryMs = 25_000 }) {
    this.urls = urls.map((u) => `${u}?token=${encodeURIComponent(token)}`);
    this.node = start % this.urls.length;
    this.label = label;
    this.measureLatency = measureLatency;
    this.pingEveryMs = pingEveryMs;
    this.lastSeq = 0;
    this.ws = null;
    this.stopped = false;
    this.closedAt = null;
    this.welcomed = false;
    this.headAtWelcome = 0;
    this.pending = null; // final ping
    this.nonce = 0;
    this.everConnected = false;
    this.startedAt = null;
    this.failures = 0; // consecutive failed connects, for the backoff
    this.maxSeen = 0; // highest seq received
    this.ahead = new Set(); // seqs received beyond a hole
    // The server delivers each seq once per connection (from `hello`) unless the
    // client asks for a replay with `sync`; across connections, and after a
    // sync, repeats are expected. Tracked per connection to check exactly that.
    this.connSeen = new Set();
    this.connSynced = false;
    this.syncTimer = null;
    this.pendingReplay = false; // replay_unavailable: sync even without a hole
  }

  start() {
    this.startedAt = Date.now();
    this.connect();
    this.pinger = setInterval(() => this.send({ type: "ping", nonce: `k-${++this.nonce}` }), this.pingEveryMs);
  }

  connect() {
    const ws = new WebSocket(this.urls[this.node]);
    this.ws = ws;
    this.welcomed = false;

    ws.onopen = () => {
      this.connSeen = new Set();
      this.connSynced = false;
      const hello = { type: "hello", protocol: "converger/1" };
      if (this.lastSeq > 0) hello.watermark = this.lastSeq;
      ws.send(JSON.stringify(hello));
    };

    // A replaced connection may still deliver frames while it closes; the new
    // one resumes from our position, so they are ignored.
    ws.onmessage = (event) => this.ws === ws && this.onFrame(JSON.parse(event.data));

    ws.onerror = () => {
      if (!this.welcomed) metrics.connectErrors.add(1);
      this.dropped(ws);
    };
    ws.onclose = () => this.dropped(ws);
  }

  // The connection failed or closed without stop(): reconnect to the next
  // node after a short backoff. The watermark makes it lossless.
  dropped(ws) {
    if (this.ws !== ws) return;
    this.ws = null;
    if (this.stopped) return;
    // Only a drop of an established connection is unexpected; failed connect
    // attempts are counted as ws_connect_errors.
    if (this.welcomed) metrics.unexpectedCloses.add(1);
    if (this.closedAt === null) this.closedAt = Date.now();
    this.node = (this.node + 1) % this.urls.length;
    // Exponential backoff with jitter, as real clients do: retrying every few
    // hundred ms turns an overloaded node into a reconnect storm.
    const backoff = Math.min(10_000, 250 * 2 ** this.failures);
    this.failures += 1;
    setTimeout(() => this.stopped || this.connect(), backoff / 2 + Math.random() * backoff);
  }

  forceReconnect() {
    if (!this.ws) return;
    this.closedAt = Date.now();
    const ws = this.ws;
    this.ws = null;
    ws.close();
    this.connect();
  }

  send(frame) {
    if (this.ws && this.welcomed) {
      try {
        this.ws.send(JSON.stringify(frame));
      } catch (_e) {}
    }
  }

  onFrame(frame) {
    switch (frame.type) {
      case "welcome":
        this.welcomed = true;
        this.headAtWelcome = frame.data.watermark || 0;
        metrics.connected.add(1);
        if (this.everConnected) {
          metrics.reconnects.add(1);
          if (this.closedAt !== null) metrics.reconnect.add(Date.now() - this.closedAt);
        } else {
          metrics.connect.add(Date.now() - this.startedAt);
        }
        this.everConnected = true;
        this.failures = 0;
        this.closedAt = null;
        if (this.pending) this.send({ type: "ping", nonce: "final" });
        return;

      case "heartbeat":
        if (frame.nonce === "final" && this.pending) this.pending(frame.headSeq);
        return;

      case "error": {
        // Under database pressure (#35) the server skips the replay or gap
        // fill and says so; the client syncs again later.
        const data = frame.data || {};
        if (data.code === "replay_unavailable") {
          metrics.replayUnavailable.add(1);
          this.scheduleSync(data.retryAfterMs || (data.details && data.details.retryAfterMs) || 1000);
        }
        return;
      }

      case "replayTruncated":
        // Never expected at benchmark sizes; anything missing shows up as loss.
        return;

      default:
        if (typeof frame.seq !== "number") return; // transient frames
        this.onPersistent(frame);
    }
  }

  // Persistent frames. `lastSeq` is the highest seq up to which everything was
  // received; frames beyond a hole wait in `ahead` until a sync fills it.
  onPersistent(frame) {
    const seq = frame.seq;
    metrics.framesReceived.add(1);
    if (this.connSeen.has(seq) && !this.connSynced) metrics.duplicates.add(1);
    this.connSeen.add(seq);
    if (seq <= this.lastSeq || this.ahead.has(seq)) return; // already have it

    // Live frames are new highs; anything else is replay or gap fill.
    const live = seq > this.maxSeen && seq > this.headAtWelcome;
    this.maxSeen = Math.max(this.maxSeen, seq);
    if (!live) metrics.replayed.add(1);
    else if (this.measureLatency) {
      const at = sentAt(frame.data && frame.data.text);
      if (at !== null) metrics.e2e.add(Date.now() - at);
    }

    if (seq === this.lastSeq + 1) {
      this.lastSeq = seq;
      while (this.ahead.delete(this.lastSeq + 1)) this.lastSeq += 1;
    } else {
      // A hole: the server normally fills it before pushing; if it could not
      // (replay_unavailable), ask again from the last contiguous seq.
      if (this.ahead.size === 0) metrics.gapsResynced.add(1);
      this.ahead.add(seq);
      this.scheduleSync(1000);
    }
  }

  sync() {
    this.connSynced = true;
    this.send({ type: "sync", watermark: this.lastSeq });
  }

  scheduleSync(afterMs) {
    if (this.syncTimer) return;
    this.syncTimer = setTimeout(() => {
      this.syncTimer = null;
      if (this.stopped) return;
      if (this.ahead.size === 0 && !this.pendingReplay) return;
      this.pendingReplay = false;
      this.sync();
    }, afterMs);
    if (this.ahead.size === 0) this.pendingReplay = true;
  }

  // Ask for the conversation head, sync until everything below it arrived (or
  // timeoutMs passes) and record what never did as lost.
  finish(timeoutMs = 30_000) {
    return new Promise((resolve) => {
      const deadline = Date.now() + timeoutMs;
      let head = null;
      let timer = null;
      const done = () => {
        if (this.pending === null) return;
        this.pending = null;
        // A pending timer keeps the VU's event loop (and iteration) alive.
        clearTimeout(timer);
        clearTimeout(this.syncTimer);
        if (head === null) metrics.unverified.add(1);
        else if (head > this.lastSeq) metrics.lost.add(head - this.lastSeq);
        this.stop();
        resolve();
      };
      const ask = () => {
        if (Date.now() >= deadline) return done();
        this.send({ type: "ping", nonce: "final" });
        timer = setTimeout(ask, 2000);
      };
      this.pending = (headSeq) => {
        head = headSeq;
        clearTimeout(timer);
        if (this.lastSeq >= headSeq || Date.now() >= deadline) return done();
        // Behind the head: sync from the last contiguous seq and ask again.
        this.sync();
        timer = setTimeout(ask, 2000);
      };
      ask();
    });
  }

  stop() {
    this.stopped = true;
    clearInterval(this.pinger);
    if (this.ws) {
      const ws = this.ws;
      this.ws = null;
      ws.close();
    }
  }
}

// POST an activity over the tenant REST API, retrying with the same
// idempotency key until it is acked (2xx) or `deadline` passes. Retries go
// to the next node (APP_URLS), starting at node `start`. Resolves to
// true when acked.
export async function postActivity({ start = 0, apiKey, conversationId, key, deadline }) {
  let backoff = 100;
  let attempt = 0;
  while (Date.now() < deadline) {
    attempt += 1;
    if (attempt > 1) metrics.sendRetries.add(1);
    let res;
    try {
      res = await http.asyncRequest(
        "POST",
        `${appUrl(start + attempt - 1)}/api/v1/conversations/${conversationId}/activities`,
        JSON.stringify({ type: "message", text: loadText(key), sender: "load" }),
        {
          headers: { "content-type": "application/json", "x-api-key": apiKey, "x-idempotency-key": key },
          tags: { name: "POST /activities" },
          timeout: "10s",
        },
      );
    } catch (_e) {
      res = null;
    }
    if (res && res.status >= 200 && res.status < 300) {
      metrics.acked.add(1);
      return true;
    }
    if (res && res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429) {
      console.error(`rejected ${key}: ${res.status} ${String(res.body).slice(0, 200)}`);
      break;
    }
    await sleepMs(backoff);
    backoff = Math.min(backoff * 2, 1000);
  }
  metrics.sendFailed.add(1);
  return false;
}
