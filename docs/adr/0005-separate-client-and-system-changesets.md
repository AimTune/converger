---
title: "ADR-0005: Separate client and system changesets for activities"
sidebar_label: "0005 Client vs system changesets"
description: Untrusted input can only set an allowlisted set of activity fields, validated against size limits, while server-controlled fields are set explicitly and inserted_at is never cast.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#5](https://github.com/AimTune/converger/issues/5) |
| **Pull request** | [#73](https://github.com/AimTune/converger/pull/73) |
| **Related** | [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md) |

Activities are created from untrusted input on four paths: the tenant REST API, the Converger client API, inbound provider webhooks and the legacy WebSocket channel. This ADR records how Converger separates the fields a client may set from the fields only the server may set.

## Context and problem statement

`Converger.Activities.Activity.changeset/2` cast `:inserted_at` along with everything else, and both `ConvergerWeb.ActivityController.create/2` and `ConversationChannel.handle_in/3` forwarded the raw request params into `create_activity/1`, only overriding `tenant_id` and `conversation_id`. A client could therefore:

- **backdate or postdate messages** by sending `inserted_at`. Ordering and watermark replay were based on `(inserted_at, id)`, so other clients could receive the message out of order or never receive it on resume;
- set `idempotency_key` in the body, bypassing the header-based idempotency contract;
- **impersonate any sender over WebSocket**, for example `"bot"`, because `sender` came from the payload;
- submit any `type` string, unbounded `metadata` and arbitrary `attachments`, which then fanned out to every channel and subscriber.

This is classic mass assignment: the trust boundary was implicit in each caller instead of explicit in the schema.

## Decision drivers

- The server timestamp and server-assigned identity must not be forgeable.
- The rule must be enforced in one place, not remembered by every controller and channel.
- Size limits protect the database, the PubSub fan-out and downstream providers.
- Validation errors must be field-level and machine-readable (422 on REST).
- Server-internal callers (echo replies, lifecycle events, fixtures) still need to create activities with system fields.

## Considered options

1. **Two changesets plus a client entry point** - `client_changeset/2` casts an allowlist, `system_changeset/2` casts server fields, and `create_client_activity(client_params, system_attrs)` filters untrusted input before merging trusted attributes.
2. **Strip forbidden keys in each controller and channel** - keep one changeset; every caller deletes `inserted_at`, `sender` and so on before calling `create_activity/1`.
3. **Embedded schema per transport** - a separate input schema (REST, WS, inbound) that validates and maps to the activity.
4. **Keep one changeset but stop casting `inserted_at`** - minimal fix for the worst symptom.

### Pros and cons of the options

#### Option 1: Client and system changesets

- Good: the allowlist lives next to the schema (`Activity.client_fields/0`) and every untrusted path goes through one function.
- Good: server fields come only from a separate argument, so a client key cannot override them even if a caller forgets.
- Good: trusted callers keep the full `changeset/2` (client plus system).
- Bad: two entry points (`create_activity/2` and `create_client_activity/2`); a new transport that calls the trusted one with raw input reintroduces the bug.

#### Option 2: Per-caller stripping

- Good: no schema change.
- Bad: a denylist in every caller; the next field added to the schema is assignable by default.

#### Option 3: Per-transport input schemas

- Good: precise per-protocol validation.
- Bad: more code, and the size and type rules would be duplicated or still need a shared core.

#### Option 4: Only drop `inserted_at`

- Good: one-line change.
- Bad: leaves sender spoofing, body idempotency keys and unbounded payloads open.

## Decision

Chosen option: **"Two changesets plus a client entry point"** (option 1), because it makes the trust boundary a property of the schema rather than of each caller, and it uses an allowlist, so new fields are server-only until someone deliberately makes them client-settable.

The rules:

- `Activity.client_changeset/2` casts only `type`, `text`, `attachments` and `metadata`, and validates:
  - `type` against `Activity.types/0`: `message`, `event`, `typing`, `conversationUpdate`, `endOfConversation`;
  - limits from `config :converger, :activity_limits` (defaults below).
- `Activity.system_changeset/2` casts `tenant_id`, `conversation_id`, `sender` and `idempotency_key`, requires `sender`, `tenant_id` and `conversation_id`, and carries the foreign-key and `(conversation_id, idempotency_key)` unique constraints.
- **`inserted_at` is never cast**, by either changeset. The server timestamp always wins. `seq` is not cast either; it is allocated under a lock (see [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)).
- `Activities.create_client_activity(client_params, system_attrs)` takes only `client_fields/0` keys from `client_params`, merges `system_attrs` on top, and calls `create_activity/2`. Each transport decides where the server fields come from:

| Path | `sender` | `idempotency_key` |
| --- | --- | --- |
| `/api/v1` tenant REST (`ActivityController`) | request body, because this is a server-to-server API authenticated by the tenant API key | `x-idempotency-key` header only |
| Converger client API (`ConvergerAPI.ActivityController`) | `from.id` in the body, per the protocol | `x-idempotency-key` header only |
| Inbound webhooks (`InboundController`) | the sender parsed by the channel adapter | the provider message id parsed by the adapter |
| Legacy WebSocket (`ConversationChannel`) | token `sub` claim | not settable |

| Limit | Default | Measured as |
| --- | --- | --- |
| `max_text_bytes` | 65536 | bytes of `text` |
| `max_attachments` | 10 | list length |
| `max_attachment_bytes` | 4096 | JSON size of each attachment map |
| `max_metadata_bytes` | 16384 | JSON size of `metadata` |

Errors: REST returns 422 with field-level errors through the fallback controller. The legacy WebSocket replies `{:error, %{reason: "invalid_activity", errors: %{field => [message]}}}`.

## Consequences

### Positive

- Clients cannot backdate messages, choose their own idempotency key in the body, or impersonate another sender over WebSocket.
- Every activity type is from a known list, and payload sizes are bounded before they reach the pipeline.
- New schema fields are server-only by default.

### Negative and trade-offs

- **Behaviour change** on the legacy WebSocket `ConversationChannel`: `sender` is now the token subject (falling back to `"user"` when the token has none). Clients that relied on sending their own `sender` see a different value.
- The `/api/v1` tenant API and the Converger client API still let the caller name the sender. That is acceptable for the server-to-server tenant API; for the client API it follows the protocol's `from.id` and relies on the conversation-scoped token for authorization.
- The upload controller builds its activity params explicitly and calls the trusted `create_activity/2`; it takes `type`, `text`, `metadata` and `from.id` from the multipart `activity` JSON. It never passes `inserted_at` or `idempotency_key`, but it is a second place to keep correct (see [ADR-0007](0007-attachment-storage-with-hand-written-signing.md)).
- Test fixtures can no longer cast `inserted_at`; `activity_fixture` backdates with a direct row update.

### Follow-ups

- The rich activity model will extend the type list and validate attachments with a schema: [#28](https://github.com/AimTune/converger/issues/28).
- Client-stamped message ids with server acks over WebSocket: [#24](https://github.com/AimTune/converger/issues/24).
- Scoped tokens and stronger client identity: [#52](https://github.com/AimTune/converger/issues/52).

## Implementation

- [`Converger.Activities.Activity`](https://github.com/AimTune/converger/blob/main/lib/converger/activities/activity.ex): `@client_fields`, `@system_fields`, `@default_limits`, `types/0`, `limits/0`, `client_changeset/2`, `system_changeset/2`, `changeset/2`.
- [`Converger.Activities.create_client_activity/2`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex).
- Callers: [`ConvergerWeb.ActivityController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/activity_controller.ex), [`ConvergerWeb.ConvergerAPI.ActivityController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/activity_controller.ex), [`ConvergerWeb.InboundController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex), [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex).

Tests: [`test/converger_web/controllers/activity_mass_assignment_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/activity_mass_assignment_test.exs) checks that a body `inserted_at` is ignored and that each limit (text, attachment count, attachment size, metadata, unknown type, configured limits) returns 422. [`test/converger_web/channels/conversation_channel_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/channels/conversation_channel_test.exs) checks that a WebSocket payload cannot set `sender`, `inserted_at` or `idempotency_key`, and that invalid payloads get field-level error replies.

## Links

- Issue [#5](https://github.com/AimTune/converger/issues/5), pull request [#73](https://github.com/AimTune/converger/pull/73)
- [Security overview](../security.md)
