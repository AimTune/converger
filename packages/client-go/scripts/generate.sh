#!/usr/bin/env bash
# Generates typed models and a low-level client from the server's OpenAPI
# document with oapi-codegen into internal/gen.
#
#   scripts/generate.sh [path/to/openapi.json]
#
# The document is priv/static/openapi.json, added by issue #45. Until it
# exists the hand-written types in models.go are the API; after generation
# they become aliases of the generated ones, and the conformance tests check
# that nothing changed for callers.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
spec="${1:-$here/../../priv/static/openapi.json}"

if [ ! -f "$spec" ]; then
  echo "No OpenAPI document at $spec (it is added by issue #45)." >&2
  exit 1
fi

mkdir -p "$here/internal/gen"
cd "$here"
go run github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.4.1 -config oapi-codegen.yaml "$spec"
gofmt -w internal/gen
# The generated client needs the oapi-codegen runtime.
go get github.com/oapi-codegen/runtime@v1.1.1
go mod tidy
echo "wrote internal/gen/gen.go"
