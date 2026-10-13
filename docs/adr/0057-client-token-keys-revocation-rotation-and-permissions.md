---
title: "ADR-0057: Client token signing keys, revocation, refresh rotation and permissions"
sidebar_label: "0057 Client token hardening"
description: Converger tokens get dedicated signing keys with kid, a Postgres-backed revocation list cached in ETS on every node and fanned out over PubSub, refresh rotation with family-wide reuse detection, and a perms claim.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#52](https://github.com/AimTune/converger/issues/52) |
| **Pull request** | to be linked |
| **Related** | [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md), [ADR-0050](0050-openapi-spec-error-envelope-and-api-versioning.md) |

## Context and problem statement

Converger tokens (`Converger.Auth.ConvergerToken`) are the end-user credential of the client API, the WebSocket,
the native Protocol v1 endpoint, SSE and gRPC. Before this decision they were stateless 30-minute HS256 JWTs signed
with `SECRET_KEY_BASE`:

- **No revocation.** A leaked token stayed valid until it expired, and `POST /tokens/refresh` minted a new one from
  any valid token, so a leaked token could be kept alive forever. `GET /conversations/:id` did the same without
  even calling refresh: it returned a fresh 30-minute conversation token on every call.
- **No rotation or reuse detection** on refresh, so a stolen copy was indistinguishable from the real client.
- **One key for everything.** Tokens and admin/portal session cookies shared `SECRET_KEY_BASE`; rotating it logged
  out every WebSocket client, and there was no `kid` to roll a key over.
- **All or nothing.** Every token could read, post and type in its conversation; a read-only viewer token was
  impossible. The existing `scope` claim only means "follow the whole channel" (agent console).

The issue's acceptance criterion: a revoked token is rejected by REST and WebSocket within one second across nodes.
The admin and portal half of #52 (2FA, password reset, sessions) is a separate decision.

## Decision drivers

- Revocation visible on every node within a second, including live sockets.
- No per-request database query: token checks are on the hot path of every REST call and socket connect.
- No new infrastructure (no Redis requirement); work in a single node and in a libcluster cluster.
- Existing clients and SDKs keep working: tokens without new claims keep their meaning, the upgrade does not log
  anyone out.
- Detect a stolen token being used in parallel with the real client.

## Considered options

### Revocation store

1. **Postgres table + per-node ETS cache + PubSub fan-out + periodic resync.**
2. **Redis denylist** checked per request.
3. **Database query per verification.**
4. **Short token lifetimes only** (no revocation).

### Permissions

1. **New `perms` claim** (list of `read`, `write`, `typing`); `scope` keeps its meaning.
2. **Overload `scope`** as an OAuth-style space-separated list (`"channel read write"`).

### Refresh semantics

1. **Rotation with a grace period**, reuse after the grace period revokes the family.
2. **Strict rotation**: the old token is invalid immediately, any later use revokes the family.
3. **No rotation**, revocation only.

### Pros and cons of the options

#### Postgres + ETS + PubSub (chosen)

- Good, because checks are ETS lookups; the broadcast reaches other nodes in milliseconds; the periodic resync and
  the full load on start repair a missed broadcast. Same shape as the cluster rate limiter
  ([ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)).
- Good, because the table's primary key makes rotation atomic across nodes (exactly one of two concurrent refreshes
  inserts the row), which reuse detection needs.
- Bad, because a node that boots while the database is down starts with an empty cache and accepts tokens revoked
  elsewhere until its next sync.
- Bad, because every refresh writes a row (rows live 31 minutes).

#### Redis denylist

- Good, because it is the textbook approach.
- Bad, because Redis is optional in Converger (only the `redis_streams` channel uses it) and a per-request round
  trip is slower than ETS. Rejected.

#### Query per verification

- Bad, because it adds a query to every request and every socket connect, the opposite of
  [ADR-0044](0044-bulkheaded-pools-and-graceful-degradation-under-database-pressure.md). Rejected.

#### Short lifetimes only

- Bad, because the refresh loophole keeps a leaked token alive regardless of lifetime. Rejected.

#### `perms` claim vs. overloading `scope`

- `scope: "channel"` is already issued, checked in several places and sent by the SDKs. Turning it into a list
  would change its meaning for existing tokens and clients. A separate `perms` claim is additive: no claim means
  every permission, as before.

#### Grace period vs. strict rotation

- Strict rotation breaks legitimate clients: a request already in flight with the old token, or two tabs sharing a
  token that refresh at once, would revoke the family and log the user out. A short grace period (30 s) keeps those
  working, and reuse after it is still detected. The cost is a 30 s window in which a stolen copy also works.

## Decision

- **Keys.** `TOKEN_SIGNING_KEYS` lists `{kid, secret}` pairs; the first signs and puts its `kid` in the header,
  all verify. Without it, `SECRET_KEY_BASE` signs under kid `default`. Tokens without a `kid` (issued before this
  change) verify with `SECRET_KEY_BASE` while `TOKEN_ACCEPT_UNKEYED` is true. Legacy tokens are untouched.
- **Claims.** Every token gets a `jti` and a family id `fam` (the `jti` of the generated token). Derived tokens
  (`POST /conversations`, `GET /conversations/:id`) inherit `fam`, `user_id` and `perms` and never outlive the
  token that asked for them (`exp` capped), which closes the `GET /conversations/:id` loophole.
- **Revocation store.** `revoked_tokens` rows: `fam:<family>`, `user:<channel_id>:<user_id>` (rejects tokens with
  `iat` up to the revocation), `jti:<jti>` with kind `rotated`. Cached per node in
  `Converger.Auth.RevocationCache` (ETS), written locally before the API answers, broadcast on
  `Converger.PubSub`, re-read incrementally every 60 s, fully loaded on start, pruned daily once expired.
  `ConvergerToken.verify_token/2` checks it on every verification, so REST, the Phoenix sockets, the native
  endpoint, SSE and gRPC all reject revoked tokens.
- **Revoke API.** `POST /api/v1/converger/tokens/revoke`: a token revokes its own family (logout); the channel
  secret revokes a given token's family or every token of an end user (ban). The subject's sockets are
  disconnected through the per-subject socket ids of [ADR-0020](0020-per-subject-socket-ids-and-presence.md).
- **Refresh rotation.** Refresh inserts the `jti` row (kind `rotated`). The rotated token works for
  `TOKEN_ROTATION_GRACE_SECONDS` (30); afterwards it is `token_rotated` (REST `401 token_revoked`). A refresh of a
  token rotated longer ago than the grace period revokes the family (`token_reused`). Only the refresh route
  (`allow_rotated: true` on `ConvergerAuth`) lets a rotated token through to detect this.
- **Permissions.** `perms` claim, set with `permissions` on generate. Enforced by
  `ConvergerWeb.Plugs.RequirePermission` on the REST controllers, in `ConvergerChannel` (join needs `read`;
  `postActivity`/`frame` need `write`; `typing` needs `typing`) and in `ConvergerWeb.Protocol.Session` (`hello` needs
  `read`, starting a conversation `write`, `text` frames `write`, `typing` frames `typing`). New error codes
  `insufficient_permission` (403, protocol 2004) and `token_revoked` (401, protocol 2005).

## Consequences

### Positive

- A revoked token is refused by every node within a second, and its sockets are closed; the two-node `:peer` suite
  asserts it.
- A stolen token used in parallel with the real client is detected at the next refresh, and both are cut off.
- Rotating `SECRET_KEY_BASE` no longer disconnects WebSocket clients; client keys roll over without downtime.
- Read-only viewer tokens (`["read"]`) and send-only bots (`["write"]`) are possible.

### Negative and trade-offs

- One small write per refresh and per revocation. The table holds about one row per refresh in the last 31 minutes.
- During the grace period a stolen copy of a just-refreshed token still works.
- `iat` has a one-second resolution: a token generated for a user in the same second as that user's revocation
  is also rejected.
- A node that starts while the database is unavailable accepts revoked tokens until its next sync (at most
  `sync_interval_ms`).
- Tokens without `jti` cannot be revoked by family; none are issued, and pre-#52 tokens all had a `jti` (Joken's
  default claims).

### Follow-ups

- Admin and tenant portal hardening (2FA, password reset, policy, server-side sessions): the second part of
  [#52](https://github.com/AimTune/converger/issues/52), its own ADR.
- Server SDKs (Elixir, Go, Python) do not expose `permissions` and `revoke` yet.

## Implementation

- Keys: [`Converger.Auth.Signer`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/signer.ex);
  `TOKEN_SIGNING_KEYS`, `TOKEN_ACCEPT_UNKEYED` in `config/runtime.exs`.
- Tokens: [`Converger.Auth.ConvergerToken`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/converger_token.ex)
  (`derived_opts/1`, `refresh_claims/1`, `permitted?/2`).
- Revocations: [`Converger.Auth.Revocations`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/revocations.ex),
  [`Converger.Auth.RevocationCache`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/revocation_cache.ex),
  migration `20261013100000_create_revoked_tokens.exs`, pruning in `Converger.Retention.prune/1`.
- API: `ConvergerWeb.ConvergerAPI.TokenController` (`revoke`, rotating `refresh`),
  `ConvergerWeb.Plugs.ConvergerAuth` (`allow_rotated`), `ConvergerWeb.Plugs.RequirePermission`,
  `ConvergerWeb.Sockets.disconnect_claims/1`.
- Tests: `test/converger/auth/converger_token_test.exs`,
  `test/converger_web/controllers/client_token_security_test.exs`,
  `test/converger_web/channels/converger_channel_permissions_test.exs`,
  `test/converger_web/protocol_token_security_test.exs`, and the cross-node case in
  `test/cluster/multi_node_test.exs`.

## Links

- [Client tokens](../security/client-tokens.md)
- [Client API: permissions, refresh, revoke](../api/client-api.md#permissions)
- [Protocol v1 error codes](../protocol/v1.md#122-error-codes)
- [Configuration: client tokens](../operations/configuration.md#client-tokens)
- RFC 9700 (OAuth 2.0 Security Best Current Practice), refresh token rotation and reuse detection
