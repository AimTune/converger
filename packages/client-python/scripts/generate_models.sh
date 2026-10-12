#!/usr/bin/env bash
# Generates Pydantic v2 models from the server's OpenAPI document into
# src/converger/_generated.py.
#
#   pip install -e '.[codegen]'
#   scripts/generate_models.sh [path/to/openapi.json]
#
# The document is priv/static/openapi.json, added by issue #45. Until it
# exists the hand-written models in src/converger/models.py are the API;
# after generation, models.py re-exports the generated classes under the
# same names (see the module docstring) and the conformance tests check that
# nothing changed for callers.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
spec="${1:-$here/../../priv/static/openapi.json}"

if [ ! -f "$spec" ]; then
  echo "No OpenAPI document at $spec (it is added by issue #45)." >&2
  exit 1
fi

datamodel-codegen \
  --input "$spec" \
  --input-file-type openapi \
  --output "$here/src/converger/_generated.py" \
  --output-model-type pydantic_v2.BaseModel \
  --target-python-version 3.10 \
  --use-standard-collections \
  --use-union-operator \
  --snake-case-field \
  --allow-population-by-field-name \
  --extra-fields allow \
  --use-schema-description \
  --disable-timestamp

echo "wrote src/converger/_generated.py"
