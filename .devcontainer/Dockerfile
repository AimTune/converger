# Development image for the dev container (docs/contributing.md#dev-container).
# Keep in sync with .tool-versions and the root Dockerfile.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=bookworm-20260824-slim

FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}

# build-essential: bcrypt_elixir NIF. cmake: brod's crc32cer NIF (Kafka).
# inotify-tools: file watching for the Phoenix code reloader.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential cmake git inotify-tools postgresql-client ca-certificates locales sudo \
  && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Non-root user. deps/ and the build root live outside the bind-mounted
# workspace, in volumes (see compose.yml), so the Linux artifacts never mix
# with a host checkout's Windows or macOS ones.
RUN groupadd --gid $USER_GID $USERNAME \
  && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
  && echo "$USERNAME ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
  && mkdir -p /home/$USERNAME/mix/deps /home/$USERNAME/mix/build \
  && chown -R $USERNAME:$USERNAME /home/$USERNAME/mix

USER $USERNAME

ENV MIX_DEPS_PATH=/home/$USERNAME/mix/deps \
    MIX_BUILD_ROOT=/home/$USERNAME/mix/build \
    ERL_AFLAGS="-kernel shell_history enabled"

RUN mix local.hex --force && mix local.rebar --force
