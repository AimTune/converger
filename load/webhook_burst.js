// Scenario "webhook_burst": inbound webhook burst -> multi-channel delivery.
//
// POSTs signed generic inbound webhooks (x-converger-signature) to the
// fixtures' duplex ingress channel at BURST_RATE requests per second for
// BURST_S seconds, from PARTICIPANTS external users (one conversation each).
// A routing rule fans every message out to the target channels, which
// deliver to load/mock_provider. The mock provider measures send -> delivery
// latency; load/run.sh waits for the outbox to drain and load/report.js
// compares accepted messages with what was stored and delivered.
//
// Environment: BURST_RATE (500/s), BURST_S (30), PARTICIPANTS (200),
// MAX_VUS (500), plus lib/converger.js.
import http from "k6/http";
import crypto from "k6/crypto";
import exec from "k6/execution";
import { Counter } from "k6/metrics";
import { RUN_ID, TREND_STATS, appUrl, fixtures, loadText, num } from "./lib/converger.js";
import { summary } from "./lib/summary.js";

const BURST_RATE = num("BURST_RATE", 500);
const BURST_S = num("BURST_S", 30);
const PARTICIPANTS = num("PARTICIPANTS", 200);

const accepted = new Counter("inbound_accepted");
const rejected = new Counter("inbound_rejected");

export const options = {
  summaryTrendStats: TREND_STATS,
  scenarios: {
    burst: {
      executor: "constant-arrival-rate",
      rate: BURST_RATE,
      timeUnit: "1s",
      duration: `${BURST_S}s`,
      // Enough VUs for up to ~1 s per request without initialising new ones
      // mid-burst (which drops iterations).
      preAllocatedVUs: Math.min(num("MAX_VUS", 500), Math.max(20, BURST_RATE)),
      maxVUs: num("MAX_VUS", 500),
    },
  },
  thresholds: {
    inbound_rejected: ["count<1"],
    dropped_iterations: ["count<1"],
    "http_req_duration{name:POST /inbound}": ["p(95)<500"],
  },
};

export default function () {
  const n = exec.scenario.iterationInTest;
  const key = `burst-${RUN_ID}-${n}`;
  const body = JSON.stringify({
    sender: "load",
    text: loadText(key),
    external_id: `participant-${n % PARTICIPANTS}`,
    idempotency_key: key,
  });
  const t = Math.floor(Date.now() / 1000);
  const signature = crypto.hmac("sha256", fixtures.ingress.secret, `${t}.${body}`, "hex");

  const res = http.post(`${appUrl(n)}/api/v1/channels/${fixtures.ingress.id}/inbound`, body, {
    headers: { "content-type": "application/json", "x-converger-signature": `t=${t},v1=${signature}` },
    tags: { name: "POST /inbound" },
    timeout: "10s",
  });

  if (res.status >= 200 && res.status < 300) accepted.add(1);
  else {
    rejected.add(1);
    if (n % 100 === 0) console.error(`inbound ${res.status}: ${String(res.body).slice(0, 200)}`);
  }
}

export const handleSummary = summary("webhook_burst", () => ({
  rate: BURST_RATE,
  duration_s: BURST_S,
  participants: PARTICIPANTS,
  targets: fixtures.targets.length,
}));
