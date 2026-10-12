// Turns one load/run.sh run into results.json and report.md (no
// dependencies, Node >= 22).
//
//   node load/results.js <out dir>
//
// Inputs in <out dir>: run.json, hardware.json, db.json, setup.json,
// <scenario>.json (k6 handleSummary), marks.csv, exit_codes.csv,
// restarts.csv, samples.csv, mock_stats.json.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { render } = require("./report.js");

const dir = process.argv[2] || "/out";
const read = (name, fallback) => {
  const file = path.join(dir, name);
  if (!fs.existsSync(file)) return fallback;
  const text = fs.readFileSync(file, "utf8");
  return name.endsWith(".json") ? JSON.parse(text) : text;
};
const lines = (name) =>
  read(name, "")
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "")
    .map((l) => l.split(";"));

const round = (x, d = 1) => (x === null || x === undefined || Number.isNaN(x) ? null : Number(x.toFixed(d)));
const metric = (k6, name, stat) => (k6 && k6.metrics[name] ? k6.metrics[name][stat] : undefined);
const count = (k6, name) => metric(k6, name, "count") || 0;

// --- inputs ------------------------------------------------------------------
const run = read("run.json", {});
const hardware = read("hardware.json", {});
const db = read("db.json", {});
const setup = read("setup.json", {});
const mock = read("mock_stats.json", { paths: {} });

const marks = {};
for (const [scenario, kind, ts] of lines("marks.csv")) {
  marks[scenario] = marks[scenario] || {};
  marks[scenario][kind] = Number(ts);
}
const exitCodes = Object.fromEntries(lines("exit_codes.csv").map(([s, c]) => [s, Number(c)]));
const restarts = lines("restarts.csv").map(([scenario, node, ms]) => ({ scenario, node, ms: Number(ms) }));

// samples.csv: "<ts>;stats;<container>;<cpu %>;<used> / <limit>",
// "<ts>;oban;<open jobs>", "<ts>;queue;<node>;<metric line>".
const bytes = (s) => {
  const m = /([\d.]+)\s*([KMGT]?i?B)/.exec(s || "");
  if (!m) return null;
  const unit = { B: 1, KiB: 1024, MiB: 1024 ** 2, GiB: 1024 ** 3, TiB: 1024 ** 4, kB: 1e3, KB: 1e3, MB: 1e6, GB: 1e9 }[m[2]];
  return Number(m[1]) * (unit || 1);
};
const samples = { stats: [], oban: [], queue: [] };
for (const row of lines("samples.csv")) {
  const ts = Number(row[0]);
  if (row[1] === "stats") {
    const node = row[2].replace(/^.*-(app\d?|db)-\d+$/, "$1");
    samples.stats.push({ ts, node, cpu: parseFloat(row[3]), rss: bytes(row[4]) });
  } else if (row[1] === "oban" && row[2] !== "") {
    samples.oban.push({ ts, depth: Number(row[2]) });
  } else if (row[1] === "queue") {
    const value = parseFloat(row[3].trim().split(/\s+/).pop());
    if (!Number.isNaN(value)) samples.queue.push({ ts, node: row[2], ms: value });
  }
}

function resources(window) {
  if (!window) return null;
  const inWindow = (s) => s.ts >= window.from && s.ts <= window.to;
  const nodes = {};
  for (const s of samples.stats.filter(inWindow)) {
    const n = (nodes[s.node] = nodes[s.node] || { cpu: [], rss: [] });
    if (!Number.isNaN(s.cpu)) n.cpu.push(s.cpu);
    if (s.rss !== null) n.rss.push(s.rss);
  }
  const perNode = {};
  for (const [node, n] of Object.entries(nodes)) {
    perNode[node] = {
      cpu_avg_pct: round(n.cpu.reduce((a, b) => a + b, 0) / (n.cpu.length || 1)),
      cpu_max_pct: round(Math.max(0, ...n.cpu)),
      rss_max_mib: round(Math.max(0, ...n.rss) / 1024 ** 2),
    };
  }
  const oban = samples.oban.filter(inWindow).map((s) => s.depth);
  const queue = samples.queue.filter(inWindow).map((s) => s.ms);
  return {
    nodes: perNode,
    oban_depth_max: oban.length ? Math.max(...oban) : null,
    db_pool_wait_max_ms: queue.length ? round(Math.max(...queue), 2) : null,
  };
}

const windowOf = (scenario, extraEnd) => {
  const m = marks[scenario];
  if (!m || !m.start) return null;
  return { from: m.start, to: (extraEnd && m[extraEnd]) || m.end || Date.now() };
};

// Highest RSS of each app node in the last samples before `ts`.
function rssBefore(ts) {
  const out = {};
  for (const s of samples.stats) {
    if (s.ts < ts && s.ts >= ts - 10_000 && s.node !== "db" && s.rss !== null) out[s.node] = s.rss;
  }
  return out;
}

// --- scenarios ------------------------------------------------------------------
const scenarios = {};
const checks = [];
const check = (name, ok, detail, warning = false) => checks.push({ name, ok, detail, warning });

// Thresholds on these metrics guard correctness (lost, duplicated or unacked
// messages, sockets that could not connect or were dropped while idle) and
// fail the run. The others are performance targets from the PRD (p95 below
// 250 ms, burst capacity): missing one is reported, and the baseline
// comparison in report.js is what gates performance.
const CORRECTNESS = new Set([
  "lost_acked_messages",
  "seq_gaps",
  "seq_duplicates",
  "messages_never_acked",
  "subscribers_unverified",
  "ws_connected",
  "ws_unexpected_closes",
]);

function base(scenario, k6) {
  const exit = exitCodes[scenario];
  const failed = Object.entries(k6.thresholds || {})
    .filter(([, ok]) => !ok)
    .map(([t]) => t);
  const broken = failed.filter((t) => CORRECTNESS.has(t.split(":")[0]));
  const missed = failed.filter((t) => !CORRECTNESS.has(t.split(":")[0]));
  // k6 exits 99 when a threshold fails; anything else non-zero is a crash.
  check(
    `${scenario}: k6 ran and correctness thresholds passed`,
    (exit === 0 || exit === 99) && broken.length === 0,
    broken.length ? broken.join(", ") : `k6 exit ${exit}`,
  );
  if (missed.length) check(`${scenario}: performance targets`, false, `missed: ${missed.join(", ")}`, true);
  return {
    params: k6.params,
    duration_s: round(k6.duration_ms / 1000),
    targets_missed: missed,
    resources: resources(windowOf(scenario, scenario === "webhook_burst" ? "drained" : null)),
  };
}

// An empty Trend passes every threshold: make sure messages were really sent
// and seen live (a rerun with reused idempotency keys sends nothing new).
function measured(scenario, k6) {
  const acked = count(k6, "messages_acked");
  const samples = metric(k6, "e2e_latency_ms", "count") || 0;
  check(`${scenario}: messages sent and received live`, acked > 0 && samples > 0, `${acked} acked, ${samples} latency samples`);
}

function lossOf(k6) {
  return {
    lost_acked_messages: count(k6, "lost_acked_messages") + count(k6, "seq_gaps"),
    seq_duplicates: count(k6, "seq_duplicates"),
    never_acked: count(k6, "messages_never_acked"),
    unverified_subscribers: count(k6, "subscribers_unverified"),
  };
}

function trend(k6, name) {
  return {
    p50: round(metric(k6, name, "med")),
    p95: round(metric(k6, name, "p(95)")),
    p99: round(metric(k6, name, "p(99)")),
    max: round(metric(k6, name, "max")),
  };
}

const e2e = read("e2e.json");
if (e2e) {
  const s = base("e2e", e2e);
  s.e2e_latency_ms = trend(e2e, "e2e_latency_ms");
  s.rest_latency_ms = trend(e2e, "http_req_duration{name:POST /activities}");
  s.messages_acked = count(e2e, "messages_acked");
  s.msgs_per_s = round(s.messages_acked / e2e.params.duration_s);
  s.frames_per_s = round((count(e2e, "frames_received") - count(e2e, "frames_replayed")) / e2e.params.duration_s);
  s.ws_connections = count(e2e, "ws_connected");
  measured("e2e", e2e);
  Object.assign(s, lossOf(e2e));
  scenarios.e2e = s;
}

const burst = read("webhook_burst.json");
if (burst) {
  const s = base("webhook_burst", burst);
  const targets = (setup.targets || []).map((t) => t.path);
  const targetStats = targets.map((p) => mock.paths[p] || { delivered: 0, latency_ms: {} });
  const delivered = targetStats.reduce((a, t) => a + t.delivered, 0);
  const expected = (db.burst_activities || 0) * targets.length;
  // Latency over every target: the slowest target's percentiles.
  const worst = (k) => round(Math.max(0, ...targetStats.map((t) => t.latency_ms[k] || 0)));
  s.inbound_accepted = count(burst, "inbound_accepted");
  s.inbound_rejected = count(burst, "inbound_rejected");
  s.inbound_per_s = round(s.inbound_accepted / burst.params.duration_s);
  s.inbound_latency_ms = trend(burst, "http_req_duration{name:POST /inbound}");
  s.stored = db.burst_activities;
  s.deliveries_expected = expected;
  s.deliveries_delivered = delivered;
  s.delivery_latency_ms = { p50: worst("p50"), p95: worst("p95"), p99: worst("p99"), max: worst("max") };
  const m = marks.webhook_burst || {};
  s.drain_after_burst_s = m.drained && m.end ? round((m.drained - m.end) / 1000) : null;
  s.deliveries_per_s = m.drained && m.start ? round(delivered / ((m.drained - m.start) / 1000)) : null;
  s.lost_acked_messages = Math.max(0, s.inbound_accepted - (s.stored || 0)) + Math.max(0, expected - delivered);
  check(
    "webhook_burst: every accepted message stored and delivered to every target",
    s.lost_acked_messages === 0,
    `accepted ${s.inbound_accepted}, stored ${s.stored}, delivered ${delivered}/${expected}`,
  );
  scenarios.webhook_burst = s;
}

const idle = read("idle.json");
if (idle) {
  const s = base("idle", idle);
  s.sockets = idle.params.sockets;
  s.ws_connections = count(idle, "ws_connected");
  s.ws_connect_ms = trend(idle, "ws_connect_ms");
  s.unexpected_closes = count(idle, "ws_unexpected_closes");
  const m = marks.idle || {};
  const before = rssBefore(m.start || 0);
  let delta = 0;
  for (const [node, r] of Object.entries((s.resources && s.resources.nodes) || {})) {
    if (node !== "db" && before[node] !== undefined) delta += r.rss_max_mib * 1024 ** 2 - before[node];
  }
  s.rss_growth_mib = round(delta / 1024 ** 2);
  s.kib_per_socket = s.ws_connections ? round(delta / 1024 / s.sockets) : null;
  scenarios.idle = s;
}

for (const name of ["reconnect_storm", "rolling_restart", "node_kill"]) {
  const k6 = read(`${name}.json`);
  if (!k6) continue;
  const s = base(name, k6);
  s.e2e_latency_ms = trend(k6, "e2e_latency_ms");
  s.ws_reconnect_ms = trend(k6, "ws_reconnect_ms");
  s.reconnects = count(k6, "ws_reconnects");
  s.messages_acked = count(k6, "messages_acked");
  s.send_retries = count(k6, "send_retries");
  const r = restarts.filter((x) => x.scenario === name);
  if (r.length) {
    s.node_recovery_s = Object.fromEntries(r.map((x) => [x.node, round(x.ms / 1000)]));
    s.recovery_max_s = round(Math.max(...r.map((x) => x.ms)) / 1000);
  }
  measured(name, k6);
  Object.assign(s, lossOf(k6));
  scenarios[name] = s;
}

for (const [name, s] of Object.entries(scenarios)) {
  if (s.lost_acked_messages !== undefined && name !== "webhook_burst") {
    check(`${name}: zero lost acked messages`, s.lost_acked_messages === 0 && !s.never_acked, `lost ${s.lost_acked_messages}, never acked ${s.never_acked || 0}`);
  }
}

// Every REST activity on the fan-out channel reached the mock provider once.
if (mock.paths.fanout || db.fanout_activities) {
  const delivered = (mock.paths.fanout || {}).delivered || 0;
  check(
    "fan-out channel: every activity delivered to the outbound webhook",
    delivered >= db.fanout_activities,
    `${delivered}/${db.fanout_activities} delivered, ${db.open_delivery_jobs} jobs still open`,
  );
}

const results = {
  run,
  hardware: { ...hardware, postgres_version: db.postgres_version, database_size_bytes: db.database_size_bytes },
  mock: mock.config,
  scenarios,
  checks,
  ok: checks.every((c) => c.ok || c.warning),
};

fs.writeFileSync(path.join(dir, "results.json"), JSON.stringify(results, null, 2));
fs.writeFileSync(path.join(dir, "report.md"), render([results]).markdown);
