// Scenarios "reconnect_storm" and "rolling_restart": reconnects with
// watermark replay under load, and the zero-loss check.
//
// Same traffic as e2e.js (SUBSCRIBERS sockets per conversation, RATE REST
// sends per second per conversation, retried with the same idempotency key
// until acked). On top of that:
//
//   * MODE=storm: every STORM_EVERY_S seconds (first at STORM_AT_S), all
//     sockets drop their connection at once and reconnect with their last
//     seq as the watermark: a client-side reconnect storm.
//   * MODE=restart: nothing extra here; load/run.sh restarts the nodes one by
//     one meanwhile (scenario "rolling_restart") or SIGKILLs one (scenario
//     "node_kill", set with SCENARIO), and sockets reconnect to the next node.
//
// Every subscriber must end with every seq of its conversation exactly once
// (lost_acked_messages, seq_duplicates); ws_reconnect_ms is the
// close -> welcome time.
//
// CONNECT_RATE > 0 opens the sockets gradually: socket k (over the whole run)
// connects k / CONNECT_RATE seconds after the scenario starts, so 10 000
// sockets can join without turning the start into a handshake storm (#190).
// 0, the default, opens every socket at once.
//
// Environment: MODE (storm), STORM_AT_S (15), STORM_EVERY_S (15),
// CONNECT_RATE (0), plus the e2e.js variables (DURATION_S defaults to 60,
// DRAIN_S to 10).
import exec from "k6/execution";
import { RUN_ID, TREND_STATS, fixtures, num, postActivity, sleepMs, Subscriber, WS_URLS } from "./lib/converger.js";
import { summary } from "./lib/summary.js";

const MODE = __ENV.MODE || "storm";
const CONVERSATIONS = Math.min(num("CONVERSATIONS", fixtures.conversations.length), fixtures.conversations.length);
const SUBSCRIBERS = num("SUBSCRIBERS", fixtures.conversations[0].tokens.length);
const RATE = num("RATE", 1);
const DURATION_S = num("DURATION_S", 60);
const DRAIN_S = num("DRAIN_S", 10);
const STORM_AT_S = num("STORM_AT_S", 15);
const STORM_EVERY_S = num("STORM_EVERY_S", 15);
const CONNECT_RATE = num("CONNECT_RATE", 0);
const RAMP_S = CONNECT_RATE > 0 ? (CONVERSATIONS * SUBSCRIBERS) / CONNECT_RATE : 0;
const SCENARIO = __ENV.SCENARIO || (MODE === "storm" ? "reconnect_storm" : "rolling_restart");

export const options = {
  summaryTrendStats: TREND_STATS,
  scenarios: {
    [SCENARIO]: {
      executor: "per-vu-iterations",
      vus: CONVERSATIONS,
      iterations: 1,
      maxDuration: `${Math.ceil(RAMP_S + DURATION_S + DRAIN_S) + 300}s`,
    },
  },
  thresholds: {
    lost_acked_messages: ["count<1"],
    seq_duplicates: ["count<1"],
    subscribers_unverified: ["count<1"],
    messages_never_acked: ["count<1"],
  },
};

export default async function () {
  const index = __VU - 1;
  const conversation = fixtures.conversations[index];

  const subscribers = conversation.tokens
    .slice(0, SUBSCRIBERS)
    .map((token, j) => new Subscriber({ urls: WS_URLS, start: index * SUBSCRIBERS + j, token, label: `${index}-${j}` }));
  const t0 = exec.scenario.startTime;
  for (const [j, s] of subscribers.entries()) {
    if (CONNECT_RATE > 0) await sleepMs(Math.max(0, t0 + ((index * SUBSCRIBERS + j) * 1000) / CONNECT_RATE - Date.now()));
    s.start();
  }

  const joinDeadline = Date.now() + 15_000;
  while (Date.now() < joinDeadline && subscribers.some((s) => !s.welcomed)) await sleepMs(50);

  const begin = Date.now();
  const stopAt = begin + DURATION_S * 1000;

  if (MODE === "storm") {
    // Every VU computes the same wall-clock schedule from its own start, which
    // is within a second of the others: close enough to a storm.
    const storm = async (at) => {
      await sleepMs(Math.max(0, begin + at * 1000 - Date.now()));
      subscribers.forEach((s) => s.forceReconnect());
    };
    for (let at = STORM_AT_S; at < DURATION_S; at += STORM_EVERY_S) storm(at);
  }

  const interval = 1000 / RATE;
  await sleepMs(Math.random() * interval);

  let n = 0;
  while (Date.now() < stopAt) {
    const started = Date.now();
    n += 1;
    await postActivity({
      start: index,
      apiKey: fixtures.api_key,
      conversationId: conversation.id,
      key: `${SCENARIO}-${RUN_ID}-${conversation.id.slice(0, 8)}-${n}`,
      // Long enough to outlast a restarted node.
      deadline: stopAt + 120_000,
    });
    await sleepMs(Math.max(0, interval - (Date.now() - started)));
  }

  await sleepMs(DRAIN_S * 1000);
  await Promise.all(subscribers.map((s) => s.finish(60_000)));
}

export const handleSummary = summary(SCENARIO, () => ({
  mode: MODE,
  conversations: CONVERSATIONS,
  subscribers_per_conversation: SUBSCRIBERS,
  sockets: CONVERSATIONS * SUBSCRIBERS,
  connect_rate: CONNECT_RATE || null,
  rate_per_conversation: RATE,
  duration_s: DURATION_S,
  storm_at_s: MODE === "storm" ? STORM_AT_S : null,
  storm_every_s: MODE === "storm" ? STORM_EVERY_S : null,
}));
