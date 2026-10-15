// Scenario "dead_channel": a healthy tenant's delivery latency while another
// tenant's channel is dead (epic #59, ADR-0031).
//
// One VU per conversation of the healthy tenant (load/isolation_setup.exs).
// Each VU POSTs RATE activities per second over the tenant REST API for
// DURATION_S seconds. Every activity is delivered to the healthy tenant's
// outbound webhook channel on the mock provider, which measures send ->
// delivery latency per message (GET /samples/healthy). load/run.sh runs this
// script twice, back to back: PHASE=baseline (nothing else going on) and
// PHASE=dead (while the other tenant's channel, which never answers, has a
// backlog of LOAD_DEAD_BACKLOG deliveries in the same queue). The comparison
// is in load/results.js.
//
// Environment: CONVERSATIONS (all in the fixtures), RATE (1 msg/s per
// conversation), DURATION_S (90), PHASE (baseline | dead), plus
// lib/converger.js (SETUP_JSON points at isolation.json).
import { RUN_ID, TREND_STATS, fixtures, num, postActivity, sleepMs } from "./lib/converger.js";
import { summary } from "./lib/summary.js";

const CONVERSATIONS = Math.min(num("CONVERSATIONS", fixtures.conversations.length), fixtures.conversations.length);
const RATE = num("RATE", 1);
const DURATION_S = num("DURATION_S", 90);
const PHASE = __ENV.PHASE || "baseline";

export const options = {
  summaryTrendStats: TREND_STATS,
  scenarios: {
    send: {
      executor: "per-vu-iterations",
      vus: CONVERSATIONS,
      iterations: 1,
      maxDuration: `${DURATION_S + 120}s`,
    },
  },
  thresholds: {
    messages_never_acked: ["count<1"],
  },
};

export default async function () {
  const index = __VU - 1;
  const conversation = fixtures.conversations[index];
  const interval = 1000 / RATE;
  await sleepMs(Math.random() * interval);

  const stopAt = Date.now() + DURATION_S * 1000;
  let n = 0;
  while (Date.now() < stopAt) {
    const started = Date.now();
    n += 1;
    await postActivity({
      start: index,
      apiKey: fixtures.api_key,
      conversationId: conversation.id,
      key: `iso-${PHASE}-${RUN_ID}-${conversation.id.slice(0, 8)}-${n}`,
      deadline: stopAt + 30_000,
    });
    await sleepMs(Math.max(0, interval - (Date.now() - started)));
  }
}

export const handleSummary = summary(`dead_channel_${PHASE}`, () => ({
  phase: PHASE,
  conversations: CONVERSATIONS,
  rate_per_conversation: RATE,
  duration_s: DURATION_S,
}));
