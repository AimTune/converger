---
title: "ADR-0003: The pipeline is the only delivery path"
sidebar_label: "0003 Pipeline-only delivery"
description: Every outbound delivery, including WebSocket-originated messages and echo replies, goes through Converger.Pipeline; no code path calls an adapter directly.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#3](https://github.com/AimTune/converger/issues/3) |
| **Pull request** | [#71](https://github.com/AimTune/converger/pull/71) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0005](0005-separate-client-and-system-changesets.md), [ADR-0008](0008-middleware-receives-channel-and-crashes-are-contained.md) |

Activities enter Converger over several transports: the tenant REST API, the Converger client API, inbound provider webhooks and WebSockets. This ADR records that all of them hand the activity to one place, `Converger.Pipeline`, and that nothing else is allowed to call a channel adapter's `deliver_activity/2`.

## Context and problem statement

`ConvergerWeb.ConversationChannel.handle_in("new_activity", ...)` did two things:

1. called `Activities.create_activity/1`, which already ran the pipeline and enqueued deliveries, and
2. called a private `handle_activity/2`, which used `Task.start` to call `Adapter.deliver_activity/2` **directly** with a hand-built `%Activity{}` that had no `id` and no `inserted_at`.

The concrete failure modes:

- For `webhook`, `whatsapp_meta` and `whatsapp_infobip` primary channels, the external system received **every WebSocket message twice**: once from the pipeline, once from the task.
- The direct call skipped `Pipeline.Middleware.run/2` (channel transformations), `Deliveries` tracking, retry and backoff, and routing-rule fan-out.
- `Task.start` was unsupervised, so failures vanished without a log of a failed delivery.
- The `echo` adapter was not in the pipeline's hardcoded list of external delivery types, so it was reached only through this side path. Echo replies worked over WebSocket but not over REST.

## Decision drivers

- Exactly one delivery per target channel per activity.
- Every delivery gets the same treatment: middleware, tracking, retry policy, dead-lettering, routing rules.
- REST and WebSocket must behave identically for the same channel configuration.
- No unsupervised processes doing I/O on the request path.

## Considered options

1. **Remove the side path; the pipeline is the only delivery path** - `handle_in` only creates the activity; echo becomes an ordinary pipeline delivery type.
2. **Keep the WebSocket side path but skip the pipeline for the primary channel** - avoids the duplicate by excluding the primary channel from pipeline fan-out for WS-originated activities.
3. **Keep the side path and make it call `Pipeline.deliver/2`** - so at least middleware and tracking run, under a `Task.Supervisor`.

### Pros and cons of the options

#### Option 1: Pipeline only

- Good: one code path to reason about, test and harden; duplicates are impossible by construction.
- Good: WebSocket-originated activities gain durability ([ADR-0001](0001-transactional-outbox-with-oban.md)), retries ([ADR-0002](0002-broadway-for-throughput-oban-for-retries.md)) and transformations for free.
- Bad: echo must go through the pipeline, which creates a loop risk (an echo reply is itself an activity that the pipeline would echo again). This needs explicit loop protection.

#### Option 2: Transport-specific exclusion

- Good: small diff.
- Bad: the side path still bypasses tracking, retries and middleware; delivery semantics would depend on which transport created the activity.

#### Option 3: Side path through `Pipeline.deliver/2`

- Good: middleware and tracking run.
- Bad: still not durable (runs after commit in a task), still duplicates unless the primary channel is excluded from the job fan-out, and still two paths.

## Decision

Chosen option: **"The pipeline is the only delivery path"** (option 1). The pipeline is where every delivery guarantee lives (transactional enqueue, uniqueness, retry policy, dead letters, middleware, routing rules), so any second path silently opts out of all of them. Removing the side path is simpler than making a second path equivalent.

Specifically:

- `ConversationChannel.handle_in("new_activity", ...)` only calls `Activities.create_client_activity/2` and replies. `handle_activity/2` is gone.
- `echo` is a regular delivery type. `Converger.Pipeline` keeps a module attribute `@delivery_types ~w(echo webhook whatsapp_meta whatsapp_infobip)`; `websocket` is deliberately excluded because its clients are reached by the PubSub broadcast in `after_commit/1`.
- Echo loop protection lives in the adapter:
  - an echo reply carries `metadata["echo_of"]` with the original activity id, and `deliver_activity/2` returns `:ok` without replying for any activity that has this tag;
  - the reply uses the idempotency key `echo:` followed by the original id, so a retried delivery cannot create a second reply;
  - a failed reply returns `{:error, {:echo_failed, reason}}` instead of a silent `:ok`, so the pipeline's retry policy applies.

Replacing the hardcoded type list with adapter capabilities was deliberately left out of scope.

## Consequences

### Positive

- One WebSocket `new_activity` produces exactly one delivery per target channel.
- Channel transformations, delivery tracking, retries and routing rules apply to WebSocket messages.
- Echo works the same over REST and WebSocket and is a convenient end-to-end test of the whole pipeline.

### Negative and trade-offs

- The list of deliverable channel types is still a literal in `Converger.Pipeline`; a new adapter must be added there to receive deliveries.
- Echo replies are created from inside a delivery job, so they depend on the conversation still being open. If it was closed in the meantime, the adapter returns `:ok` and no reply is created.
- Test fixtures had to change: `channel_fixture` defaults to `websocket` instead of `echo`, so ordinary tests do not generate bot replies.
- Legacy behaviour change: on the legacy socket the sender of a WebSocket activity is the token subject (from [ADR-0005](0005-separate-client-and-system-changesets.md)), not a client-supplied value.

### Follow-ups

- Adapter behaviour v2 with `capabilities/0` to remove hardcoded type lists: [#36](https://github.com/AimTune/converger/issues/36).
- A first-class duplex `websocket` adapter (deliver to sockets, offline buffering, fan-out target): [#22](https://github.com/AimTune/converger/issues/22).
- Unifying the legacy `UserSocket`/`ConversationChannel` with `ConvergerSocket`/`ConvergerChannel`: [#23](https://github.com/AimTune/converger/issues/23).

## Implementation

- [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex): `handle_in("new_activity", ...)` builds `system_attrs` from the token claims and calls `Activities.create_client_activity/2`; replies `{:error, %{reason: "invalid_activity", errors: ...}}` or `{:error, %{reason: "conversation_closed"}}` on failure.
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): `@delivery_types` and `resolve_delivery_channels/1` (primary channel if deliverable and `outbound`/`duplex`, plus active routing-rule targets, minus the participant's own channel for its inbound messages).
- [`Converger.Channels.Adapters.Echo`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/echo.ex): `echo_of` tag, `echo:` idempotency key, error propagation.

Tests: the WebSocket test stubs the webhook with `Req.Test` and asserts exactly one outbound request and one tracked delivery with `status: "sent"` and `attempts == 1`; an `add_prefix` transformation shows up in the webhook body for a WS-originated message; echo is checked over WebSocket (one reply, no loop) and REST (controller test). See [`test/converger_web/channels/conversation_channel_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/channels/conversation_channel_test.exs) and [`test/converger_web/controllers/activity_controller_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/activity_controller_test.exs).

## Links

- Issue [#3](https://github.com/AimTune/converger/issues/3), pull request [#71](https://github.com/AimTune/converger/pull/71)
