// Chaos load driver (no dependencies, Node >= 22: global fetch and WebSocket).
//
// Sends activities concurrently over
//   * REST: POST /api/v1/conversations/:id/activities with the tenant API key
//     and an `x-idempotency-key` header, and
//   * WebSocket: the Converger socket /socket/converger/websocket, channel
//     `converger:conversation:<id>`, event `postActivity` with a `clientId`,
// while run.sh kills and restarts the app container. Every message keeps its
// idempotency key across retries; a message counts as ACKED only when the
// server answered REST 2xx / WS phx_reply "ok". Unacked messages are retried
// (same key) until acked or until the drain timeout.
//
// The message text is "chaos <key>", so verify.js can count copies of a
// message in Postgres even if the server ignored the idempotency key.
//
// Input:  $OUT_DIR/setup.json (from setup.exs). Output: $OUT_DIR/driver.json.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const OUT_DIR = process.env.OUT_DIR || "/out";
const BASE_URL = process.env.APP_URL || "http://app:4000";
const WS_URL = BASE_URL.replace(/^http/, "ws") + "/socket/converger/websocket";
const DURATION_MS = Number(process.env.CHAOS_DURATION_S || 60) * 1000;
const DRAIN_MS = Number(process.env.CHAOS_DRAIN_S || 180) * 1000;
const REST_WORKERS = Number(process.env.CHAOS_REST_WORKERS_PER_CONVERSATION || 2);
const WS_WINDOW = Number(process.env.CHAOS_WS_WINDOW || 4);
const PAUSE_MS = Number(process.env.CHAOS_PAUSE_MS || 20);
const REQUEST_TIMEOUT_MS = 5000;
const WS_PUSH_TIMEOUT_MS = 10000;

const setup = JSON.parse(fs.readFileSync(path.join(OUT_DIR, "setup.json"), "utf8"));

const startedAt = Date.now();
const sendUntil = startedAt + DURATION_MS;
const drainUntil = sendUntil + DRAIN_MS;

const messages = [];
const stats = {
  rest_attempts: 0,
  rest_errors: 0,
  rest_rejected: 0,
  ws_pushes: 0,
  ws_connects: 0,
  ws_disconnects: 0,
  ws_timeouts: 0,
  ws_rejected: 0,
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now();
const log = (...args) =>
  console.log(`[driver +${((now() - startedAt) / 1000).toFixed(1)}s]`, ...args);

function newMessage(kind, conversationId, key) {
  const msg = {
    key,
    kind,
    conversation_id: conversationId,
    text: `chaos ${key}`,
    acked: false,
    activity_id: null,
    attempts: 0,
    rejected: null,
  };
  messages.push(msg);
  return msg;
}

// ---------------------------------------------------------------- REST

async function restSend(msg) {
  let backoff = 100;
  while (!msg.acked && now() < drainUntil) {
    msg.attempts += 1;
    stats.rest_attempts += 1;
    try {
      const res = await fetch(`${BASE_URL}/api/v1/conversations/${msg.conversation_id}/activities`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": setup.api_key,
          "x-idempotency-key": msg.key,
        },
        body: JSON.stringify({ type: "message", text: msg.text, sender: "chaos-rest" }),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      const body = await res.text();
      if (res.status >= 200 && res.status < 300) {
        const json = JSON.parse(body);
        msg.acked = true;
        msg.activity_id = (json.data && json.data.id) || json.id || null;
        return;
      }
      if (res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429) {
        // Permanent rejection: never acked, so never retried.
        stats.rest_rejected += 1;
        msg.rejected = `${res.status} ${body.slice(0, 200)}`;
        return;
      }
      stats.rest_errors += 1;
    } catch (_e) {
      stats.rest_errors += 1;
    }
    await sleep(backoff);
    backoff = Math.min(backoff * 2, 1000);
  }
}

async function restWorker(conversationId, worker) {
  let n = 0;
  while (now() < sendUntil) {
    n += 1;
    const msg = newMessage("rest", conversationId, `rest-${conversationId.slice(0, 8)}-${worker}-${n}`);
    await restSend(msg);
    await sleep(PAUSE_MS);
  }
}

// ---------------------------------------------------------------- WebSocket

// One Phoenix socket (protocol 2.0.0, JSON arrays) per conversation with up to
// WS_WINDOW pushes in flight. On disconnect every in-flight push goes back to
// the pending queue and is re-pushed (same idempotency key) after rejoining.
async function wsWorker(conv) {
  const pending = []; // messages to (re)push
  let n = 0;
  let backoff = 200;

  const nextMessage = () => {
    n += 1;
    return newMessage("ws", conv.id, `ws-${conv.id.slice(0, 8)}-${n}`);
  };

  while (now() < drainUntil) {
    const sending = () => now() < sendUntil;
    if (!sending() && pending.length === 0) return;

    let ws;
    try {
      ws = await connect(`${WS_URL}?vsn=2.0.0&token=${encodeURIComponent(conv.token)}`);
    } catch (_e) {
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 1000);
      continue;
    }
    stats.ws_connects += 1;

    const result = await runSession(ws, conv, pending, nextMessage, sending);
    stats.ws_disconnects += 1;
    if (result === "done") return;
    await sleep(backoff);
    backoff = Math.min(backoff * 2, 1000);
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const timer = setTimeout(() => {
      try {
        ws.close();
      } catch (_e) {}
      reject(new Error("connect timeout"));
    }, REQUEST_TIMEOUT_MS);
    ws.onopen = () => {
      clearTimeout(timer);
      resolve(ws);
    };
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error("connect error"));
    };
  });
}

function runSession(ws, conv, pending, nextMessage, sending) {
  return new Promise((resolve) => {
    const topic = `converger:conversation:${conv.id}`;
    const joinRef = "1";
    let ref = 1;
    let joined = false;
    let finished = false;
    const inflight = new Map(); // ref -> {msg, timer}

    const send = (arr) => ws.send(JSON.stringify(arr));

    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearInterval(heartbeat);
      clearInterval(pump);
      for (const { msg, timer } of inflight.values()) {
        clearTimeout(timer);
        if (!msg.acked) pending.unshift(msg);
      }
      inflight.clear();
      try {
        ws.close();
      } catch (_e) {}
      resolve(result);
    };

    const push = (msg) => {
      ref += 1;
      const r = String(ref);
      msg.attempts += 1;
      stats.ws_pushes += 1;
      const timer = setTimeout(() => {
        // No reply in time: treat the connection as broken and resend later.
        stats.ws_timeouts += 1;
        finish("retry");
      }, WS_PUSH_TIMEOUT_MS);
      inflight.set(r, { msg, timer });
      send([joinRef, r, topic, "postActivity", { type: "message", text: msg.text, clientId: msg.key }]);
    };

    const fill = () => {
      if (!joined || finished) return;
      while (inflight.size < WS_WINDOW) {
        if (pending.length > 0) push(pending.shift());
        else if (sending()) push(nextMessage());
        else break;
      }
      if (inflight.size === 0 && pending.length === 0 && !sending()) finish("done");
      if (now() > drainUntil) finish("done");
    };

    const heartbeat = setInterval(() => {
      ref += 1;
      try {
        send([null, String(ref), "phoenix", "heartbeat", {}]);
      } catch (_e) {}
    }, 15000);
    const pump = setInterval(fill, PAUSE_MS);

    ws.onmessage = (event) => {
      let frame;
      try {
        frame = JSON.parse(event.data);
      } catch (_e) {
        return;
      }
      const [, msgRef, msgTopic, msgEvent, payload] = frame;
      if (msgTopic !== topic) return;

      if (msgEvent === "phx_reply" && msgRef === joinRef) {
        if (payload.status === "ok") {
          joined = true;
          fill();
        } else {
          log(`ws join rejected for ${conv.id}:`, JSON.stringify(payload.response));
          finish("retry");
        }
        return;
      }

      if (msgEvent === "phx_reply" && inflight.has(msgRef)) {
        const { msg, timer } = inflight.get(msgRef);
        clearTimeout(timer);
        inflight.delete(msgRef);
        if (payload.status === "ok") {
          msg.acked = true;
          msg.activity_id = (payload.response && payload.response.id) || null;
        } else {
          stats.ws_rejected += 1;
          msg.rejected = JSON.stringify(payload.response);
        }
        fill();
        return;
      }

      if (msgEvent === "phx_error" || msgEvent === "phx_close") finish("retry");
    };

    ws.onclose = () => finish("retry");
    ws.onerror = () => finish("retry");

    send([joinRef, joinRef, topic, "phx_join", {}]);
  });
}

// ---------------------------------------------------------------- main

async function main() {
  log(
    `REST conversations=${setup.rest_conversations.length} x ${REST_WORKERS} workers, ` +
      `WS conversations=${setup.ws_conversations.length} (window ${WS_WINDOW}), ` +
      `send ${DURATION_MS / 1000}s, drain <= ${DRAIN_MS / 1000}s`,
  );

  const progress = setInterval(() => {
    const acked = messages.filter((m) => m.acked).length;
    log(`messages=${messages.length} acked=${acked} unacked=${messages.length - acked}`);
  }, 5000);

  const workers = [];
  for (const id of setup.rest_conversations) {
    for (let w = 1; w <= REST_WORKERS; w++) workers.push(restWorker(id, w));
  }
  for (const conv of setup.ws_conversations) workers.push(wsWorker(conv));
  await Promise.all(workers);
  clearInterval(progress);

  const summary = {
    sent: messages.length,
    acked: messages.filter((m) => m.acked).length,
    rejected: messages.filter((m) => m.rejected).length,
    never_acked: messages.filter((m) => !m.acked).length,
    retried: messages.filter((m) => m.attempts > 1).length,
    by_kind: {},
    stats,
  };
  for (const kind of ["rest", "ws"]) {
    const ms = messages.filter((m) => m.kind === kind);
    summary.by_kind[kind] = {
      sent: ms.length,
      acked: ms.filter((m) => m.acked).length,
      retried: ms.filter((m) => m.attempts > 1).length,
    };
  }

  fs.writeFileSync(path.join(OUT_DIR, "driver.json"), JSON.stringify({ summary, messages }));
  log("done", JSON.stringify(summary));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
