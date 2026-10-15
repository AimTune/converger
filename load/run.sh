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
#   LOAD_BACKBONE    native | kafka (event backbone, #66)       (native)
#   LOAD_PROFILE     full | smoke                              (full)
#   LOAD_RESTART_DELAY_S / LOAD_RESTART_CONNECT_RATE   restart scenarios:
#                    traffic before the first restart (20), socket connect
#                    rate (0 = all at once)
#   LOAD_SCENARIOS   space-separated subset of
#                    "e2e webhook_burst idle reconnect_storm rolling_restart node_kill"
#                    plus the opt-in "dead_channel" (not in the default list)
#   LOAD_SKIP_BUILD  1 reuses the image (LOAD_IMAGE)           (0)
#   LOAD_IMAGE       image tag to build and run   (converger-load:local)
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
export LOAD_IMAGE="${LOAD_IMAGE:-converger-load:local}"
export LOAD_APP_PORT="${LOAD_APP_PORT:-14100}"
export LOAD_APP2_PORT="${LOAD_APP2_PORT:-14101}"
export LOAD_APP3_PORT="${LOAD_APP3_PORT:-14102}"

log() { echo "[load $(date +%H:%M:%S)] $*"; }

case "$BACKBONE" in
  native | kafka) ;;
  nats | rabbitmq)
    log "backbone '$BACKBONE' is supported by Converger (#66) but not wired into the harness yet; use native or kafka"
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
  d_dead_conversations=10 d_dead_duration=30 d_dead_backlog=1000
else
  d_conversations=100 d_subscribers=10 d_rate=1 d_duration=60
  d_burst_rate=500 d_burst_s=30 d_idle_sockets=10000 d_idle_hold=60 d_idle_conversations=1000
  d_dead_conversations=50 d_dead_duration=90 d_dead_backlog=10000
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
# Restart scenarios: seconds of traffic before the first restart, and the rate
# at which their sockets connect (0: all at once). For the 10 000-socket run
# (#190), connect at 100/s and wait for the ramp: e.g. 130 s.
RESTART_DELAY_S="${LOAD_RESTART_DELAY_S:-20}"
RESTART_CONNECT_RATE="${LOAD_RESTART_CONNECT_RATE:-0}"
DELIVERY_TIMEOUT_S="${LOAD_DELIVERY_TIMEOUT_S:-300}"
# dead_channel: healthy tenant conversations x LOAD_DEAD_RATE msgs/s each for
# LOAD_DEAD_DURATION_S per phase; LOAD_DEAD_BACKLOG deliveries for the dead
# channel, created by LOAD_DEAD_BACKLOG_CONCURRENCY processes.
DEAD_CONVERSATIONS="${LOAD_DEAD_CONVERSATIONS:-$d_dead_conversations}"
DEAD_RATE="${LOAD_DEAD_RATE:-1}"
DEAD_DURATION_S="${LOAD_DEAD_DURATION_S:-$d_dead_duration}"
DEAD_BACKLOG="${LOAD_DEAD_BACKLOG:-$d_dead_backlog}"
DEAD_BACKLOG_CONCURRENCY="${LOAD_DEAD_BACKLOG_CONCURRENCY:-10}"
# Tier of the dead tenant: default (shares the healthy tenant's queue) or bulk
# / high (its own queue).
DEAD_TIER="${LOAD_DEAD_TIER:-default}"

COMPOSE_FILES=(-f docker-compose.yml -f load/docker-compose.load.yml)
if [ "$NODES" = "3" ]; then
  COMPOSE_FILES+=(-f docker-compose.cluster.yml -f load/docker-compose.load-cluster.yml)
fi
# The event backbone (#66): Kafka is one more container and one variable
# (BACKBONE=kafka) on every node.
BACKBONE_SERVICES=""
if [ "$BACKBONE" = "kafka" ]; then
  COMPOSE_FILES+=(-f load/docker-compose.load-kafka.yml)
  [ "$NODES" = "3" ] && COMPOSE_FILES+=(-f load/docker-compose.load-kafka-cluster.yml)
  BACKBONE_SERVICES="kafka"
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

# The backbone zero-loss check (#66): every activity of the run is published
# to the backbone, and the platform webhook subscription of load/setup.exs
# consumes it. Wait until the subscriber has a webhook event for every
# activity and none is left to send.
wait_backbone() {
  local deadline=$((SECONDS + DELIVERY_TIMEOUT_S)) behind
  while :; do
    behind=$(psql_q "SELECT (SELECT count(*) FROM activities WHERE tenant_id = '$TENANT_ID') - (SELECT count(DISTINCT event_id) FROM webhook_events WHERE subscription_id = '$BACKBONE_SUB_ID' AND status = 'delivered')")
    [ "$behind" -le 0 ] 2>/dev/null && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "backbone subscriber still $behind event(s) behind after ${DELIVERY_TIMEOUT_S}s"
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
  for svc in $SERVICES db $BACKBONE_SERVICES; do containers="$containers ${PROJECT}-${svc}-1"; done
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

# --- dead_channel (epic #59) -----------------------------------------------------
# A healthy tenant's delivery latency without (baseline) and with (dead)
# another tenant's dead channel and its backlog, back to back. Both tenants
# are on the default tier, so they share the `deliveries` queue. See
# docs/benchmarks/dead-channel-isolation.md.

# Open delivery jobs of one channel.
channel_open_jobs() {
  psql_q "SELECT count(*) FROM oban_jobs WHERE args->>'channel_id' = '$1' AND worker = 'Converger.Workers.ActivityDeliveryWorker' AND state IN ('available','scheduled','executing','retryable')"
}

wait_channel_drained() {
  local deadline=$((SECONDS + DELIVERY_TIMEOUT_S))
  until [ "$(channel_open_jobs "$1")" = "0" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "channel $1 still has open delivery jobs after ${DELIVERY_TIMEOUT_S}s"
      return 1
    fi
    sleep 1
  done
}

# Every second: the dead channel's breaker state and failure counter, its
# jobs (executing, available at normal priority, parked = priority 3 and
# snoozed, retryable), the executing jobs of the shared queue and the healthy
# channel's open jobs.
isolation_sampler() {
  local dead=$1 healthy=$2 queue=$3
  while [ ! -f "$RUN_DIR/stop-isolation-sampler" ]; do
    echo "$(now_ms);$(docker exec "${PROJECT}-db-1" psql -U postgres -d converger_prod -At -F';' -c "
      SELECT c.circuit_state, c.consecutive_failures,
             count(j.id) FILTER (WHERE j.state = 'executing'),
             count(j.id) FILTER (WHERE j.state = 'available' AND j.priority < 3),
             count(j.id) FILTER (WHERE j.priority = 3 AND j.state IN ('scheduled', 'available')),
             count(j.id) FILTER (WHERE j.state = 'retryable'),
             (SELECT count(*) FROM oban_jobs WHERE queue = '$queue' AND state = 'executing'),
             (SELECT count(*) FROM oban_jobs WHERE args->>'channel_id' = '$healthy'
                AND state IN ('available', 'scheduled', 'executing', 'retryable'))
      FROM channels c
      LEFT JOIN oban_jobs j ON j.args->>'channel_id' = c.id::text
        AND j.worker = 'Converger.Workers.ActivityDeliveryWorker'
        AND j.state IN ('available', 'scheduled', 'executing', 'retryable')
      WHERE c.id = '$dead'
      GROUP BY 1, 2" 2>/dev/null || true)"
    sleep 1
  done
}

mock_get() { dc exec -T mock wget -qO- "http://127.0.0.1:8080$1"; }

dead_channel_scenario() {
  dc exec -T app bin/converger rpc \
    "Code.eval_string(File.read!(\"/load/isolation_setup.exs\"), conversations: $DEAD_CONVERSATIONS, dead_tier: \"$DEAD_TIER\", mock_url: \"http://mock:8080\")" |
    grep '^{' | tail -n 1 >"$OUT/isolation.json"
  local dead healthy queue
  dead=$(sed -E 's/.*"dead_channel_id":"([^"]+)".*/\1/' "$OUT/isolation.json")
  healthy=$(sed -E 's/.*"healthy_channel_id":"([^"]+)".*/\1/' "$OUT/isolation.json")
  queue=$(psql_q "SELECT CASE tier WHEN 'high' THEN 'deliveries_high' WHEN 'bulk' THEN 'deliveries_bulk' ELSE 'deliveries' END FROM tenants t JOIN channels c ON c.tenant_id = t.id WHERE c.id = '$healthy'")
  log "isolation fixtures: dead channel $dead, healthy channel $healthy, queue $queue"

  for phase in baseline dead; do
    local sampler_pid="" backlog_pid=""
    if [ "$phase" = "dead" ]; then
      rm -f "$RUN_DIR/stop-isolation-sampler"
      isolation_sampler "$dead" "$healthy" "$queue" >"$OUT/dead_channel_circuit.csv" &
      sampler_pid=$!
      # The backlog is created while the healthy tenant sends: the breaker
      # has to open (and the backlog to sink) under traffic, the worst case.
      log "dead_channel: backlog of $DEAD_BACKLOG deliveries for the dead channel"
      echo "dead_channel;backlog_start;$(now_ms)" >>"$OUT/marks.csv"
      (
        dc exec -T app bin/converger rpc \
          "Code.eval_string(File.read!(\"/load/isolation_backlog.exs\"), fixtures: Jason.decode!(File.read!(\"/load/.run/out/isolation.json\")), count: $DEAD_BACKLOG, concurrency: $DEAD_BACKLOG_CONCURRENCY)" |
          grep '^{' | tail -n 1 >"$OUT/dead_channel_backlog.json"
        echo "dead_channel;backlog_created;$(now_ms)" >>"$OUT/marks.csv"
      ) &
      backlog_pid=$!
    fi

    k6_run "dead_channel_$phase" dead_channel.js "SETUP_JSON=/out/isolation.json" "PHASE=$phase" \
      "CONVERSATIONS=$DEAD_CONVERSATIONS" "RATE=$DEAD_RATE" "DURATION_S=$DEAD_DURATION_S"
    wait_channel_drained "$healthy" || true
    echo "dead_channel_$phase;drained;$(now_ms)" >>"$OUT/marks.csv"
    mock_get /samples/healthy >"$OUT/dead_channel_$phase.samples.json"
    mock_get /stats >"$OUT/dead_channel_$phase.mock.json"

    if [ "$phase" = "dead" ]; then
      wait "$backlog_pid" || true
      touch "$RUN_DIR/stop-isolation-sampler"
      wait "$sampler_pid" 2>/dev/null || true
      psql_q "SELECT circuit_state, consecutive_failures, (SELECT count(*) FROM deliveries WHERE channel_id = '$dead'), (SELECT count(*) FROM deliveries WHERE channel_id = '$dead' AND status = 'paused') FROM channels WHERE id = '$dead'" >"$OUT/dead_channel_final.txt"
      # The dead channel never recovers: cancel its parked backlog so the
      # end-of-run drain check is about the other scenarios.
      psql_q "UPDATE oban_jobs SET state = 'cancelled', cancelled_at = now() WHERE args->>'channel_id' = '$dead' AND state IN ('available','scheduled','executing','retryable') RETURNING 1" | wc -l |
        xargs -I{} echo "dead_channel: cancelled {} parked jobs of the dead channel" >&2
    fi
    log "dead_channel: $phase phase done"
  done
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
log "starting db, migrate, $SERVICES, mock $BACKBONE_SERVICES ($NODES node(s), backbone $BACKBONE, project $PROJECT)"
# shellcheck disable=SC2086
dc up -d db migrate $BACKBONE_SERVICES $SERVICES mock
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
BACKBONE_SUB_ID=$(sed -E 's/.*"backbone_subscription_id":"([^"]+)".*/\1/' "$OUT/setup.json")
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
      duration=$((RESTART_DELAY_S + n * (RESTART_GAP_S + 40)))
      # shellcheck disable=SC2046
      k6_run "$scenario" reconnect.js MODE=restart "SCENARIO=$scenario" "CONNECT_RATE=$RESTART_CONNECT_RATE" $(common_env) "DURATION_S=$duration" &
      K6_PID=$!
      sleep "$RESTART_DELAY_S"
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
    dead_channel)
      dead_channel_scenario
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
log "waiting for the backbone subscriber ($BACKBONE) to catch up"
t0=$(now_ms)
echo "backbone;deliveries_drained;$t0" >>"$OUT/marks.csv"
wait_backbone || true
echo "backbone;caught_up;$(now_ms)" >>"$OUT/marks.csv"
log "backbone subscriber caught up $(($(now_ms) - t0)) ms after the deliveries drained"
touch "$RUN_DIR/stop-sampler"
wait "$SAMPLER_PID" 2>/dev/null || true

dc exec -T mock wget -qO- http://127.0.0.1:8080/stats >"$OUT/mock_stats.json"
cat >"$OUT/db.json" <<EOF
{
  "fanout_activities": $(psql_q "SELECT count(*) FROM activities a JOIN conversations c ON c.id = a.conversation_id WHERE c.channel_id = '$FANOUT_ID' AND a.text LIKE 'load %'"),
  "burst_activities": $(psql_q "SELECT count(*) FROM activities a JOIN conversations c ON c.id = a.conversation_id WHERE c.channel_id = '$INGRESS_ID' AND a.text LIKE 'load %'"),
  "open_delivery_jobs": $(psql_q "SELECT count(*) FROM oban_jobs WHERE queue LIKE 'deliveries%' AND state IN ('available','scheduled','executing','retryable')"),
  "failed_deliveries": $(psql_q "SELECT count(*) FROM deliveries d JOIN activities a ON a.id = d.activity_id WHERE a.tenant_id = '$TENANT_ID' AND d.status NOT IN ('delivered','sent')"),
  "tenant_activities": $(psql_q "SELECT count(*) FROM activities WHERE tenant_id = '$TENANT_ID'"),
  "backbone_webhook_events": $(psql_q "SELECT count(*) FROM webhook_events WHERE subscription_id = '$BACKBONE_SUB_ID'"),
  "backbone_webhook_events_distinct": $(psql_q "SELECT count(DISTINCT event_id) FROM webhook_events WHERE subscription_id = '$BACKBONE_SUB_ID'"),
  "backbone_webhook_events_delivered": $(psql_q "SELECT count(*) FROM webhook_events WHERE subscription_id = '$BACKBONE_SUB_ID' AND status = 'delivered'"),
  "backbone_parked_jobs": $(psql_q "SELECT count(*) FROM oban_jobs WHERE queue = 'backbone'"),
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
