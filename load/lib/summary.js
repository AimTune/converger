// handleSummary for the load scenarios: the usual end-of-test text on stdout,
// plus $OUT_DIR/<scenario>.json for load/report.js (params, every metric's
// values and whether each threshold passed).
import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";

export function summary(scenario, params) {
  return (data) => {
    const metrics = {};
    const thresholds = {};
    for (const [name, metric] of Object.entries(data.metrics)) {
      metrics[name] = metric.values;
      for (const [expr, result] of Object.entries(metric.thresholds || {})) {
        thresholds[`${name}: ${expr}`] = result.ok;
      }
    }

    const out = __ENV.OUT_DIR || "/load/.run/out";
    return {
      stdout: textSummary(data, { indent: " ", enableColors: false }),
      [`${out}/${scenario}.json`]: JSON.stringify(
        {
          scenario,
          params: params(),
          started_at: new Date(Date.now() - data.state.testRunDurationMs).toISOString(),
          duration_ms: data.state.testRunDurationMs,
          metrics,
          thresholds,
        },
        null,
        2,
      ),
    };
  };
}
