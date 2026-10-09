---
title: "ADR-0026: One client socket stack; the legacy socket and token family are deprecated"
sidebar_label: "0026 One client socket stack"
description: The Converger API socket becomes the only implementation of the client protocol, gains sending over the socket, and the legacy socket, conversation and channel tokens are deprecated with per-use warnings; legacy token verifiers check the token's shape.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#23](https://github.com/AimTune/converger/issues/23) |
| **Pull request** | to be filled at merge |
| **Related** | [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

## Context and problem statement

Converger had two client WebSocket stacks and two token families:

| | Legacy | Converger API |
| --- | --- | --- |
| Socket | `/socket`, `ConvergerWeb.UserSocket` | `/socket/converger`, `ConvergerWeb.ConvergerSocket` |
| Topic / channel | `conversation:<id>`, `ConversationChannel` | `converger:conversation:<id>`, `ConvergerChannel` |
| Token | `Converger.Auth.Token` (`x-channel-token`, `POST /api/v1/tokens`) | `Converger.Auth.ConvergerToken` (`Bearer`, `/api/v1/converger/tokens/*`) |
| Frames | `new_activity` | `activitySet` with a watermark |
| Resume | `last_activity_id` | watermark |
| Sending | `new_activity` push with a reply | REST only |

They duplicated authorization, drifted in payload shape, and every document
and SDK had to explain both. Protocol v1 (#21, [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md))
is built on the Converger API stack (#22), so the legacy stack has no future.
The only capability the Converger API socket lacked was sending with a reply.

While moving the tests, we found that the legacy verifier
(`Converger.Auth.Token.verify_token/1`) only checked the signature. All tokens
share one signer, so an end user's conversation token or Converger API token
passed `x-channel-token` authentication: it acted as the whole tenant on the
tenant API (routing rules, any conversation's activities) and could call
`POST /api/v1/tokens` to mint tokens for other conversations of the channel
under any user id.

## Decision drivers

- One implementation of the client protocol, so #22 to #28 are built once.
- Existing integrations keep working until a removal date that is announced
  in advance (protocol v1, section 13.3).
- Operators can see who still uses a deprecated surface before it is removed.
- An end user's token must never act as the tenant.

## Considered options

1. **Deprecate the legacy stack, add sending to the Converger API socket,
   log every use** - the legacy code stays as it is until removal.
2. **Make the legacy socket a thin alias of the Converger API socket** -
   translate `new_activity` / `last_activity_id` into the new stack.
3. **Remove the legacy stack now** - one breaking release.

### Pros and cons of the options

#### Option 1

- Good, because no existing client breaks before the announced removal.
- Good, because the new code (sending) lives only in the stack that stays.
- Bad, because the legacy code stays in the tree for at least two minor
  releases.

#### Option 2

- Good, because only one channel module would run.
- Bad, because the translation layer is new code with its own bugs, written
  for a surface that is removed anyway, and its frames (`new_activity` with
  the canonical map) still differ from `activitySet`.

#### Option 3

- Good, because it removes the most code.
- Bad, because it breaks every legacy client without a migration window,
  against the deprecation policy of protocol v1.

## Decision

Chosen option: **"Deprecate, add sending, log every use"**.

- `ConvergerChannel` handles the `postActivity` event: a Direct Line-style
  activity is stored through `Activities.create_client_activity/2` (the
  pipeline is the only delivery path, [ADR-0003](0003-pipeline-is-the-only-delivery-path.md)),
  and the reply carries `id`, `seq` and `watermark`. The sender is the token's
  verified `user_id`, else `from.id`, else `"user"` (protocol v1, section 3.2).
  An optional `clientId` (protocol v1 syntax) is stored as
  `ws:<sender>:<clientId>`, like the legacy `idempotency_key`. Sends share the
  tenant's `activity_create` rate-limit bucket with REST.
- Deprecated, removed no earlier than two minor releases and 6 months after
  this change: `/socket` (`UserSocket`, `ConversationChannel`),
  `POST /api/v1/tokens`, and every `x-channel-token` use (channel tokens on
  `POST /api/v1/conversations` and on the tenant API). The tenant API with
  `x-api-key` is **not** deprecated: it is the server-to-server API and has no
  replacement.
- `ConvergerWeb.Deprecation` logs a warning per legacy socket connection and
  per HTTP request, emits `[:converger, :deprecated, :use]`, and adds the
  RFC 9745 `Deprecation` and `Link: <guide>; rel="deprecation"` headers to HTTP
  responses.
- Legacy verifiers check the token's shape: `verify_channel_token/1` (has
  `channel_id`, no `conversation_id`) for `x-channel-token`,
  `verify_conversation_token/1` for the legacy socket, and both reject
  Converger API tokens (`type: "converger"`).

`postActivity` is a pre-v1 event on the pre-v1 (`activitySet`) shape of the
topic. Protocol v1 frames (#22) replace it with `text` and the other message
frames plus `ack` (#24); `postActivity` follows the deprecation of the
`activitySet` shape.

## Consequences

### Positive

- New client work (#22 to #28) targets one socket.
- All WebSocket tests run against the Converger API socket; the legacy tests
  only pin the deprecation warning and what still ships.
- Deprecated-surface usage is visible in logs and telemetry.
- End-user tokens can no longer act as the tenant.

### Negative and trade-offs

- Integrations that sent a conversation token as `x-channel-token` to the
  tenant API break immediately (security fix, not deprecation).
- REST `POST .../activities` still takes `from.id` as the sender even when the
  token names a `user_id`; only the socket enforces the verified id.
- Per-request warnings on the tenant API can be noisy for an integration that
  still uses a channel token; that is intended pressure to migrate.

### Follow-ups

- [#22](https://github.com/AimTune/converger/issues/22): protocol v1 frames on
  the same socket; `postActivity` and `activitySet` become the deprecated
  pre-v1 shape.
- [#24](https://github.com/AimTune/converger/issues/24): `ack` frames for
  `clientId`.
- Remove the legacy stack after the deprecation window (protocol v1,
  section 13.3).

## Implementation

- [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex)
  (`postActivity`).
- [`ConvergerWeb.Deprecation`](https://github.com/AimTune/converger/blob/main/lib/converger_web/deprecation.ex),
  called from `UserSocket.connect/3`, `TenantAuth`, `TokenController.create/2`
  and `ConversationController.create/2`.
- [`Converger.Auth.Token`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/token.ex)
  (`verify_channel_token/1`, `verify_conversation_token/1`).
- Tests: `test/converger_web/channels/converger_channel_test.exs`,
  `conversation_channel_test.exs` (deprecation),
  `test/converger_web/controllers/legacy_deprecation_test.exs`,
  `auth_test.exs` (end-user tokens refused), and the integration tests. The
  chaos harness drives the Converger API socket.

## Links

- [Migrating from the legacy API](../api/migrating-from-legacy.md)
- [WebSocket](../websocket.md), [Real-time](../architecture/realtime.md)
- [Converger Protocol v1](../protocol/v1.md), section 13.3
- [RFC 9745: The Deprecation HTTP Response Header Field](https://www.rfc-editor.org/rfc/rfc9745)
