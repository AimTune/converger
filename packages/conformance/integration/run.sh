#!/usr/bin/env bash
# End-to-end SDK tests against a real Converger server.
#
#   packages/conformance/integration/run.sh [python] [go] [elixir]   (default: all three)
#
# Needs the dev database (docker compose up -d db; set DB_NAME to use a
# separate database, it is created and migrated), Elixir deps (mix deps.get)
# and, per SDK, Go, Python 3.10+ (or Docker with PYTHON_DOCKER=1) and Elixir.
# Starts the server with packages/conformance/integration/server.exs (which
# creates one tenant, client channel and signed webhook channel per SDK),
# waits for it, runs each SDK's integration test, then stops the server.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
here="$root/packages/conformance/integration"
fixtures="$here/fixtures.json"
port="${PORT:-4000}"
sdks=("$@")
[ ${#sdks[@]} -eq 0 ] && sdks=(python go elixir)

rm -f "$fixtures"
cd "$root"
mix ecto.create --quiet
mix ecto.migrate --quiet
PHX_SERVER=true PORT="$port" CONVERGER_FIXTURES="$fixtures" \
  mix run --no-halt packages/conformance/integration/server.exs >"$here/server.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if [ -f "$fixtures" ] && curl -fsS "http://localhost:$port/health/live" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$server" 2>/dev/null; then
    cat "$here/server.log"
    exit 1
  fi
  sleep 1
done
[ -f "$fixtures" ] || { echo "server did not start"; cat "$here/server.log"; exit 1; }

status=0
for sdk in "${sdks[@]}"; do
  echo "=== $sdk ==="
  case "$sdk" in
    python)
      if [ "${PYTHON_DOCKER:-0}" = "1" ]; then
        MSYS_NO_PATHCONV=1 docker run --rm \
          -v "$root:/w" -w /w/packages/client-python \
          -p 47801:47801 --add-host host.docker.internal:host-gateway \
          -e CONVERGER_FIXTURES=/w/packages/conformance/integration/fixtures.json \
          -e CONVERGER_BASE_URL="http://host.docker.internal:$port" \
          python:3.12-slim sh -c "pip install -q -e '.[test]' && python -m pytest -m integration -v" || status=1
      else
        (cd packages/client-python && CONVERGER_FIXTURES="$fixtures" python -m pytest -m integration -v) || status=1
      fi
      ;;
    go)
      (cd packages/client-go && CONVERGER_FIXTURES="$fixtures" go test -count=1 -run TestIntegration -v ./...) || status=1
      ;;
    elixir)
      (cd packages/client-elixir && CONVERGER_FIXTURES="$fixtures" mix test --only integration) || status=1
      ;;
    *)
      echo "unknown SDK $sdk"
      status=1
      ;;
  esac
done
exit "$status"
