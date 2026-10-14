#!/usr/bin/env bash
# Backbone benchmark matrix (issue #66, extends #34): runs load/run.sh for
# every backbone x node count and renders one table with load/report.js.
#
# Usage: load/matrix.sh                 (from anywhere; same requirements as run.sh)
#
#   LOAD_MATRIX_BACKBONES  backbones to run          ("native kafka")
#   LOAD_MATRIX_NODES      node counts to run        ("1 3")
#   LOAD_MATRIX_PUBLISH    1 writes the table to docs/benchmarks/backbone-matrix.md
#                          (only from a quiet machine or the nightly runner)
#   every load/run.sh variable (LOAD_PROFILE, LOAD_SCENARIOS, ...) applies to each run.
#
# Results: load/.run/matrix/<backbone>-<n>node.json and load/.run/matrix/report.md.
# Exit code: non-zero when any run failed a check (lost or duplicated messages).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BACKBONES="${LOAD_MATRIX_BACKBONES:-native kafka}"
NODE_COUNTS="${LOAD_MATRIX_NODES:-1 3}"
DIR="load/.run/matrix"
rm -rf "$DIR"
mkdir -p "$DIR"

log() { echo "[matrix $(date +%H:%M:%S)] $*"; }

status=0
built=0
files=()
for backbone in $BACKBONES; do
  for nodes in $NODE_COUNTS; do
    log "run: backbone $backbone, $nodes node(s)"
    code=0
    LOAD_BACKBONE="$backbone" LOAD_NODES="$nodes" LOAD_SKIP_BUILD="${LOAD_SKIP_BUILD:-$built}" \
      bash load/run.sh >"$DIR/$backbone-${nodes}node.log" 2>&1 || code=$?
    built=1
    if [ -f load/.run/out/results.json ]; then
      cp load/.run/out/results.json "$DIR/$backbone-${nodes}node.json"
      cp load/.run/out/report.md "$DIR/$backbone-${nodes}node.md"
      files+=("$DIR/$backbone-${nodes}node.json")
    fi
    if [ "$code" != 0 ]; then
      log "run failed (exit $code): see $DIR/$backbone-${nodes}node.log"
      status=1
    fi
    rm -rf load/.run/out
  done
done

if [ "${#files[@]}" = 0 ]; then
  log "no results"
  exit 1
fi

node load/report.js --title "Backbone matrix" --out "$DIR/report.md" "${files[@]}" || status=1
cat "$DIR/report.md"

if [ "${LOAD_MATRIX_PUBLISH:-0}" = "1" ]; then
  bash load/publish_matrix.sh "$DIR/report.md" "Measured with \`load/matrix.sh\` on $(hostname) ($(date -u +%Y-%m-%d))."
fi

exit "$status"
