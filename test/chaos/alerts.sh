#!/usr/bin/env bash
# Alert chaos test: under steady REST load, kill the webhook target and wait
# for Prometheus to fire the delivery alerts of docker/prometheus/alerts.yml
# (with shorter `for:` durations), then bring the target back and wait for the
# circuit breaker alert to resolve. See docs/chaos.md.
#
#   1. healthy: deliveries are sent, no delivery alert fires;
#   2. target killed, circuit breaker effectively off: the success rate drops
#      -> ConvergerDeliverySuccessRateLow;
#   3. breaker back to its defaults: it opens
#      -> ConvergerChannelCircuitOpen;
#   4. target back: the breaker closes and the alert resolves.
#
# Usage: test/chaos/alerts.sh         (from anywhere; needs docker compose >= 2.24)
#
# Tunables (env): CHAOS_ALERT_TIMEOUT_S (240), CHAOS_REST_CONVERSATIONS (2),
# CHAOS_APP_PORT (14100), CHAOS_PROMETHEUS_PORT (19090),
# CHAOS_PROJECT (converger-chaos-alerts), CHAOS_SKIP_BUILD (0), CHAOS_KEEP (0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# Native path for docker (C:/... under Git Bash, unchanged elsewhere).
ROOT="$(pwd -W 2>/dev/null || pwd)"

PROJECT="${CHAOS_PROJECT:-converger-chaos-alerts}"
RUN_DIR="test/chaos/.run"
OUT="$RUN_DIR/out"
ALERT_TIMEOUT_S="${CHAOS_ALERT_TIMEOUT_S:-240}"
REST_CONVERSATIONS="${CHAOS_REST_CONVERSATIONS:-2}"
export CHAOS_APP_PORT="${CHAOS_APP_PORT:-14100}"
export CHAOS_PROMETHEUS_PORT="${CHAOS_PROMETHEUS_PORT:-19090}"
# Steady, moderate load for the whole run; the driver is stopped at the end.
export CHAOS_DURATION_S=3600 CHAOS_DRAIN_S=1 CHAOS_REST_WORKERS_PER_CONVERSATION=1 CHAOS_PAUSE_MS=50
PROM="http://127.0.0.1:$CHAOS_PROMETHEUS_PORT"

log() { echo "[alerts $(date +%H:%M:%S)] $*"; }

dc() {
  MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" --project-directory "$ROOT" --env-file "$RUN_DIR/.env" \
    -f docker-compose.yml -f test/chaos/docker-compose.chaos.yml -f test/chaos/docker-compose.alerts.yml \
    --profile chaos-driver "$@"
}

rpc() { dc exec -T app bin/converger rpc "$1"; }

rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }

DRIVER_PID=""
cleanup() {
  local code=$?
  [ -n "$DRIVER_PID" ] && kill "$DRIVER_PID" 2>/dev/null || true
  if [ -f "$RUN_DIR/.env" ]; then
    dc logs --no-color app >"$OUT/app.log" 2>&1 || true
    curl -s "$PROM/api/v1/alerts" >"$OUT/alerts.json" 2>/dev/null || true
    if [ "${CHAOS_KEEP:-0}" != "1" ]; then
      log "tearing down (set CHAOS_KEEP=1 to keep the stack)"
      dc down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  exit "$code"
}
trap cleanup EXIT

wait_ready() {
  local deadline=$((SECONDS + ${1:-180}))
  until code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CHAOS_APP_PORT/api/v1/conversations") &&
    [ "$code" = "401" ] || [ "$code" = "403" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "app did not become ready"
      return 1
    fi
    sleep 1
  done
}

# Prints the number of series an instant PromQL query returns.
series() {
  curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$1" | grep -o '"metric":' | wc -l | tr -d ' '
}

firing() { [ "$(series "ALERTS{alertname=\"$1\",alertstate=\"firing\"}")" != "0" ]; }

# wait_for <description> <timeout_s> <command...>
wait_for() {
  local what=$1 timeout=$2 start=$SECONDS
  shift 2
  until "$@"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      log "FAIL: $what not seen after ${timeout}s"
      return 1
    fi
    sleep 5
  done
  log "ok: $what after $((SECONDS - start))s"
  echo "\"$what\": $((SECONDS - start))," >>"$OUT/timings.txt"
}

not_firing() { ! firing "$1"; }
has_series() { [ "$(series "$1")" != "0" ]; }

# --- throwaway secrets, Prometheus config (test/chaos/.run is gitignored) ----
rm -rf "$OUT" "$RUN_DIR/prometheus"
mkdir -p "$OUT" "$RUN_DIR/prometheus"
chmod 777 "$OUT" 2>/dev/null || true
umask 077
cat >"$RUN_DIR/.env" <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 24)
SECRET_KEY_BASE=$(rand_b64 64)
CLOAK_KEY=$(rand_b64 32)
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 16)
FORCE_SSL=false
EOF
umask 022

cat >"$RUN_DIR/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s
rule_files:
  - /etc/prometheus/alerts.yml
scrape_configs:
  - job_name: converger
    metrics_path: /metrics
    static_configs:
      - targets: ["app:4000"]
EOF
# Same rules, minutes-long `for:` shortened so the run takes minutes.
sed -E 's/^( +for: )(5m|10m|2m)$/\120s/; s/^( +for: )1m$/\110s/' docker/prometheus/alerts.yml \
  >"$RUN_DIR/prometheus/alerts.yml"
chmod -R a+rX "$RUN_DIR/prometheus"

dc down -v --remove-orphans >/dev/null 2>&1 || true

# --- stack ----------------------------------------------------------------------
if [ "${CHAOS_SKIP_BUILD:-0}" != "1" ]; then
  log "building image"
  dc build app
fi
log "starting db, migrate, app, sink, prometheus (app on 127.0.0.1:$CHAOS_APP_PORT, Prometheus on $PROM)"
dc up -d db migrate app sink prometheus
wait_ready 240
log "app ready"

rpc "Code.eval_string(File.read!(\"/chaos/setup.exs\"), rest: $REST_CONVERSATIONS, ws: 0, sink_url: \"http://sink:8080/hook\")" |
  grep '^{' | tail -n 1 >"$OUT/setup.json"

log "starting driver"
: >"$OUT/timings.txt"
dc run --rm -T --no-deps driver >"$OUT/driver.log" 2>&1 &
DRIVER_PID=$!

# --- 1. healthy -----------------------------------------------------------------
wait_for "deliveries sent and scraped" 120 \
  has_series 'converger_delivery_stop_duration_count{status="sent"} > 0'
wait_for "client connections gauge scraped" 60 has_series 'converger_ws_connections_count'
sleep 30
for alert in ConvergerDeliverySuccessRateLow ConvergerChannelCircuitOpen; do
  if firing "$alert"; then
    log "FAIL: $alert fires while the target is healthy"
    exit 1
  fi
done
log "ok: no delivery alert while healthy"

# --- 2. target killed, breaker effectively off ------------------------------------
rpc 'Application.put_env(:converger, :circuit_breaker, failure_threshold: 1_000_000)' >/dev/null
log "killing the webhook target"
dc kill sink >/dev/null
wait_for "ConvergerDeliverySuccessRateLow firing" "$ALERT_TIMEOUT_S" firing ConvergerDeliverySuccessRateLow

# --- 3. breaker back to its defaults: it opens --------------------------------------
rpc 'Application.delete_env(:converger, :circuit_breaker)' >/dev/null
wait_for "ConvergerChannelCircuitOpen firing" "$ALERT_TIMEOUT_S" firing ConvergerChannelCircuitOpen

# --- 4. target back -------------------------------------------------------------------
log "restarting the webhook target"
dc start sink >/dev/null
wait_for "ConvergerChannelCircuitOpen resolved" "$ALERT_TIMEOUT_S" not_firing ConvergerChannelCircuitOpen

log "PASS (timings in $OUT/timings.txt, alerts in $OUT/alerts.json)"
