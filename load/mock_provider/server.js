// Mock provider for the load harness (no dependencies, Node >= 22).
//
// Stands in for the endpoints Converger delivers to (generic webhooks, and the
// provider APIs behind WhatsApp and friends). Every channel of the load
// fixtures points at POST /hook/<path>.
//
//   * Answers after MOCK_LATENCY_MS (+ up to MOCK_JITTER_MS) milliseconds.
//   * Fails a MOCK_ERROR_RATE fraction (0..1) of requests with 500, which
//     Converger retries; a delivery counts once it got a 2xx.
//   * Measures delivery latency: the load scripts send texts of the form
//     "load <sent at, unix ms> <key>", so the latency of the first successful
//     delivery of an activity is (now - sent at). Both run on the same host.
//   * Paths starting with "hang" (POST /hook/hang-...) never answer: the
//     request is held until Converger gives up (its adapter timeout). The
//     dead_channel scenario points a channel at one to model a provider that
//     accepts connections and never responds.
//
// GET  /stats  -> {"paths": {"<path>": {requests, failed, delivered, duplicates,
//                  latency_ms: {count, p50, p95, p99, max}}}, "totals": {...}}
// GET  /samples/<path> -> [[arrived at (unix ms), latency ms], ...] of every
//                  first delivery on that path, in arrival order
// POST /reset  -> clears everything
"use strict";

const http = require("node:http");

const port = Number(process.env.MOCK_PORT || 8080);
const latencyMs = Number(process.env.MOCK_LATENCY_MS || 0);
const jitterMs = Number(process.env.MOCK_JITTER_MS || 0);
const errorRate = Number(process.env.MOCK_ERROR_RATE || 0);

let paths = new Map();

function pathStats(path) {
  let s = paths.get(path);
  if (!s) {
    s = { requests: 0, failed: 0, duplicates: 0, hanging: 0, seen: new Set(), latencies: [], samples: [] };
    paths.set(path, s);
  }
  return s;
}

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, i)];
}

function summarise(s) {
  const sorted = Float64Array.from(s.latencies).sort();
  return {
    requests: s.requests,
    failed: s.failed,
    delivered: s.seen.size,
    duplicates: s.duplicates,
    hanging: s.hanging || 0,
    latency_ms: {
      count: sorted.length,
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      max: sorted.length ? sorted[sorted.length - 1] : null,
    },
  };
}

function stats() {
  const out = { config: { latencyMs, jitterMs, errorRate }, paths: {} };
  const all = { requests: 0, failed: 0, duplicates: 0, seen: new Set(), latencies: [] };
  for (const [path, s] of paths) {
    out.paths[path] = summarise(s);
    all.requests += s.requests;
    all.failed += s.failed;
    all.duplicates += s.duplicates;
    for (const id of s.seen) all.seen.add(`${path}/${id}`);
    for (const l of s.latencies) all.latencies.push(l);
  }
  out.totals = summarise(all);
  return out;
}

function json(res, code, body) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/stats") return json(res, 200, stats());
  const samples = req.method === "GET" && /^\/samples\/([A-Za-z0-9_-]+)$/.exec(req.url);
  if (samples) return json(res, 200, (paths.get(samples[1]) || { samples: [] }).samples);
  if (req.method === "POST" && req.url === "/reset") {
    paths = new Map();
    return json(res, 200, {});
  }

  const match = req.method === "POST" && /^\/hook\/([A-Za-z0-9_-]+)$/.exec(req.url);
  if (!match) {
    res.writeHead(404);
    res.end();
    return;
  }

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const s = pathStats(match[1]);
    s.requests += 1;

    // A provider that never answers: hold the request until the client
    // closes it.
    if (match[1].startsWith("hang")) {
      s.hanging += 1;
      res.on("close", () => (s.hanging -= 1));
      return;
    }

    const fail = errorRate > 0 && Math.random() < errorRate;
    const delay = latencyMs + (jitterMs > 0 ? Math.random() * jitterMs : 0);

    const answer = () => {
      if (fail) {
        s.failed += 1;
        return json(res, 500, { error: "mock failure" });
      }

      let body = {};
      try {
        body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch (_e) {}

      const id = body.id || req.headers["x-converger-delivery-id"];
      if (id && s.seen.has(id)) {
        s.duplicates += 1;
      } else if (id) {
        s.seen.add(id);
        // Channel deliveries carry the text; platform event webhooks (the
        // backbone check of #66) carry the activity under `data`.
        const text = body.text || (body.data && body.data.text) || "";
        const m = /^load (\d+) /.exec(text);
        if (m) {
          const now = Date.now();
          s.latencies.push(now - Number(m[1]));
          s.samples.push([now, now - Number(m[1])]);
        }
      }
      json(res, 200, {});
    };

    if (delay > 0) setTimeout(answer, delay);
    else answer();
  });
});

// Converger keeps connections alive; do not let Node's defaults cut them.
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

server.listen(port, "0.0.0.0", () => {
  console.log(`mock provider on :${port} (latency ${latencyMs}+${jitterMs} ms, error rate ${errorRate})`);
});

process.on("SIGTERM", () => server.close(() => process.exit(0)));
