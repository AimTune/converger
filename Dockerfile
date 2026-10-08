# Keep in sync with .tool-versions.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=bookworm-20260824-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# --- Build Stage ---
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

RUN mix compile

COPY config/runtime.exs config/
# bin/server and bin/migrate overlays (see docs/deployment.md).
COPY rel rel
RUN chmod +x rel/overlays/bin/*

RUN mix release

# --- Runtime Stage ---
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/converger ./

USER nobody

# The default command only starts the server. Migrations are a separate,
# one-off step: run `/app/bin/migrate` (an init container, pre-deploy job or
# the compose `migrate` service) before rolling out new replicas, so a
# rolling deploy never runs migrations from several replicas at once.
CMD ["/app/bin/server"]
