#!/usr/bin/env bash
# Load test harness: boots the release image (1 or 3 nodes), the mock
# provider and Postgres, creates fixtures, runs the k6 scenarios while
# sampling CPU, memory, Oban queue depth and DB pool wait, and writes
# load/.run/out/results.json and report.md. See docs/benchmarks/index.md.
#
# Usage: load/run.sh            (from anywhere; needs docker compose >= 2.24)
#
# Main knobs (env):
#   LOAD_NODES       1 | 3                                     (1)
#   LOAD_BACKBONE    native (kafka is planned, #66)            (native)
#   LOAD_PROFILE     full | smoke                              (full)
#   LOAD_SCENARIOS   space-separated subset of
#                    "e2e webhook_burst idle reconnect_storm rolling_restart node_kill"
#   LOAD_SKIP_BUILD  1 reuses converger-load:local             (0)
#   LOAD_KEEP        1 leaves the stack running                (0)
#   LOAD_APP_CPUS / LOAD_APP_MEMORY   per-node limits, e.g. 2 / 2g (unlimited)
# Scenario sizes are listed under "profiles" below; every one can be
# overridden (e.g. LOAD_IDLE_SOCKETS=20000).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Native path for docker (C:/... under Git Bash, unchanged elsewhere).
ROOT="$(pwd -W 2>/dev/null || pwd)"

PROJECT="${LOAD_PROJECT:-converger-load}"
RUN_DIR="load/.run"
OUT="$RUN_DIR/out"
NODES="${LOAD_NODES:-1}"
BACKBONE="${LOAD_BACKBONE:-native}"
PROFILE="${LOAD_PROFILE:-full}"
SCENARIOS="${LOAD_SCENARIOS:-e2e webhook_burst idle reconnect_storm rolling_restart node_kill}"
export LOAD_APP_PORT="${LOAD_APP_PORT:-14100}"
export LOAD_APP2_PORT="${LOAD_APP2_PORT:-14101}"
export LOAD_APP3_PORT="${LOAD_APP3_PORT:-14102}"

log() { echo "[load $(date +%H:%M:%S)] $*"; }

case "$BACKBONE" in
  native) ;;
  kafka | nats | rabbitmq)
    log "backbone '$BACKBONE' is planned (#66); only 'native' (Phoenix.PubSub + Oban) exists today"
    exit 2
    ;;
  *)
    log "unknown LOAD_BACKBONE '$BACKBONE'"
    exit 2
    ;;
esac

case "$NODES" in
  1)
    SERVICES="app"
    PORTS="$LOAD_APP_PORT"
    export LOAD_APP_URLS="http://app:4000"
    ;;
  3)
    SERVICES="app app2 app3"
    PORTS="$LOAD_APP_PORT $LOAD_APP2_PORT $LOAD_APP3_PORT"
    export LOAD_APP_URLS="http://app:4000,http://app2:4000,http://app3:4000"
    ;;
  *)
    log "LOAD_NODES must be 1 or 3"
    exit 2
    ;;
esac

# --- profiles -------------------------------------------------------------------
if [ "$PROFILE" = "smoke" ]; then
  d_conversations=10 d_subscribers=3 d_rate=2 d_duration=20
  d_burst_rate=50 d_burst_s=10 d_idle_sockets=500 d_idle_hold=15 d_idle_conversations=50
else
  d_conversations=100 d_subscribers=10 d_rate=1 d_duration=60
  d_burst_rate=500 d_burst_s=30 d_idle_sockets=10000 d_idle_hold=60 d_idle_conversations=1000
fi
CONVERSATIONS="${LOAD_CONVERSATIONS:-$d_conversations}"
SUBSCRIBERS="${LOAD_SUBSCRIBERS:-$d_subscribers}"
RATE="${LOAD_RATE:-$d_rate}"
DURATION_S="${LOAD_DURATION_S:-$d_duration}"
BURST_RATE="${LOAD_BURST_RATE:-$d_burst_rate}"
BURST_S="${LOAD_BURST_S:-$d_burst_s}"
TARGETS="${LOAD_TARGETS:-3}"
IDLE_SOCKETS="${LOAD_IDLE_SOCKETS:-$d_idle_sockets}"
IDLE_HOLD_S="${LOAD_IDLE_HOLD_S:-$d_idle_hold}"
IDLE_CONVERSATIONS="${LOAD_IDLE_CONVERSATIONS:-$d_idle_conversations}"
CONNECT_RATE="${LOAD_CONNECT_RATE:-100}"
RESTART_GAP_S="${LOAD_RESTART_GAP_S:-10}"
DELIVERY_TIMEOUT_S="${LOAD_DELIVERY_TIMEOUT_S:-300}"

COMPOSE_FILES=(-f docker-compose.yml -f load/docker-compose.load.yml)
if [ "$NODES" = "3" ]; then
  COMPOSE_FILES+=(-f docker-compose.cluster.yml -f load/docker-compose.load-cluster.yml)
fi

dc() {
  # MSYS_NO_PATHCONV: Git Bash on Windows must not rewrite the /load/...
  # container paths in arguments into C:/... host paths.
  MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" --project-directory "$ROOT" --env-file "$RUN_DIR/.env" \
    "${COMPOSE_FILES[@]}" --profile load-tools "$@"
}

psql_q() {
  dc exec -T db psql -U postgres -d converger_prod -At -v ON_ERROR_STOP=1 -c "$1"
}

now_ms() { date +%s%3N; }
rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }

cleanup() {
  local code=$?
  touch "$RUN_DIR/stop-sampler" 2>/dev/null || true
  if [ -f "$RUN_DIR/.env" ]; then
    for svc in $SERVICES; do dc logs --no-color "$svc" >"$OUT/$svc.log" 2>&1 || true; done
    if [ "${LOAD_KEEP:-0}" != "1" ]; then
      log "tearing down (set LOAD_KEEP=1 to keep the stack)"
      dc down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  exit "$code"
}
trap cleanup EXIT

# Ready, or `degraded` (#35): readiness answers 503 while the interactive pool
# wait is high, but the node is up and serving; under load that is expected.
ready() {
  local body
  body=$(curl -s -m 5 "http://127.0.0.1:$1/health/ready" 2>/dev/null) || return 1
  case "$body" in *'"status":"ready"'* | *'"status":"degraded"'*) return 0 ;; *) return 1 ;; esac
}

wait_ready() {
  local port=$1 deadline=$((SECONDS + ${2:-180}))
  until ready "$port"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "node on port $port did not become ready"
      return 1
    fi
    sleep 0.5
  done
}

port_of() {
  case "$1" in
    app) echo "$LOAD_APP_PORT" ;;
    app2) echo "$LOAD_APP2_PORT" ;;
    app3) echo "$LOAD_APP3_PORT" ;;
  esac
}

wait_deliveries() {
  local deadline=$((SECONDS + DELIVERY_TIMEOUT_S)) open
  while :; do
    open=$(psql_q "SELECT count(*) FROM oban_jobs WHERE queue LIKE 'deliveries%' AND state IN ('available','scheduled','executing','retryable')")
    [ "$open" = "0" ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "delivery jobs still open after ${DELIVERY_TIMEOUT_S}s: $open"
      return 1
    fi
    sleep 1
  done
}

# CPU and memory of each node and Postgres (`docker stats --no-stream`, about
# every 2.5 s on Docker Desktop), and every second the open Oban jobs and each
# node's last DB pool queue time (/metrics). Streaming `docker stats` is not
# used: on Windows it outlives its reader. `docker exec` rather than `docker
# compose exec`: the compose CLI takes over a second per call.
sampler() {
  local containers=""
  for svc in $SERVICES db; do containers="$containers ${PROJECT}-${svc}-1"; done
  while [ ! -f "$RUN_DIR/stop-sampler" ]; do
    local ts
    ts=$(now_ms)
    # shellcheck disable=SC2086
    docker stats --no-stream --format '{{.Name}};{{.CPUPerc}};{{.MemUsage}}' $containers 2>/dev/null |
      sed "s/^/$ts;stats;/" || true
  done &
  while [ ! -f "$RUN_DIR/stop-sampler" ]; do
    local ts
    ts=$(now_ms)
    echo "$ts;oban;$(docker exec "${PROJECT}-db-1" psql -U postgres -d converger_prod -At -c "SELECT count(*) FROM oban_jobs WHERE state IN ('available','scheduled','executing','retryable')" 2>/dev/null || true)"
    for svc in $SERVICES; do
      # A histogram since #33 (sum and count of the wait, summed over label
      # sets); before that a gauge holding the last value.
      curl -s -m 2 -H "authorization: Bearer $METRICS_TOKEN" "http://127.0.0.1:$(port_of "$svc")/metrics" 2>/dev/null |
        awk -v p="$ts;queue;$svc;" '
          /^converger_repo_query_queue_time_sum/ { s += $NF; h = 1 }
          /^converger_repo_query_queue_time_count/ { c += $NF }
          /^converger_repo_query_queue_time[{ ]/ { g = $NF }
          /^converger_background_repo_query_queue_time_sum/ { bs += $NF; b = 1 }
          /^converger_background_repo_query_queue_time_count/ { bc += $NF }
          END {
            if (h) print p "hist;" s ";" c; else if (g != "") print p "last;" g
            if (b) print p "bghist;" bs ";" bc
          }' || true
    done
    sleep 1
  done
  wait
}

k6_run() {
  local scenario=$1 script=$2
  shift 2
  local env_args=()
  for kv in "$@"; do env_args+=(-e "$kv"); done
  echo "$scenario;start;$(now_ms)" >>"$OUT/marks.csv"
  local code=0
  dc run --rm -T --no-deps "${env_args[@]}" k6 run --quiet "/load/$script" >"$OUT/$scenario.log" 2>&1 || code=$?
  echo "$scenario;end;$(now_ms)" >>"$OUT/marks.csv"
  echo "$scenario;$code" >>"$OUT/exit_codes.csv"
  grep -E '✓|✗|e2e_latency|ws_connected |ws_reconnect_ms|inbound_accepted|messages_acked' "$OUT/$scenario.log" || true
  log "$scenario finished (k6 exit $code)"
}

common_env() {
  echo "CONVERSATIONS=$CONVERSATIONS SUBSCRIBERS=$SUBSCRIBERS RATE=$RATE"
}

# --- throwaway secrets (never committed: load/.run is gitignored) --------------
rm -rf "$OUT" "$RUN_DIR/stop-sampler"
mkdir -p "$OUT"
chmod 777 "$OUT" 2>/dev/null || true
METRICS_TOKEN=$(openssl rand -hex 16)
umask 077
cat >"$RUN_DIR/.env" <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 24)
SECRET_KEY_BASE=$(rand_b64 64)
CLOAK_KEY=$(rand_b64 32)
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 16)
RELEASE_COOKIE=$(openssl rand -hex 32)
CLUSTER_GOSSIP_SECRET=$(openssl rand -hex 32)
METRICS_TOKEN=$METRICS_TOKEN
FORCE_SSL=false
EOF
umask 022

dc down -v --remove-orphans >/dev/null 2>&1 || true

# --- stack --------------------------------------------------------------------
if [ "${LOAD_SKIP_BUILD:-0}" != "1" ]; then
  log "building image"
  dc build migrate
fi
log "starting db, migrate, $SERVICES, mock ($NODES node(s), project $PROJECT)"
# shellcheck disable=SC2086
dc up -d db migrate $SERVICES mock
for port in $PORTS; do wait_ready "$port" 240; done
if [ "$NODES" = "3" ]; then
  deadline=$((SECONDS + 60))
  until [ "$(dc exec -T app bin/converger rpc 'IO.puts(length(Node.list()))' 2>/dev/null | tr -d '\r')" = "2" ]; do
    [ "$SECONDS" -ge "$deadline" ] && { log "nodes did not form a cluster"; exit 1; }
    sleep 1
  done
  log "cluster formed (3 nodes)"
fi
log "app ready"

dc exec -T app bin/converger rpc \
  "Code.eval_string(File.read!(\"/load/setup.exs\"), conversations: $CONVERSATIONS, tokens_per_conversation: $SUBSCRIBERS, idle_conversations: $IDLE_CONVERSATIONS, targets: $TARGETS, mock_url: \"http://mock:8080\")" |
  grep '^{' | tail -n 1 >"$OUT/setup.json"
TENANT_ID=$(sed -E 's/.*"tenant_id":"([^"]+)".*/\1/' "$OUT/setup.json")
INGRESS_ID=$(sed -E 's/.*"ingress":\{"id":"([^"]+)".*/\1/' "$OUT/setup.json")
FANOUT_ID=$(sed -E 's/.*"fanout_channel_id":"([^"]+)".*/\1/' "$OUT/setup.json")
log "fixtures created (tenant $TENANT_ID)"

# --- warm-up -------------------------------------------------------------------
# A cold node (JIT, connection pools, first queries) answers the first seconds
# up to ten times slower: run e2e for LOAD_WARMUP_S and discard its numbers.
WARMUP_S="${LOAD_WARMUP_S:-15}"
if [ "$WARMUP_S" -gt 0 ]; then
  log "warm-up (${WARMUP_S}s of e2e, not measured)"
  mkdir -p "$OUT/warmup"
  chmod 777 "$OUT/warmup" 2>/dev/null || true
  dc run --rm -T --no-deps -e OUT_DIR=/out/warmup -e "DURATION_S=$WARMUP_S" -e DRAIN_S=2 \
    -e "CONVERSATIONS=$CONVERSATIONS" -e "SUBSCRIBERS=$SUBSCRIBERS" -e "RATE=$RATE" \
    k6 run --quiet /load/e2e.js >"$OUT/warmup/e2e.log" 2>&1 || true
fi

sampler >"$OUT/samples.csv" 2>/dev/null &
SAMPLER_PID=$!

# --- scenarios ------------------------------------------------------------------
for scenario in $SCENARIOS; do
  log "scenario $scenario"
  case "$scenario" in
    e2e)
      # shellcheck disable=SC2046
      k6_run e2e e2e.js $(common_env) "DURATION_S=$DURATION_S"
      ;;
    webhook_burst)
      k6_run webhook_burst webhook_burst.js "BURST_RATE=$BURST_RATE" "BURST_S=$BURST_S"
      t0=$(now_ms)
      wait_deliveries || true
      echo "webhook_burst;drained;$(now_ms)" >>"$OUT/marks.csv"
      log "burst deliveries drained in $(($(now_ms) - t0)) ms after the burst"
      ;;
    idle)
      k6_run idle idle.js "SOCKETS=$IDLE_SOCKETS" "HOLD_S=$IDLE_HOLD_S" "CONNECT_RATE=$CONNECT_RATE"
      ;;
    reconnect_storm)
      # shellcheck disable=SC2046
      k6_run reconnect_storm reconnect.js MODE=storm $(common_env) "DURATION_S=$DURATION_S"
      ;;
    rolling_restart | node_kill)
      if [ "$scenario" = "rolling_restart" ]; then targets="$SERVICES"; else targets="app"; fi
      n=$(echo "$targets" | wc -w)
      duration=$((20 + n * (RESTART_GAP_S + 40)))
      # shellcheck disable=SC2046
      k6_run "$scenario" reconnect.js MODE=restart "SCENARIO=$scenario" $(common_env) "DURATION_S=$duration" &
      K6_PID=$!
      sleep 20
      for svc in $targets; do
        t0=$(now_ms)
        if [ "$scenario" = "rolling_restart" ]; then
          log "graceful restart of $svc (SIGTERM, drain)"
          dc restart -t 60 "$svc" >/dev/null
        else
          log "SIGKILL $svc"
          docker kill -s KILL "${PROJECT}-${svc}-1" >/dev/null
          dc start "$svc" >/dev/null
        fi
        wait_ready "$(port_of "$svc")" 180
        echo "$scenario;$svc;$(($(now_ms) - t0))" >>"$OUT/restarts.csv"
        log "$svc ready again after $(($(now_ms) - t0)) ms"
        sleep "$RESTART_GAP_S"
      done
      wait "$K6_PID" || true
      ;;
    *)
      log "unknown scenario $scenario"
      exit 2
      ;;
  esac
done

# --- drain + collect -----------------------------------------------------------
log "waiting for the delivery queues to drain"
wait_deliveries || true
touch "$RUN_DIR/stop-sampler"
wait "$SAMPLER_PID" 2>/dev/null || true

dc exec -T mock wget -qO- http://127.0.0.1:8080/stats >"$OUT/mock_stats.json"
cat >"$OUT/db.json" <<EOF
{
  "fanout_activities": $(psql_q "SELECT count(*) FROM activities a JOIN conversations c ON c.id = a.conversation_id WHERE c.channel_id = '$FANOUT_ID' AND a.text LIKE 'load %'"),
  "burst_activities": $(psql_q "SELECT count(*) FROM activities a JOIN conversations c ON c.id = a.conversation_id WHERE c.channel_id = '$INGRESS_ID' AND a.text LIKE 'load %'"),
  "open_delivery_jobs": $(psql_q "SELECT count(*) FROM oban_jobs WHERE queue LIKE 'deliveries%' AND state IN ('available','scheduled','executing','retryable')"),
  "failed_deliveries": $(psql_q "SELECT count(*) FROM deliveries d JOIN activities a ON a.id = d.activity_id WHERE a.tenant_id = '$TENANT_ID' AND d.status NOT IN ('delivered','sent')"),
  "database_size_bytes": $(psql_q "SELECT pg_database_size('converger_prod')"),
  "postgres_version": "$(psql_q "SHOW server_version")"
}
EOF

cat >"$OUT/hardware.json" <<EOF
{
  "host": "$(hostname)",
  "runner": "${RUNNER_NAME:-local}",
  "runner_os": "${RUNNER_OS:-$(uname -s)}",
  "docker_cpus": $(docker info --format '{{.NCPU}}'),
  "docker_memory_bytes": $(docker info --format '{{.MemTotal}}'),
  "docker_version": "$(docker version --format '{{.Server.Version}}')",
  "kernel": "$(docker info --format '{{.KernelVersion}}')",
  "app_cpus_limit": "${LOAD_APP_CPUS:-unlimited}",
  "app_memory_limit": "${LOAD_APP_MEMORY:-unlimited}",
  "pool_size": ${LOAD_POOL_SIZE:-20},
  "background_pool_size": ${LOAD_BACKGROUND_POOL_SIZE:-10}
}
EOF

cat >"$OUT/run.json" <<EOF
{
  "commit": "$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "nodes": $NODES,
  "backbone": "$BACKBONE",
  "profile": "$PROFILE",
  "scenarios": "$SCENARIOS"
}
EOF

dc run --rm -T --no-deps node node /load/results.js /out
cat "$OUT/report.md"

if grep -q '^  "ok": false' "$OUT/results.json"; then
  log "FAILED: see $OUT/report.md"
  exit 1
fi
log "passed; results in $OUT"
