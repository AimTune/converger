---
title: "ADR-0057: Pluggable password hasher with a pure-Elixir option, and a dev container"
sidebar_label: "0057 Password hasher and dev container"
description: Password hashing goes through Converger.Accounts.PasswordHasher (bcrypt by default, PBKDF2 when CONVERGER_PASSWORD_HASHER=pbkdf2 leaves the bcrypt NIF out of the build), verification follows the stored hash's prefix, and .devcontainer/ gives every OS a Linux toolchain with Postgres.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#53](https://github.com/AimTune/converger/issues/53) |
| **Pull request** | [#159](https://github.com/AimTune/converger/pull/159) |
| **Related** | [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md), [ADR-0023](0023-platform-and-dependency-baseline.md) |

## Context and problem statement

On a fresh Windows machine, `mix deps.get && mix compile` stops at the first NIF that needs a C toolchain:

```text
==> bcrypt_elixir
** (Mix) "nmake" not found in the path.
```

`bcrypt_elixir` hashes the passwords of admin and tenant users. Its NIF is built with MSVC and `nmake` on Windows,
so a contributor needs the Visual Studio Build Tools and a Developer shell before running a single test. The
workaround was documented, but it is heavy for someone who only wants to run the test suite. `bcrypt_elixir` is the
only dependency that blocks the build: `brod`'s `crc32cer` NIF does not build on Windows either, but it is loaded only
when a Kafka channel runs, and the compile goes through without it ([ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md)).

The schemas called `Bcrypt` directly (`AdminUser`, `TenantUser`), so there was no way to choose another algorithm.

## Decision drivers

- A contributor on any OS can build and test without installing a C compiler.
- Production hashing does not change: bcrypt stays the default, and existing hashes keep verifying.
- No compile-time warnings or code paths that differ between the two builds beyond the hasher.
- One switch that controls both the dependency set and the runtime choice.

## Considered options

1. **Document the MSVC setup only.** Already done; does not remove the requirement.
2. **Switch to `argon2_elixir`.** Also a C NIF with the same Windows problem.
3. **A hasher behind a facade, with `pbkdf2_elixir` as a pure-Elixir option chosen by an environment variable that
   also drops `bcrypt_elixir` from the deps.**
4. **Replace bcrypt with PBKDF2 everywhere.** Removes the NIF but changes production hashing and forces a rehash.

Plus, independent of the hasher: a **dev container** (`.devcontainer/`) with the pinned toolchain, the C tools and
Postgres, so every OS gets a Linux environment that matches CI.

## Decision

Chosen option: **3**, plus the dev container.

- `Converger.Accounts.PasswordHasher` hashes new passwords with the module in `config :converger, :password_hasher`
  (any `Comeonin` implementation; `Bcrypt` or `Pbkdf2`). `AdminUser` and `TenantUser` call it instead of `Bcrypt`.
- **Verification follows the stored hash, not the setting**: `$2…` hashes go to `Bcrypt`, `$pbkdf2-…` hashes to
  `Pbkdf2`. Both kinds can sit in the same table, so switching the setting never locks out existing users while both
  libraries are compiled. If a hash needs a library that is not compiled in, the login fails after a dummy
  verification (same timing as an unknown user) and a warning is logged.
- `CONVERGER_PASSWORD_HASHER` (`bcrypt` by default, or `pbkdf2`) is read in `mix.exs` and in `config/config.exs`.
  With `pbkdf2`, `bcrypt_elixir` is not a dependency at all, so nothing needs a C compiler, and new hashes are
  PBKDF2-SHA512 (`pbkdf2_elixir` defaults: 160,000 iterations, 16-byte salt). Any other value stops `mix` with an error.
- `pbkdf2_elixir` is always a dependency. It is pure Elixir on top of `:crypto`, it keeps `mix.lock` the same in both
  modes (CI's `deps.unlock --check-unused` sees one lock), and it lets a bcrypt build verify PBKDF2 hashes made in
  a pbkdf2 build that shares the database.
- `.devcontainer/` (VS Code Dev Containers, GitHub Codespaces, the `devcontainer` CLI): the `hexpm/elixir` image of
  the root `Dockerfile` with build-essential, cmake and inotify-tools, a non-root `vscode` user, and a Postgres 17
  service with the dev/test defaults. `deps/` and the build root (`MIX_DEPS_PATH`, `MIX_BUILD_ROOT`) live in named
  volumes, not in the bind-mounted checkout, so Linux artifacts never mix with a host's Windows or macOS `_build`.

## Consequences

### Positive

- A Windows contributor runs `$env:CONVERGER_PASSWORD_HASHER = "pbkdf2"; mix setup; mix test` in a plain PowerShell
  window. The whole suite passes in that mode.
- Production behavior and stored hashes are unchanged; the release image still builds bcrypt.
- The dev container gives macOS, Linux and Windows the same environment as CI, including the Kafka NIF.
- Moving to another `Comeonin` hasher later is a config change plus a prefix clause.

### Negative and trade-offs

- Two builds exist. The pbkdf2 build cannot verify bcrypt hashes, so a database seeded by a bcrypt build has to be
  reseeded (or the passwords reset) before logging in from a pbkdf2 build. Tests are unaffected: they create their
  users.
- The variable is read at compile time. Changing it needs `mix deps.get` and recompiles the project (`config.exs`
  changes); a separate `MIX_BUILD_PATH` per mode avoids recompiling back and forth.
- Nothing stops a production build with `CONVERGER_PASSWORD_HASHER=pbkdf2`. PBKDF2-SHA512 at 160,000 iterations is
  an accepted password hash, but bcrypt is the documented and tested production setting.
- One more dependency (`pbkdf2_elixir`, sharing `comeonin` with `bcrypt_elixir`).

### Follow-ups

- Rehash on login when a stored hash is not the configured algorithm, if a deployment ever switches algorithms
  for real. Not needed while the second hasher is a development aid.

## Implementation

- [`lib/converger/accounts/password_hasher.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/accounts/password_hasher.ex):
  the facade; [`admin_user.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/accounts/admin_user.ex)
  and [`tenant_user.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/accounts/tenant_user.ex) use it.
- [`mix.exs`](https://github.com/AimTune/converger/blob/main/mix.exs) `password_hasher_deps/0`;
  [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs) `:password_hasher`;
  [`config/test.exs`](https://github.com/AimTune/converger/blob/main/config/test.exs) sets one PBKDF2 round, as it
  already did for bcrypt ([ADR-0023](0023-platform-and-dependency-baseline.md)).
- [`test/converger/accounts/password_hasher_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/accounts/password_hasher_test.exs):
  hashing with each configured module, cross-verification, and the bcrypt-not-compiled path (that test is compiled
  only in a pbkdf2 build).
- [`.devcontainer/`](https://github.com/AimTune/converger/tree/main/.devcontainer): `devcontainer.json`,
  `compose.yml`, `Dockerfile`.
- Verified: the full suite on Windows with `CONVERGER_PASSWORD_HASHER=pbkdf2` and no MSVC on `PATH`, and the full
  suite inside the dev container (built with the `devcontainer` CLI).

## Links

- [Getting started: per-OS notes](../getting-started.md#per-os-notes)
- [Contributing: dev container](../contributing.md#dev-container)
- [Security overview](../security/overview.md)
