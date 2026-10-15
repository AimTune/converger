#!/usr/bin/env bash
# Partition archive and drop on a 100M-row dataset (issue #192, ADR-0034).
#
# Starts its own Postgres 17 and MinIO (compose project converger-p100m,
# ports 15432 / 19000, named volumes), migrates the schema, seeds
# P100M_ROWS rows with generate_series, then runs the production retention
# path (Converger.Retention.run/1: detach, archive to MinIO, verify, drop)
# for the oldest month while writers insert into the current month, reads
# the archive back and re-imports a tenant. Results:
# test/load/partition_100m/.run/out/results.json and report.md.
# See docs/benchmarks/index.md.
#
# Usage: test/load/partition_100m/run.sh                (from anywhere)
#        P100M_ROWS=1000000 test/load/partition_100m/run.sh   (smoke run)
#
# Knobs (env), defaults in brackets:
#   P100M_ROWS (or ROWS)       rows in activities + deliveries   [100000000]
#   P100M_ACTIVITY_SHARE       share of activities               [0.6]
#   P100M_MONTHS               monthly partitions seeded          [6]
#   P100M_TENANTS              tenants                            [8]
#   P100M_CONVERSATIONS        conversations per tenant           [2000]
#   P100M_SEED_BATCH           rows per INSERT ... SELECT         [1000000]
#   P100M_SEED_JOBS            partitions seeded in parallel      [4]
#   P100M_WRITERS              concurrent writers                 [8]
#   P100M_WRITER_RATE          inserts per second per writer      [25]
#   P100M_BASELINE_S           writer baseline before the run     [30]
#   P100M_AFTER_S              writers kept running afterwards     [15]
#   P100M_REIMPORT_TENANTS     tenants re-imported from the archive [1]
#   P100M_PART_ROWS            rows per archive object            [50000]
#   P100M_DB_PORT / P100M_MINIO_PORT                              [15432 / 19000]
#   P100M_SHARED_BUFFERS, P100M_EFFECTIVE_CACHE_SIZE,
#   P100M_MAINTENANCE_WORK_MEM, P100M_MAX_WAL_SIZE   Postgres settings
#   P100M_BYTES_PER_ROW        disk estimate per row, from a smoke run [600]
#   P100M_FORCE                1 starts even if the disk check fails [0]
#   P100M_KEEP                 1 keeps containers and volumes; a later run
#                              with the same seed settings reuses the data [0]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

PROJECT="converger-p100m"
HERE="test/load/partition_100m"
RUN_DIR="$HERE/.run"
OUT="$RUN_DIR/out"

export P100M_ROWS="${P100M_ROWS:-${ROWS:-100000000}}"
export P100M_MONTHS="${P100M_MONTHS:-6}"
export P100M_DB_PORT="${P100M_DB_PORT:-15432}"
export P100M_MINIO_PORT="${P100M_MINIO_PORT:-19000}"
export P100M_MAX_WAL_SIZE="${P100M_MAX_WAL_SIZE:-16GB}"
BYTES_PER_ROW="${P100M_BYTES_PER_ROW:-600}"
# Archive objects per archived row (gzip JSON Lines), from a smoke run.
ARCHIVE_BYTES_PER_ROW="${P100M_ARCHIVE_BYTES_PER_ROW:-100}"

log() { echo "[p100m $(date +%H:%M:%S)] $*"; }

dc() {
  # MSYS_NO_PATHCONV: Git Bash on Windows must not rewrite container paths.
  MSYS_NO_PATHCONV=1 docker compose -p "$PROJECT" -f "$HERE/docker-compose.yml" "$@"
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1024 / 1024 / 1024 }'; }

cleanup() {
  local code=$?
  mkdir -p "$OUT"
  dc logs --no-color db >"$OUT/postgres.log" 2>&1 || true
  if [ "${P100M_KEEP:-0}" != "1" ]; then
    log "tearing down containers and volumes (P100M_KEEP=1 keeps them)"
    dc down -v --remove-orphans >/dev/null 2>&1 || true
  else
    log "keeping $PROJECT (tear down: docker compose -p $PROJECT -f $HERE/docker-compose.yml down -v)"
  fi
  exit "$code"
}

for tool in docker mix awk; do
  command -v "$tool" >/dev/null || { log "$tool is required"; exit 2; }
done

case "$P100M_ROWS" in
  '' | *[!0-9_]*) log "P100M_ROWS must be a number"; exit 2 ;;
esac
ROWS_N="${P100M_ROWS//_/}"

rm -rf "$OUT"
mkdir -p "$OUT"
trap cleanup EXIT

log "starting Postgres and MinIO ($PROJECT, ports $P100M_DB_PORT and $P100M_MINIO_PORT)"
if ! dc up -d --wait >"$OUT/compose-up.log" 2>&1; then
  cat "$OUT/compose-up.log"
  exit 1
fi

# --- disk check -------------------------------------------------------------
# Data and WAL go to the Docker disk (the pgdata volume), the archive to the
# MinIO volume on the same disk.
read -r DISK_TOTAL DISK_AVAIL < <(dc exec -T db df -Pk /var/lib/postgresql/data |
  awk 'NR == 2 { print $2 * 1024, $4 * 1024 }')
WAL_BYTES="$(awk -v s="$P100M_MAX_WAL_SIZE" 'BEGIN {
  n = s + 0; u = s; gsub(/[0-9]/, "", u)
  m = (u == "kB") ? 1024 : (u == "MB") ? 1024^2 : (u == "GB") ? 1024^3 : (u == "TB") ? 1024^4 : 1
  printf "%.0f", n * m }')"
NEED="$(awk -v r="$ROWS_N" -v b="$BYTES_PER_ROW" -v a="$ARCHIVE_BYTES_PER_ROW" -v m="$P100M_MONTHS" -v w="$WAL_BYTES" \
  'BEGIN { printf "%.0f", (r * b + w + r / m * a) * 1.2 }')"
NEED_100M="$(awk -v b="$BYTES_PER_ROW" -v a="$ARCHIVE_BYTES_PER_ROW" -v m="$P100M_MONTHS" -v w="$WAL_BYTES" \
  'BEGIN { r = 100000000; printf "%.0f", (r * b + w + r / m * a) * 1.2 }')"
log "Docker disk: $(gib "$DISK_AVAIL") free of $(gib "$DISK_TOTAL")"
log "estimated need for $ROWS_N rows: $(gib "$NEED") (100M rows: $(gib "$NEED_100M"); $BYTES_PER_ROW B/row data, max_wal_size $P100M_MAX_WAL_SIZE, archive, +20%)"
if [ "$DISK_AVAIL" -lt "$NEED" ]; then
  if [ "${P100M_FORCE:-0}" = "1" ]; then
    log "WARNING: not enough free disk, continuing because P100M_FORCE=1"
  else
    log "not enough free disk on the Docker disk; free space, enlarge the Docker disk, lower P100M_ROWS, or set P100M_FORCE=1"
    exit 3
  fi
fi

# --- hardware -----------------------------------------------------------------
host_cpu() {
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1).Name" 2>/dev/null | tr -d '\r'
  elif [ -r /proc/cpuinfo ]; then
    awk -F': ' '/model name/ { print $2; exit }' /proc/cpuinfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n machdep.cpu.brand_string 2>/dev/null
  fi
}
host_mem() {
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" 2>/dev/null | tr -d '\r'
  elif [ -r /proc/meminfo ]; then
    awk '/MemTotal/ { print $2 * 1024; exit }' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null
  fi
}
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

HOST_MEM="$(host_mem || true)"
cat >"$OUT/hardware.json" <<EOF
{
  "host_os": "$(json_str "$(uname -srm)")",
  "host_cpu": "$(json_str "$(host_cpu || true)")",
  "host_memory_bytes": ${HOST_MEM:-null},
  "docker_cpus": $(docker info --format '{{.NCPU}}'),
  "docker_memory_bytes": $(docker info --format '{{.MemTotal}}'),
  "docker_version": "$(json_str "$(docker version --format '{{.Server.Version}}')")",
  "docker_os": "$(json_str "$(docker info --format '{{.OperatingSystem}}')")",
  "kernel": "$(json_str "$(docker info --format '{{.KernelVersion}}')")",
  "disk_total_bytes": $DISK_TOTAL,
  "disk_avail_bytes": $DISK_AVAIL,
  "disk_need_estimate_bytes": $NEED
}
EOF

# --- run ----------------------------------------------------------------------
# The measurement is an ExUnit module, so it calls the production code
# (Converger.Retention, Converger.Archive) against this database. `mix test`
# creates and migrates the database first.
log "migrating, seeding and running (output below)"
export MIX_ENV=test
export DB_HOSTNAME=127.0.0.1
export DB_PORT="$P100M_DB_PORT"
export DB_NAME=converger_p100m
export DB_USERNAME=postgres
export DB_PASSWORD=postgres
export P100M_CONFIRM=1
export P100M_OUT="$OUT"
export P100M_HARDWARE="$OUT/hardware.json"
export P100M_MINIO_ENDPOINT="http://127.0.0.1:$P100M_MINIO_PORT"

started=$(date +%s)
log "migrating (log: $OUT/migrate.log)"
if ! { mix ecto.create --quiet && mix ecto.migrate --quiet; } >"$OUT/migrate.log" 2>&1; then
  tail -n 40 "$OUT/migrate.log"
  log "migration failed"
  exit 1
fi
mix test "$HERE/partition_100m_test.exs" --only partition_100m --seed 0
log "done in $(($(date +%s) - started)) s: $OUT/report.md, $OUT/results.json"
