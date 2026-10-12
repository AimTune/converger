// Scenario "idle": memory footprint of many idle WebSocket connections.
//
// Opens SOCKETS Protocol v1 connections (default 10 000), SOCKETS_PER_VU per
// VU, at CONNECT_RATE new connections per second overall, holds them for
// HOLD_S seconds (each pings every 25 s to stay under the 60 s idle timeout)
// and closes them. load/run.sh samples the nodes' RSS while they are held;
// this script reports how many connected and how long connecting took.
//
// Sockets are spread over the fixtures' idle conversations (several sockets
// share a conversation token, like one user with several tabs).
//
// Environment: SOCKETS (10000), SOCKETS_PER_VU (200), CONNECT_RATE (500/s),
// HOLD_S (60), plus lib/converger.js.
import { TREND_STATS, fixtures, num, sleepMs, Subscriber, WS_URLS } from "./lib/converger.js";
import { summary } from "./lib/summary.js";

const SOCKETS = num("SOCKETS", 10_000);
const PER_VU = num("SOCKETS_PER_VU", 200);
const CONNECT_RATE = num("CONNECT_RATE", 500);
const HOLD_S = num("HOLD_S", 60);
const VUS = Math.ceil(SOCKETS / PER_VU);
const RAMP_S = SOCKETS / CONNECT_RATE;

export const options = {
  summaryTrendStats: TREND_STATS,
  scenarios: {
    idle: {
      executor: "per-vu-iterations",
      vus: VUS,
      iterations: 1,
      maxDuration: `${Math.ceil(RAMP_S + HOLD_S) + 180}s`,
    },
  },
  thresholds: {
    // Every socket connects; none is dropped while idle.
    ws_connected: [`count>=${SOCKETS}`],
    ws_unexpected_closes: ["count<1"],
  },
};

export default async function () {
  const first = (__VU - 1) * PER_VU;
  const count = Math.min(PER_VU, SOCKETS - first);
  const conversations = fixtures.idle_conversations;
  const sockets = [];

  // Socket k connects at k / CONNECT_RATE seconds after the start.
  const t0 = Date.now();
  for (let i = 0; i < count; i++) {
    const k = first + i;
    await sleepMs(Math.max(0, t0 + (k * 1000) / CONNECT_RATE - Date.now()));
    const conversation = conversations[k % conversations.length];
    const s = new Subscriber({ urls: WS_URLS, start: k, token: conversation.tokens[0], label: `idle-${k}`, measureLatency: false });
    s.start();
    sockets.push(s);
  }

  // Hold from the moment the last socket of the whole run has been opened.
  await sleepMs(Math.max(0, t0 + RAMP_S * 1000 + HOLD_S * 1000 - Date.now()));
  sockets.forEach((s) => s.stop());
}

export const handleSummary = summary("idle", () => ({
  sockets: SOCKETS,
  sockets_per_vu: PER_VU,
  connect_rate: CONNECT_RATE,
  ramp_s: RAMP_S,
  hold_s: HOLD_S,
}));
