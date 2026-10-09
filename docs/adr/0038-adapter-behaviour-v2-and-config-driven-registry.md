---
title: "ADR-0038: Adapter behaviour v2 with declared capabilities, config schemas and a config-driven registry"
sidebar_label: "0038 Adapter behaviour v2"
description: Channel adapters declare their type, capabilities and config schema; the registry is the built-ins plus config :converger, :adapters, and nothing outside an adapter lists channel types.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-10 |
| **Issue** | [#36](https://github.com/AimTune/converger/issues/36) |
| **Pull request** | [#130](https://github.com/AimTune/converger/pull/130) |
| **Related** | [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0033](0033-websocket-channel-adapter-delivery.md), [ADR-0036](0036-rich-activity-model.md) |

## Context and problem statement

`Converger.Channels.Adapter` covered delivery, inbound parsing and config validation, and
[ADR-0033](0033-websocket-channel-adapter-delivery.md) added an optional `capabilities/0` so the pipeline
no longer listed deliverable types. Everything else about a channel type was still spread over the code
base as type-string literals:

- `Channel.@channel_types` (accepted types and the admin dropdown) and the `adapter_for/1` `case`;
- `["webhook", "whatsapp_meta", "whatsapp_infobip"]` in `Health.check_all_channels/1` and again in
  `Admin.DashboardLive`;
- `config_fields/1` and `config_summary/1` per type in `Admin.ChannelLive`;
- `@provider_ack_types` in `InboundController`, and a `"whatsapp_meta"` clause for the webhook
  verification handshake;
- the Meta `app_secret` rule in `Channel.validate_signature_config/1`;
- `["webhook", "websocket"]` for conversation lifecycle events in `Pipeline`;
- `whatsapp_message_id` / `infobip_message_id` in `Deliveries.mark_sent/2`.

Adding a channel type meant editing seven files outside the adapter. A fork could not add one without
patching core, and a missed list failed silently: the new type simply got no health checks, no admin form,
or the wrong inbound status code. The roadmap adds Telegram, Slack, email and SMS adapters
([#38](https://github.com/AimTune/converger/issues/38), [#39](https://github.com/AimTune/converger/issues/39)),
so the cost would grow with every one.

## Decision drivers

- Adding an adapter is one module plus one config line; it then appears in the admin UI, health checks
  and the pipeline.
- No channel type literal outside the adapters (acceptance criterion of #36).
- Existing adapters, channel configs and error messages keep working; no migration.
- Channel types stay strings, never atoms from input.
- Misconfiguration fails at boot, not at the first delivery.

## Considered options

1. **Keep the lists, document them** (the checklist that `writing-an-adapter.md` carried before).
2. **Declarations on the adapter, a registry from built-ins plus config** (chosen).
3. **Discover adapters at runtime** by scanning loaded modules for the behaviour.
4. **The full adapter list in config only** (`config :converger, :adapters, [all modules]`).

### Pros and cons of the options

#### Option 1: keep the lists

- Good, because nothing changes.
- Bad, because forks must patch core, and every missed list is a silent bug.

#### Option 2: declarations and a registry from built-ins plus config

- Good, because each consumer asks the adapter (`capability?/2`, `config_schema/1`, `types_with/1`), so a
  new type needs no edit elsewhere.
- Good, because a fork adds `config :converger, :adapters, [MyAdapter]` without restating the built-ins,
  and can replace a built-in by registering a module with the same type.
- Bad, because the capability vocabulary has to be kept meaningful: a capability that nothing reads is
  only documentation.

#### Option 3: runtime discovery

- Good, because no config line at all.
- Bad, because it depends on which modules are loaded (releases load lazily), is slow, and makes the set
  of channel types implicit.

#### Option 4: the full list in config

- Good, because it is explicit and lets an installation remove built-ins.
- Bad, because `config` lists replace rather than merge, so every fork would restate the built-ins and
  silently lose new ones on upgrade.

## Decision

Chosen option: **"Declarations on the adapter, a registry from built-ins plus config"**.

- **`use Converger.Channels.Adapter, type: "<type>"`** sets `@behaviour`, defines the new required
  callback `type/0`, and gives the optional callbacks overridable defaults: `capabilities/0`
  (`[:inbound, :outbound]`), `supported_modes/0` (derived from `:inbound` and `:outbound`),
  `config_schema/0` (`[]`), `validate_config/1` (`:ok`), `retry_policy/0`, `rate_limit/0`,
  `normalize_error/1`.
- **Capabilities** are a list of atoms plus the `activity_types:` entry of
  [ADR-0036](0036-rich-activity-model.md): `:inbound`, `:outbound`, `:external_delivery` (health checks
  and dashboard), `:receipts`, `:typing`, `:lifecycle_events` (close and reopen events),
  `:provider_ack` (handled inbound requests always get `200`), and `:media`, `:templates`, `:reactions`,
  `:edits` for native outbound content. The last four are descriptive until
  [#37](https://github.com/AimTune/converger/issues/37) and [#68](https://github.com/AimTune/converger/issues/68)
  read them.
- **`config_schema/0`** returns field specs (`name`, `type` of `:string | :url | :integer | :boolean | :map`,
  `required` of `true | false | :with_signature`, `secret`, `label`, `placeholder`, `help`, `summary`,
  `form`). `Adapter.validate_config/3` checks it before the adapter's own `validate_config/1`, and the
  admin form and channel list are rendered from it. `required: :with_signature` replaces the Meta-specific
  changeset rule. Unknown keys stay allowed, because some keys apply to every type
  (`conversation_idle_timeout_seconds`, `unsupported_activities`).
- **Registry**: `Adapter.adapters/0` is the built-in modules followed by `config :converger, :adapters`;
  a later module with the same `type/0` replaces an earlier one. The list is cached in `:persistent_term`,
  keyed by the configured list, so dispatch does not rebuild it. `Adapter.validate_registry!/0` runs at
  the start of `Converger.Application.start/2` and raises for a missing module, missing required
  functions or an empty type.
- **New optional callbacks**: `verify_subscription/2` (the `GET` webhook handshake),
  `health_probe/1` and `normalize_error/1`. `verify_inbound_signature/3` and `send_typing/2` already
  existed ([ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md),
  [ADR-0032](0032-transient-conversation-signals.md)).
- **`normalize_error/1`** turns any `{:error, reason}` from `deliver_activity/2` into a `DeliveryError`
  (a map with `reason`, `retryable?`, `retry_after_ms` is accepted) before the circuit breaker and the
  retry policy see it. The default keeps a `DeliveryError` and treats anything else as retryable, as
  [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) did. The pipeline therefore
  handles one error shape.
- **Health probes**: a channel with `:external_delivery` and no deliveries in the window is probed with
  `health_probe/1` when the adapter has one. `:ok` stores `healthy`; an error stores `degraded`, never
  `unhealthy`, because the worker opens the circuit breaker on `unhealthy` and one failed call must not
  hold deliveries. `whatsapp_meta` probes its phone number on the Graph API. Probes can be switched off
  (`config :converger, :channel_health, probe_idle_channels: false`; off in tests).
- `deliver_activity/2` may return `provider_message_id` in its metadata; `Deliveries.mark_sent/2` reads it
  before the older provider-specific keys.

## Consequences

### Positive

- `lib/` contains no list of channel types; `grep whatsapp_meta lib` finds only the adapters.
- A new adapter (in core, a fork or a dependency) is one module plus one config line, verified by
  `test/converger/channels/adapter_test.exs` with a test-only adapter registered from config.
- The admin form and validation cannot drift apart: both come from the schema.
- Idle WhatsApp Meta channels report a real status, so an expired token is visible before a message
  fails.

### Negative and trade-offs

- Echo's capabilities are now `[:outbound, ...]` instead of the implicit default; its supported modes
  (`outbound`) are unchanged.
- The webhook's missing-URL error is now the generic `webhook config missing: url` instead of
  `webhook config requires a 'url' field`.
- `Pipeline.deliver/2` returns `{:error, %DeliveryError{}}` for every retryable failure, instead of the
  adapter's raw reason. Callers only test `Pipeline.retryable?/1`, which is unchanged.
- The registry cache is keyed by the configured list: changing `:adapters` at runtime (tests do) creates
  a new `:persistent_term` entry. That is cheap for the handful of lists an installation or test suite uses.
- Health probes make outbound calls from the health worker every five minutes per idle Meta channel.

### Follow-ups

- [#37](https://github.com/AimTune/converger/issues/37) and [#68](https://github.com/AimTune/converger/issues/68):
  read `:media`, `:templates`, `:reactions` and `:edits` when rendering outbound content.
- An Infobip health probe.
- New adapters ([#38](https://github.com/AimTune/converger/issues/38),
  [#39](https://github.com/AimTune/converger/issues/39)) are written against this behaviour.

## Implementation

- [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex):
  behaviour, `__using__/1`, registry (`adapters/0`, `types/0`, `types_with/1`, `validate_registry!/0`),
  `validate_config/3`, `validate_schema/4` and dispatch.
- [`lib/converger/channels/delivery_error.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/delivery_error.ex):
  `normalize/1`.
- Built-in adapters under `lib/converger/channels/adapters/` declare capabilities and schemas;
  `whatsapp_meta.ex` adds `verify_subscription/2` and `health_probe/1`.
- Consumers: `Channel` (types, schema validation), `Health.list_monitored_channels/0` (also used by the
  dashboard), `Pipeline` (`:lifecycle_events`, `normalize_error`), `InboundController` (`:provider_ack`,
  `verify_subscription/2`), `Admin.ChannelLive` (generated form, summary, masking), `Converger.Application`
  (boot check).
- Config: `config :converger, :adapters` and `config :converger, :channel_health` in `config/config.exs`.
- Tests: `test/converger/channels/adapter_test.exs` (registry, schema, probes, pipeline, errors),
  `test/converger_web/live/admin_channel_schema_test.exs` (generated form), and the test-only
  `test/support/test_sms_adapter.ex`.

## Links

- [Writing an adapter](../channels/writing-an-adapter.md)
- [Channels and adapters](../channels/overview.md)
- [Configuration](../operations/configuration.md)
