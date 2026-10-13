#!/usr/bin/env bash
# Regenerates the Elixir modules of the gRPC transport (ADR-0056) from
# priv/protos/**/*.proto into lib/converger_web/grpc/gen/.
#
# Needs `protoc` and the `protoc-gen-elixir` plugin of the `protobuf` Hex
# package (the version in mix.lock). Without a local toolchain it runs them
# in Docker, in the builder image of the Dockerfile:
#
#   priv/protos/generate.sh            # protoc in Docker
#   LOCAL=1 priv/protos/generate.sh    # protoc and protoc-gen-elixir on PATH
#
# Local plugin install: `mix escript.install hex protobuf 0.17.1`
# (protoc-gen-elixir lands in ~/.mix/escripts).
set -euo pipefail

cd "$(dirname "$0")/../.."

PROTOBUF_VSN="0.17.1"
OUT="lib/converger_web/grpc/gen"
IMAGE="hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim"

protoc_elixir() {
  # plugins=grpc also generates the ChannelStream.Service and .Stub modules.
  protoc -I priv/protos ${PROTOC_INCLUDE:+-I "$PROTOC_INCLUDE"} --elixir_out=plugins=grpc,one_file_per_module=true:"$OUT" \
    $(cd priv/protos && find . -name '*.proto' | sed 's|^\./||')
}

if [ "${INSIDE_DOCKER:-}" = "1" ]; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends protobuf-compiler libprotobuf-dev >/dev/null
  mix local.hex --force >/dev/null
  mix escript.install --force hex protobuf "$PROTOBUF_VSN" >/dev/null
  export PATH="$HOME/.mix/escripts:$PATH" PROTOC_INCLUDE=/usr/include
  protoc_elixir
  exit 0
fi

mkdir -p "$OUT"
rm -rf "${OUT:?}"/*

if [ "${LOCAL:-}" = "1" ]; then
  protoc_elixir
else
  # $(pwd -W) gives a Docker-mountable path in Git Bash on Windows.
  ROOT="$(pwd -W 2>/dev/null || pwd)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "$ROOT":/src -w /src -e INSIDE_DOCKER=1 \
    "$IMAGE" bash priv/protos/generate.sh
fi

mix format $(find "$OUT" -name '*.ex')
