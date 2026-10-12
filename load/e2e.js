// Scenario "e2e": REST -> WebSocket fan-out latency.
//
// One VU per conversation. Each VU opens SUBSCRIBERS Protocol v1 sockets on
// its conversation, then POSTs RATE activities per second over the tenant REST
// API for DURATION_S seconds. Every subscriber measures send -> text frame
// latency (e2e_latency_ms) and checks that it ends up with every seq up to the
// head (lost_acked_messages), each delivered once (seq_duplicates).
//
//   k6 run -e SETUP_JSON=load/.run/out/setup.json -e APP_URLS=http://localhost:4000 load/e2e.js
//
// Environment: CONVERSATIONS (all in setup.json), SUBSCRIBERS (all tokens per
// conversation), RATE (1 msg/s per conversation), DURATION_S (60),
// DRAIN_S (5), E2E_P95_MS (250, threshold), plus lib/converger.js.
import { RUN_ID, TREND_STATS, fixtures, num, postActivity, sleepMs, Subscriber, WS_URLS } from "./lib/converger.js";
import { summary } from "./lib/summary.js";

const CONVERSATIONS = Math.min(num("CONVERSATIONS", fixtures.conversations.length), fixtures.conversations.length);
const SUBSCRIBERS = num("SUBSCRIBERS", fixtures.conversations[0].tokens.length);
const RATE = num("RATE", 1);
const DURATION_S = num("DURATION_S", 60);
const DRAIN_S = num("DRAIN_S", 5);

export const options = {
  summaryTrendStats: TREND_STATS,
  scenarios: {
    e2e: {
      executor: "per-vu-iterations",
      vus: CONVERSATIONS,
      iterations: 1,
      maxDuration: `${DURATION_S + DRAIN_S + 120}s`,
    },
  },
  thresholds: {
    e2e_latency_ms: [`p(95)<${num("E2E_P95_MS", 250)}`],
    lost_acked_messages: ["count<1"],
    seq_duplicates: ["count<1"],
    messages_never_acked: ["count<1"],
    "http_req_duration{name:POST /activities}": [`p(95)<${num("REST_P95_MS", 1000)}`],
  },
};

export default async function () {
  const index = __VU - 1;
  const conversation = fixtures.conversations[index];

  const subscribers = conversation.tokens.slice(0, SUBSCRIBERS).map(
    (token, j) => new Subscriber({ urls: WS_URLS, start: index * SUBSCRIBERS + j, token, label: `${index}-${j}` }),
  );
  subscribers.forEach((s) => s.start());

  // Start sending once every subscriber is in (or after 15 s regardless).
  const joinDeadline = Date.now() + 15_000;
  while (Date.now() < joinDeadline && subscribers.some((s) => !s.welcomed)) await sleepMs(50);

  // Spread the conversations' first sends over one interval.
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
      key: `e2e-${RUN_ID}-${conversation.id.slice(0, 8)}-${n}`,
      deadline: stopAt + 30_000,
    });
    await sleepMs(Math.max(0, interval - (Date.now() - started)));
  }

  await sleepMs(DRAIN_S * 1000);
  await Promise.all(subscribers.map((s) => s.finish()));
}

export const handleSummary = summary("e2e", () => ({
  conversations: CONVERSATIONS,
  subscribers_per_conversation: SUBSCRIBERS,
  sockets: CONVERSATIONS * SUBSCRIBERS,
  rate_per_conversation: RATE,
  duration_s: DURATION_S,
}));
