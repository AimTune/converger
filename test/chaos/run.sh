#!/usr/bin/env bash
# Chaos test: kill the app node (SIGKILL) repeatedly while REST and WebSocket
# clients send activities, then verify that no acked message was lost or
# duplicated, `seq` is gap-free and every acked message reached the webhook
# sink. See docs/chaos.md.
#
# Usage: test/chaos/run.sh            (from anywhere; needs docker compose >= 2.24)
#
# Tunables (env): CHAOS_KILLS (3), CHAOS_FIRST_KILL_S (10), CHAOS_KILL_INTERVAL_S (15),
# CHAOS_DOWN_S (3), CHAOS_DURATION_S (60), CHAOS_DRAIN_S (180),
# CHAOS_REST_CONVERSATIONS (8), CHAOS_WS_CONVERSATIONS (8),
# CHAOS_DELIVERY_TIMEOUT_S (300), CHAOS_APP_PORT (14000),
# CHAOS_PROJECT (converger-chaos), CHAOS_SKIP_BUILD (0), CHAOS_KEEP (0: tear
# the stack down, volumes included, when done).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# Native path for docker (C:/... under Git Bash, unchanged elsewhere).
ROOT="$(pwd -W 2>/dev/null || pwd)"

PROJECT="${CHAOS_PROJECT:-converger-chaos}"
RUN_DIR="test/chaos/.run"
OUT="$RUN_DIR/out"
KILLS="${CHAOS_KILLS:-3}"
FIRST_KILL_S="${CHAOS_FIRST_KILL_S:-10}"
KILL_INTERVAL_S="${CHAOS_KILL_INTERVAL_S:-15}"
DOWN_S="${CHAOS_DOWN_S:-3}"
REST_CONVERSATIONS="${CHAOS_REST_CONVERSATIONS:-8}"
WS_CONVERSATIONS="${CHAOS_WS_CONVERSATIONS:-8}"
DELIVERY_TIMEOUT_S="${CHAOS_DELIVERY_TIMEOUT_S:-300}"
export CHAOS_APP_PORT="${CHAOS_APP_PORT:-14000}"

log() { echo "[chaos $(date +%H:%M:%S)] $*"; }

dc() {
  # MSYS_NO_PATHCONV: Git Bash on Windows must not rewrite the /chaos/...
  # container paths in arguments into C:/... host paths.
  MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" --project-directory "$ROOT" --env-file "$RUN_DIR/.env" \
    -f docker-compose.yml -f test/chaos/docker-compose.chaos.yml --profile chaos-driver "$@"
}

psql_q() {
  dc exec -T db psql -U postgres -d converger_prod -At -v ON_ERROR_STOP=1 -c "$1"
}

rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }

cleanup() {
  local code=$?
  if [ -f "$RUN_DIR/.env" ]; then
    dc logs --no-color app >"$OUT/app.log" 2>&1 || true
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

# --- throwaway secrets (never committed: test/chaos/.run is gitignored) ------
rm -rf "$OUT"
mkdir -p "$OUT"
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

# Start from scratch: a leftover database volume has a different password.
dc down -v --remove-orphans >/dev/null 2>&1 || true

# --- stack --------------------------------------------------------------------
if [ "${CHAOS_SKIP_BUILD:-0}" != "1" ]; then
  log "building image"
  dc build app
fi
log "starting db, migrate, app, sink (project $PROJECT, app on 127.0.0.1:$CHAOS_APP_PORT)"
dc up -d db migrate app sink
wait_ready 240
log "app ready"

dc exec -T app bin/converger rpc \
  "Code.eval_string(File.read!(\"/chaos/setup.exs\"), rest: $REST_CONVERSATIONS, ws: $WS_CONVERSATIONS, sink_url: \"http://sink:8080/hook\")" |
  grep '^{' | tail -n 1 >"$OUT/setup.json"
TENANT_ID=$(sed -E 's/.*"tenant_id":"([^"]+)".*/\1/' "$OUT/setup.json")
log "fixtures created (tenant $TENANT_ID)"

# --- load + kills ---------------------------------------------------------------
log "starting driver"
dc run --rm -T --no-deps driver >"$OUT/driver.log" 2>&1 &
DRIVER_PID=$!

sleep "$FIRST_KILL_S"
LAST_RESTART=$SECONDS
for i in $(seq 1 "$KILLS"); do
  CID=$(dc ps -q app)
  log "kill $i/$KILLS: docker kill -s KILL $CID"
  docker kill -s KILL "$CID" >/dev/null
  sleep "$DOWN_S"
  dc start app >/dev/null
  wait_ready 120
  LAST_RESTART=$SECONDS
  log "app back after kill $i"
  if [ "$i" -lt "$KILLS" ]; then sleep "$KILL_INTERVAL_S"; fi
done

log "waiting for the driver to finish"
DRIVER_CODE=0
wait "$DRIVER_PID" || DRIVER_CODE=$?
tail -n 1 "$OUT/driver.log"
if [ "$DRIVER_CODE" != "0" ]; then
  log "driver failed ($DRIVER_CODE), see $OUT/driver.log"
  exit 1
fi

# --- wait for the outbox to drain ---------------------------------------------
log "waiting for delivery jobs (timeout ${DELIVERY_TIMEOUT_S}s)"
deadline=$((SECONDS + DELIVERY_TIMEOUT_S))
while :; do
  open=$(psql_q "SELECT count(*) FROM oban_jobs WHERE queue = 'deliveries' AND state IN ('available','scheduled','executing','retryable')")
  [ "$open" = "0" ] && break
  if [ "$SECONDS" -ge "$deadline" ]; then
    log "delivery jobs still open after ${DELIVERY_TIMEOUT_S}s: $open"
    psql_q "SELECT state, count(*) FROM oban_jobs WHERE queue = 'deliveries' GROUP BY state" || true
    break
  fi
  sleep 2
done
DRAINED_AFTER_S=$((SECONDS - LAST_RESTART))
log "delivery queue drained ${DRAINED_AFTER_S}s after the last restart (open jobs: $open)"

# --- dump + verify --------------------------------------------------------------
psql_q "COPY (SELECT id, conversation_id, seq, coalesce(idempotency_key, ''), text FROM activities WHERE tenant_id = '$TENANT_ID') TO STDOUT WITH CSV" >"$OUT/activities.csv"
psql_q "COPY (SELECT id, last_seq FROM conversations WHERE tenant_id = '$TENANT_ID') TO STDOUT WITH CSV" >"$OUT/conversations.csv"
psql_q "COPY (SELECT d.activity_id, d.status, d.attempts FROM deliveries d JOIN activities a ON a.id = d.activity_id WHERE a.tenant_id = '$TENANT_ID') TO STDOUT WITH CSV" >"$OUT/deliveries.csv"
psql_q "COPY (SELECT state, attempt, count(*) FROM oban_jobs WHERE queue = 'deliveries' GROUP BY state, attempt ORDER BY state, attempt) TO STDOUT WITH CSV" >"$OUT/oban_jobs.csv"
cat >"$OUT/timing.json" <<EOF
{"kills": $KILLS, "down_s": $DOWN_S, "open_delivery_jobs": $open, "delivery_drained_after_last_restart_s": $DRAINED_AFTER_S}
EOF

log "verifying"
dc run --rm -T --no-deps driver node /chaos/verify.js
