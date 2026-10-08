// Chaos verification (no dependencies). Reads from $OUT_DIR:
//   driver.json        messages the driver sent / got acked
//   activities.csv     id,conversation_id,seq,idempotency_key,text  (Postgres)
//   conversations.csv  id,last_seq                                  (Postgres)
//   deliveries.csv     activity_id,status,attempts                  (Postgres)
//   sink.jsonl         every request the webhook sink received
// Writes $OUT_DIR/report.json and exits non-zero when any check fails.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const OUT_DIR = process.env.OUT_DIR || "/out";
const read = (f) => fs.readFileSync(path.join(OUT_DIR, f), "utf8");

// Values never contain commas or quotes (uuids, keys, "chaos <key>", ints).
const csv = (f, cols) =>
  read(f)
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => {
      const parts = l.split(",");
      return Object.fromEntries(cols.map((c, i) => [c, parts[i] === undefined ? "" : parts[i]]));
    });

const driver = JSON.parse(read("driver.json"));
const activities = csv("activities.csv", ["id", "conversation_id", "seq", "idempotency_key", "text"]);
const conversations = csv("conversations.csv", ["id", "last_seq"]);
const deliveries = csv("deliveries.csv", ["activity_id", "status", "attempts"]);
const sink = read("sink.jsonl")
  .split("\n")
  .filter((l) => l.trim() !== "")
  .map((l) => JSON.parse(l));

// --- persistence: every acked message exactly once ---------------------------
const byText = new Map();
for (const a of activities) {
  if (!byText.has(a.text)) byText.set(a.text, []);
  byText.get(a.text).push(a);
}

const acked = driver.messages.filter((m) => m.acked);
const lost = [];
const duplicated = [];
const idMismatch = [];
for (const m of driver.messages) {
  const rows = byText.get(m.text) || [];
  if (m.acked && rows.length === 0) lost.push(m);
  if (rows.length > 1) duplicated.push({ key: m.key, kind: m.kind, copies: rows.length, acked: m.acked });
  if (m.acked && m.activity_id && rows.length === 1 && rows[0].id !== m.activity_id) idMismatch.push(m.key);
}
const unackedPersisted = driver.messages.filter((m) => !m.acked && (byText.get(m.text) || []).length > 0);
const knownTexts = new Set(driver.messages.map((m) => m.text));
const unknownActivities = activities.filter((a) => !knownTexts.has(a.text));

// --- ordering: gap-free seq per conversation --------------------------------
const seqs = new Map();
for (const a of activities) {
  if (!seqs.has(a.conversation_id)) seqs.set(a.conversation_id, []);
  seqs.get(a.conversation_id).push(Number(a.seq));
}
const seqProblems = [];
for (const c of conversations) {
  const list = (seqs.get(c.id) || []).sort((x, y) => x - y);
  const gapFree = list.every((s, i) => s === i + 1);
  if (!gapFree || list.length !== Number(c.last_seq)) {
    seqProblems.push({ conversation_id: c.id, count: list.length, last_seq: Number(c.last_seq), gap_free: gapFree });
  }
}

// --- delivery: every acked message reached the webhook sink ------------------
const deliveryByActivity = new Map(deliveries.map((d) => [d.activity_id, d]));
const sinkActivities = new Set(sink.map((r) => r.activity_id));
const sinkDeliveryIds = new Set(sink.map((r) => r.delivery_id));
const persistedAcked = acked
  .map((m) => (byText.get(m.text) || [])[0])
  .filter(Boolean);
const SENT = new Set(["sent", "delivered", "read"]);
const notSent = persistedAcked.filter((a) => !SENT.has((deliveryByActivity.get(a.id) || {}).status));
const notAtSink = persistedAcked.filter((a) => !sinkActivities.has(a.id));
const deliveredAcked = persistedAcked.length - notAtSink.length;

const byKind = {};
for (const kind of ["rest", "ws"]) {
  const ms = driver.messages.filter((m) => m.kind === kind);
  const ackedK = ms.filter((m) => m.acked);
  byKind[kind] = {
    sent: ms.length,
    acked: ackedK.length,
    persisted: ackedK.filter((m) => (byText.get(m.text) || []).length > 0).length,
    delivered: ackedK.filter((m) => {
      const row = (byText.get(m.text) || [])[0];
      return row && sinkActivities.has(row.id);
    }).length,
    lost: lost.filter((m) => m.kind === kind).length,
    duplicates: duplicated.filter((d) => d.kind === kind).length,
  };
}

const report = {
  sent: driver.messages.length,
  acked: acked.length,
  never_acked: driver.messages.length - acked.length,
  rejected: driver.messages.filter((m) => m.rejected).length,
  retried: driver.messages.filter((m) => m.attempts > 1).length,
  persisted_acked: persistedAcked.length,
  persisted_total: activities.length,
  unacked_but_persisted: unackedPersisted.length,
  lost: lost.length,
  duplicates: duplicated.length,
  ack_id_mismatch: idMismatch.length,
  unknown_activities: unknownActivities.length,
  conversations: conversations.length,
  seq_problems: seqProblems.length,
  delivered_acked: deliveredAcked,
  deliveries_not_sent: notSent.length,
  not_at_sink: notAtSink.length,
  sink_requests: sink.length,
  sink_unique_deliveries: sinkDeliveryIds.size,
  sink_redeliveries: sink.length - sinkDeliveryIds.size,
  by_kind: byKind,
  // Delivery jobs that ran more than once: rescued by Lifeline after a kill
  // (or retried after an error).
  delivery_jobs_retried: fs.existsSync(path.join(OUT_DIR, "oban_jobs.csv"))
    ? csv("oban_jobs.csv", ["state", "attempt", "count"])
        .filter((r) => Number(r.attempt) > 1)
        .reduce((n, r) => n + Number(r.count), 0)
    : null,
  timing: fs.existsSync(path.join(OUT_DIR, "timing.json")) ? JSON.parse(read("timing.json")) : null,
  driver_stats: driver.summary.stats,
  samples: {
    lost: lost.slice(0, 10).map((m) => m.key),
    duplicated: duplicated.slice(0, 10),
    seq_problems: seqProblems.slice(0, 10),
    not_sent: notSent.slice(0, 10).map((a) => ({ id: a.id, delivery: deliveryByActivity.get(a.id) || null })),
    not_at_sink: notAtSink.slice(0, 10).map((a) => a.id),
  },
};

fs.writeFileSync(path.join(OUT_DIR, "report.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));

const failures = [];
if (report.acked === 0) failures.push("nothing was acked");
if (report.lost > 0) failures.push(`${report.lost} acked messages lost`);
if (report.duplicates > 0) failures.push(`${report.duplicates} messages persisted more than once`);
if (report.ack_id_mismatch > 0) failures.push(`${report.ack_id_mismatch} acks returned a different activity id`);
if (report.unknown_activities > 0) failures.push(`${report.unknown_activities} unexpected activities`);
if (report.seq_problems > 0) failures.push(`${report.seq_problems} conversations with seq gaps`);
if (report.deliveries_not_sent > 0) failures.push(`${report.deliveries_not_sent} acked messages not marked sent`);
if (report.not_at_sink > 0) failures.push(`${report.not_at_sink} acked messages never reached the sink`);

if (failures.length > 0) {
  console.error("CHAOS FAILED: " + failures.join("; "));
  process.exit(1);
}
console.log("CHAOS PASSED: zero acked messages lost, no duplicates, gap-free seq, all delivered");
