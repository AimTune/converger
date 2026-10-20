# Build for Anthropic's OSS Scanner (https://red.anthropic.com/oss-scanner/).
# See docs/security/oss-scanner.md and ADR-0078. Enrolment: projects/converger
# in https://github.com/anthropics/oss-scanner.
#
# This is NOT the release image (that is the root Dockerfile). The scanner
# builds this file with the repository as the build context (`.dockerignore`
# applies) while the network is available, then analyses the image with no
# network at all. So everything the suite, the compiler or a running node could
# need is fetched here: Hex and git dependencies for the dev and test
# environments, the standalone tailwind and esbuild binaries, and a PostgreSQL
# server inside the image.
#
# In the finished image (as root, in /src):
#   .oss-scanner/with-postgres.sh mix test             the suite (MIX_ENV=test)
#   .oss-scanner/with-postgres.sh                      a shell with Postgres up
#   MIX_ENV=dev .oss-scanner/with-postgres.sh mix phx.server   the app on :4000
#
# Keep the versions in sync with .tool-versions and the root Dockerfile.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=bookworm-20260824-slim
ARG POSTGRES_VERSION=17

FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}

ARG POSTGRES_VERSION
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PG_VERSION=${POSTGRES_VERSION}

# build-essential: the bcrypt_elixir NIF. cmake: brod's crc32cer NIF (Kafka
# client). git: the heroicons and daisyUI git dependencies. PostgreSQL comes
# from PGDG so the image runs the major version CI tests against (17).
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg build-essential cmake git procps \
  && install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /etc/apt/keyrings/apt.postgresql.org.asc \
  && echo "deb [signed-by=/etc/apt/keyrings/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends "postgresql-${POSTGRES_VERSION}" \
  && rm -rf /var/lib/apt/lists/*

# The Debian package created the cluster "<version>/main" on 127.0.0.1:5432.
# config/dev.exs and config/test.exs connect as postgres/postgres by default.
RUN pg_ctlcluster "${PG_VERSION}" main start \
  && su postgres -c "psql -v ON_ERROR_STOP=1 -c \"ALTER USER postgres PASSWORD 'postgres'\"" \
  && pg_ctlcluster "${PG_VERSION}" main stop

RUN mix local.hex --force \
  && mix local.rebar --force

# scanner contract: the checkout lives inside the image, at /src
WORKDIR /src

# Dependencies first, so a source change does not refetch them. `deps.get`
# fetches every environment's dependencies listed in mix.lock.
COPY mix.exs mix.lock ./
RUN mix deps.get

COPY . /src
RUN chmod +x .oss-scanner/*.sh

# The test build (test/support is compiled too) and the dev build, with the
# admin/portal assets, so `mix phx.server` works offline as well.
RUN MIX_ENV=test mix compile
RUN MIX_ENV=dev mix do compile + assets.setup + assets.build

# Create and migrate both databases, then run the suite once so the image is
# known to work. A failing test does not fail the build (the log says so);
# a failing build is emailed to the primary contact.
RUN .oss-scanner/with-postgres.sh sh -c ' \
      MIX_ENV=dev mix do ecto.create --quiet + ecto.migrate --quiet \
      && (MIX_ENV=test mix test || echo "WARNING: mix test reported failures")' \
  && pg_ctlcluster "${PG_VERSION}" main stop

ENV MIX_ENV=test
CMD ["bash"]
