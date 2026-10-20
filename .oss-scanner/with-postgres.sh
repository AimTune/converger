#!/usr/bin/env bash
# Starts the PostgreSQL cluster that lives inside the OSS Scanner image (see
# .oss-scanner/Dockerfile) if it is not running, waits until it accepts
# connections on 127.0.0.1:5432, then runs the given command (default: bash).
#
#   .oss-scanner/with-postgres.sh mix test
#   MIX_ENV=dev .oss-scanner/with-postgres.sh mix phx.server
set -euo pipefail

PG_VERSION="${PG_VERSION:-17}"

if ! pg_ctlcluster "$PG_VERSION" main status >/dev/null 2>&1; then
  pg_ctlcluster "$PG_VERSION" main start
fi

for _ in $(seq 1 60); do
  if pg_isready -q -h 127.0.0.1 -p 5432; then
    break
  fi
  sleep 0.5
done
pg_isready -h 127.0.0.1 -p 5432

if [ "$#" -eq 0 ]; then
  exec bash
fi
exec "$@"
