---
title: "ADR-0046: Conditional routing rules, reply-back routing by source channel, and a dry-run on the real planner"
sidebar_label: "0046 Conditional routing"
description: Routing rules get JSON conditions validated on save, a priority with first-match stop, and their own middleware chain; activities record the channel they came in on, so a reply from a target channel goes back to the conversation's origin only; conversations record their origin and span channels through a join table; a dry-run runs the real planning code.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#43](https://github.com/AimTune/converger/issues/43) |
| **Pull request** | (pending) |
| **Related** | [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0008](0008-middleware-receives-channel-and-crashes-are-contained.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0033](0033-websocket-channel-adapter-delivery.md), [ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md) |

## Context and problem statement

Routing rules were static: "every activity of a conversation on channel A also goes to channels B, C"
(`RoutingRules.resolve_target_channels/2`). Issue [#43](https://github.com/AimTune/converger/issues/43) asks for what
real hubs need: route only some activities (a type, a sender, `metadata.department == "sales"`), apply different
transformations per route, pick an order when several rules match, try a rule before enabling it, and above all route
replies back to where the conversation came from. Its acceptance criteria:

1. WhatsApp to an agent on a `websocket` console: the agent's reply reaches only the originating WhatsApp number.
2. A rule with `metadata.vip == true` routes to a priority webhook only for matching activities.
3. A dry-run shows the matched rules and the transformed payloads.

The first one did not hold. A conversation belonged to one channel, and every activity of it was delivered to that
channel and to all targets of that channel's rules. An agent reply posted on the console therefore also went to every
other target of the WhatsApp channel (a CRM webhook, a second console). Nothing recorded which channel an activity came
in on, so the pipeline could not tell an inbound message from a reply.

## Decision drivers

- Existing rules, conversations and activities keep working unchanged, through a rolling deploy.
- No user-supplied input may block a delivery worker: a condition is data, not code, and a regex is bounded.
- The dry-run must show what the pipeline really does, not a second implementation that can drift.
- Delivery-time behaviour must be reproducible across retries and replays (dead-letter replay re-runs `Pipeline.deliver/2`
  with only the activity and the channel, [ADR-0028](0028-dead-letter-replay-in-place-through-oban.md)).
- Cycle detection stays a cheap, conservative safety net.

## Considered options

For the conditions:

1. **A JSON predicate tree validated on save** (`field`, `op`, `value`; `all` / `any` / `not`).
2. **An expression language** (a small DSL or JSONLogic).
3. **Arbitrary Elixir/Lua code per rule.**

For reply-back:

1. **Record the source channel on each activity; a reply goes to the origin and only the replying channel's rules apply.**
2. **Mark agent replies explicitly** (a flag or a `metadata` key the client sets).
3. **Express reply-back as rules** (a rule from the console back to WhatsApp).

For per-rule transformations:

1. **Re-route at delivery time** and run the matched rules' chains after the channel's chain.
2. **Store the matched rule ids in the job arguments.**

### Pros and cons of the options

#### Conditions as a JSON predicate tree

- Good, because it is stored as JSONB, rendered as-is by the API, and validated field by field with precise errors.
- Good, because evaluation is a small pure function with no compilation step and no code execution.
- Bad, because it is more verbose than an expression string.

#### An expression language

- Good, because it is compact.
- Bad, because it needs a parser, error positions and its own escaping rules, and JSONLogic would add a dependency for
  little gain over a fixed operator set.

#### Code per rule

- Bad, because tenants could run arbitrary code in the delivery path.

#### Source channel on each activity

- Good, because every write path already knows its channel (inbound webhook, WebSocket, client API token, echo).
- Good, because "unless a rule says otherwise" falls out naturally: the replying channel's own rules still apply.
- Good, because activities without a channel (tenant API, system events, every stored row) keep the old routing.
- Bad, because a new nullable column on the partitioned `activities` table.

#### Explicit reply marking

- Bad, because every client must opt in, and a forgotten flag silently fans the reply out.

#### Reply-back as rules

- Bad, because a console-to-WhatsApp rule plus the WhatsApp-to-console rule is a cycle, and a rule cannot name "the
  participant of this conversation".

#### Re-route at delivery time

- Good, because every delivery path (Oban, Broadway, Inline, retries, dead-letter replay, routed socket replay) calls
  `Pipeline.deliver/2` or the routed socket frame code with only the activity and the channel.
- Good, because rule edits apply to pending deliveries, like channel middleware edits.
- Bad, because a delivery re-reads the rules; a cheap existence check skips this when no rule targeting the channel has
  transformations.

#### Rule ids in the job arguments

- Bad, because Broadway messages, replays and the routed socket replay have no job arguments, and the unique key of
  delivery jobs is `{activity_id, channel_id}`.

## Decision

**Conditions** (`Converger.RoutingRules.Conditions`) are a JSON predicate tree over `type`, `sender`, `text`,
`metadata.*`, `conversation.metadata.*`, `conversation.status`, `participant.*` and `time.*`, with the operators `eq`,
`neq`, `in`, `contains`, `regex`, `exists`, `gt`, `lt` and the groups `all`, `any`, `not`. A list is shorthand for `all`.
They are validated in the rule changeset: known fields and operators only, at most 32 predicates, depth 4, 100 `in`
values; a regex must compile and is at most 256 bytes, and it runs with a PCRE `match_limit`, so catastrophic
backtracking ends as "no match". Time conditions read the activity's `inserted_at` (with an optional fixed
`utc_offset_minutes`), so a retry is routed like the first attempt.

**Priority and first match.** Rules of a source channel are evaluated in ascending `priority` (default 100), then name
and id. Every matching rule adds its targets; a matching rule with `stop_processing` ends the evaluation.

**Reply-back by source channel.** Activities record `source_channel_id`; conversations record `origin_channel_id` (set
on insert, backfilled from `channel_id`, read through `Conversation.origin_channel_id/1`, which falls back to
`channel_id`). `RoutingRules.route/3` decides the direction: an activity from the origin or from no channel is
**inbound** and evaluates the origin's rules, as before; an activity from another channel is a **reply**: it goes to
the origin channel (whose adapter already addresses the conversation's participant), to the replying channel itself
when it is a `websocket` hub (other agents' sockets see the reply, as before), and to the targets of the **replying
channel's** matching rules only. The origin channel's other targets do not get it.

**Conversations span channels.** A `conversation_channels` join table records the origin (with the participant), every
channel the pipeline delivers to (`target`) and every other channel that wrote into the conversation (`member`). It is
written with `ON CONFLICT DO NOTHING` when a conversation is created and when the backends plan deliveries, and shown
by `GET /api/v1/conversations/:id`. `conversations.channel_id` is unchanged, so every existing query keeps working.

**Per-rule transformations** use the channel middleware format and are validated the same way. `Pipeline.transform/3`
runs the channel's chain, then the chains of the matched rules that target the channel, in rule order; it is used by
`Pipeline.deliver/2` and by the routed `websocket` socket frames. The rules are re-evaluated at delivery time.

**One planner.** `Pipeline.plan/2` returns every candidate channel with its reason (`origin`, `reply_back`,
`source_hub`, `rule`) and, when it is left out, why (`echo`, `inactive`, `inbound_only`, `not_deliverable`,
`unsupported_activity`). `resolve_delivery_channels/2` is its non-excluded entries; the backends use
`delivery_channels/1`, which also records the channels. The **dry-run** (`Converger.RoutingRules.DryRun`,
`POST /api/v1/routing_rules/dry_run`, admin `/admin/routing_rules/dry_run`) builds an activity that is never inserted
and runs `plan/2` and `Pipeline.preview/3` (type downgrade plus `transform/3`) on it.

**Cycle detection** is unchanged and ignores conditions: a conditional edge is an edge.

## Consequences

### Positive

- An agent reply reaches only the conversation's participant on the origin channel (tested end to end: two WhatsApp
  conversations, a CRM webhook target, one WhatsApp request for the reply, no CRM delivery).
- Rules can filter, order and transform per route, and can be tried with a dry-run that cannot drift from delivery.
- Existing rules match everything with no transformations, and activities without a source channel route as before.

### Negative and trade-offs

- **Behaviour change** for activities written from a non-origin channel (a routed `websocket` console, a Slack thread
  or an email reply that joined another channel's conversation): they no longer fan out to the origin's other targets.
  Deployments that relied on that (for example a CRM webhook receiving agent replies) need a rule from the replying
  channel. The tenant API has no channel, so its replies still fan out.
- Every planned activity writes `conversation_channels` rows (`INSERT ... ON CONFLICT DO NOTHING`, usually a no-op).
- A delivery to a channel targeted by a rule with transformations re-reads the conversation and the rules.
- Rule edits apply to deliveries that have not run yet, including conditions: an activity enqueued for a target whose
  rule no longer matches still gets that delivery, but not the rule's transformations.
- A routed `websocket` socket may follow a conversation whenever an enabled rule targets its channel, whatever the
  conditions, and its replay contains the whole conversation: conditions decide deliveries, not access.
- Time windows support fixed UTC offsets only; there is no time zone database.

### Follow-ups

- Time zone names for time windows, if a time zone database is added.
- [#51](https://github.com/AimTune/converger/issues/51) management API: rule editing outside the admin panel beyond the
  tenant API.

## Implementation

- [`Converger.RoutingRules.Conditions`](https://github.com/AimTune/converger/blob/main/lib/converger/routing_rules/conditions.ex),
  [`RoutingRule`](https://github.com/AimTune/converger/blob/main/lib/converger/routing_rules/routing_rule.ex)
  (changeset), [`RoutingRules.route/3`](https://github.com/AimTune/converger/blob/main/lib/converger/routing_rules.ex),
  [`Converger.RoutingRules.DryRun`](https://github.com/AimTune/converger/blob/main/lib/converger/routing_rules/dry_run.ex).
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): `plan/2`,
  `resolve_delivery_channels/2`, `delivery_channels/1`, `transform/3`, `preview/3`; the Oban, Broadway and Inline
  backends call `delivery_channels/1`.
- `source_channel_id` is set by `Converger.Inbound`, `ConvergerWeb.ConvergerChannel`, `ConvergerWeb.ProtocolSocket`, the
  client API activity and upload controllers, and the echo adapter.
- [`Conversation`](https://github.com/AimTune/converger/blob/main/lib/converger/conversations/conversation.ex)
  (`origin_channel_id`), [`ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger/conversations/conversation_channel.ex),
  `Conversations.insert_conversation/1`, `record_channels/2`.
- Admin `ConvergerWeb.Admin.RoutingRuleLive` (create and edit with conditions, transformations, priority, stop) and
  `ConvergerWeb.Admin.RoutingRuleDryRunLive`; the portal lists priority and conditions.
- Migrations `20261012200000_add_conditions_to_routing_rules`, `20261012200100_add_source_channel_id_to_activities`,
  `20261012200200_create_conversation_channels` (batched backfill).
- Tests: `test/converger/routing_rules/conditions_test.exs`, `test/converger/routing_rules_test.exs`,
  `test/converger/pipeline/conditional_routing_test.exs`,
  `test/converger_web/controllers/routing_rule_controller_test.exs`,
  `test/converger_web/live/routing_rule_live_test.exs`, and the reply-back case in
  `test/converger_web/integration/websocket_channel_adapter_test.exs`.

## Links

- [Routing rules](../concepts/routing-rules.md), [Conversations](../concepts/conversations.md#channels-of-a-conversation),
  [Middleware](../concepts/middleware.md), [Tenant API: dry-run](../api/tenant-api.md#dry-run-routing),
  [Data model](../architecture/data-model.md), [Delivery pipeline](../architecture/delivery-pipeline.md),
  [Migrations](../operations/migrations.md)
