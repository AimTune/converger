---
title: Channels
description: Channels are a tenant's endpoints - adapter type, direction mode, encrypted secret and config, middleware transformations, signature enforcement, retry policy and health.
sidebar_position: 3
---

A channel is a tenant's endpoint to the outside world: a webhook URL, a WhatsApp number, a set of WebSocket clients. Its **type** selects the adapter that talks to the provider. Its **mode** says whether messages may come in, go out, or both. A conversation always belongs to exactly one channel. Other channels can receive its activities through [routing rules](routing-rules.md).

Source: [`lib/converger/channels/channel.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/channel.ex), [`lib/converger/channels.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels.ex), [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex).

## Schema

Table `channels`:

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `id` | uuid | | Primary key. |
| `tenant_id` | uuid | | Owner. `(tenant_id, name)` is unique. |
| `name` | text | | Required. |
| `type` | string | `"webhook"` | Adapter: `echo`, `webhook`, `websocket`, `whatsapp_meta`, `whatsapp_infobip`. |
| `mode` | text | `"duplex"` | `inbound`, `outbound` or `duplex`. Must be supported by the type. |
| `secret` | encrypted binary | generated | Encrypted at rest. Generated (32 random bytes, Base64) when not given. |
| `secret_hash` | binary | | SHA-256 of `secret`, unique, used for lookups. |
| `config` | encrypted map | `{}` | Adapter configuration, including provider credentials. Encrypted at rest. |
| `transformations` | jsonb array | `[]` | [Middleware](middleware.md) chain applied before delivery to this channel. |
| `require_signature` | boolean | `true` | Reject unsigned inbound webhooks. |
| `retry_policy` | map | `{}` | Per-channel delivery retry overrides. |
| `status` | text | `"active"` | The admin panel and portal toggle between `active` and `inactive`. |
| `inserted_at`, `updated_at` | utc_datetime_usec | | |

All fields go through `Channel.changeset/2`, which validates the type, the mode (and that the type supports it), the type's config, the signature config, the middleware chain and the retry policy.

## Types and adapters

Each type maps to a module implementing the `Converger.Channels.Adapter` behaviour: `deliver_activity/2`, `parse_inbound/2`, `validate_config/1`, `supported_modes/0`, and optionally `parse_status_update/2`, `verify_inbound_signature/3`, `retry_policy/0` and `capabilities/0` (default `[:inbound, :outbound]`; the pipeline delivers only to types with `:outbound`).

| Type | Modes | Required config | Delivery | Page |
| --- | --- | --- | --- | --- |
| `webhook` | `inbound`, `outbound`, `duplex` | `url`. Optional: `method` (`POST`, `PUT`, `PATCH`), `headers`, `connect_timeout`, `receive_timeout`, `max_response_bytes` | HTTP request with the canonical activity, signed with `x-converger-signature` | [Webhooks](../webhooks.md) |
| `websocket` | `inbound`, `outbound`, `duplex` | none. Optional: `require_ack` (`true`/`false`, default `false`) | Broadcast to the channel's connected sockets; the delivery stays `pending` while no client is connected (or until a client acks, with `require_ack`). Clients send messages over the socket ([ADR-0028](../adr/0028-websocket-channel-adapter-delivery.md)). | [WebSocket channel](../channels/websocket.md) |
| `whatsapp_meta` | `inbound`, `outbound`, `duplex` | `phone_number_id`, `access_token`, `verify_token`, plus `app_secret` when `require_signature` is true | WhatsApp Cloud API (Graph) | [WhatsApp](../channels/whatsapp.md) |
| `whatsapp_infobip` | `inbound`, `outbound`, `duplex` | `base_url`, `api_key`, `sender` | Infobip WhatsApp API | [WhatsApp](../channels/whatsapp.md) |
| `echo` | `outbound` | none | Writes a reply activity from `"bot"` into the same conversation (testing) | [Echo](../channels/echo.md) |

See the [channels overview](../channels/overview.md) for provider setup, and [writing an adapter](../channels/writing-an-adapter.md) to add a type. The rest of adapter behaviour v2 (config schemas, beyond the `capabilities/0` callback) is Planned ([#36](https://github.com/AimTune/converger/issues/36)).

One config key is read for every inbound-capable type: `conversation_idle_timeout_seconds` (positive integer). It starts a new conversation for a participant whose active conversation has been idle longer than this ([participants](participants.md)).

## Modes

The mode is the channel's direction. It was introduced by migration [`20260227160000_add_mode_to_channels`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20260227160000_add_mode_to_channels.exs), which defaulted existing channels to `duplex` and set `echo` and `websocket` channels to `outbound`. Migration [`20261010040000_make_websocket_channels_duplex`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261010040000_make_websocket_channels_duplex.exs) later moved existing `websocket` channels from `outbound` to `duplex`, when the type gained inbound support ([#22](https://github.com/AimTune/converger/issues/22)).

| Mode | Accepts inbound webhooks | Receives deliveries | Can be a routing rule source | Can be a routing rule target |
| --- | --- | --- | --- | --- |
| `inbound` | yes | no | yes | no |
| `outbound` | no | yes | no | yes |
| `duplex` | yes | yes | yes | yes |

Concretely:

- `POST /api/v1/channels/:id/inbound` with messages on an `outbound` channel returns `400 {"error": "Channel does not accept inbound messages"}`. If the same request also carried status updates, they are applied, and the messages are dropped with a warning. A `new_activity` sent over the client API socket of an `outbound` channel is answered with the error `inbound_not_supported`.
- The pipeline delivers only to channels whose mode is `outbound` or `duplex`, both for the conversation's own channel and for routing targets.
- `RoutingRules` rejects an `outbound` source ("source channel is outbound-only and cannot receive inbound messages") and `inbound` targets.
- `Channel.changeset/2` rejects a mode the adapter does not support, for example `echo channels only support modes: outbound`.

## Secret

Every channel has a secret, shown **once** when the channel is created in the admin panel and stored encrypted with `Converger.Vault` (AES-GCM, key `CLOAK_KEY`). Lookups go through `secret_hash`, and the decrypted value is then compared in constant time. The secret is used to:

- authenticate `POST /api/v1/converger/tokens/generate` (`authorization: Bearer <channel secret>`), which issues client tokens for the channel ([client API](../api/client-api.md));
- verify the generic inbound signature `x-converger-signature: t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>` ([ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md));
- sign outbound webhook requests with the same header format ([ADR-0014](../adr/0014-webhook-ssrf-guard-and-outbound-signing.md)).

## Config and encryption at rest

`config` is a map with string keys, validated by the adapter's `validate_config/1`. Both `secret` and `config` are `Cloak.Ecto` encrypted fields. Migration [`20261008100000_encrypt_channel_secrets`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008100000_encrypt_channel_secrets.exs) encrypted existing rows in place and dropped the plaintext columns (issue [#12](https://github.com/AimTune/converger/issues/12)). In the admin UI and the audit logs, sensitive keys (`access_token`, `api_key`, `secret`, `token`, `password`, `verify_token`, `app_secret`, `authorization`, and keys ending in `_secret`, `_token` or `_hash`) are masked or redacted.

After rotating `CLOAK_KEY`, move the old key to `CLOAK_RETIRED_KEYS` and run `bin/converger eval "Converger.Release.reencrypt_secrets()"`. See [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md) and [security](../security.md).

## Transformations

`transformations` is an ordered list of middleware steps, each a map with a `"type"` and its options:

```json
[
  { "type": "add_prefix", "prefix": "[Support] " },
  { "type": "truncate_text", "max_length": 160, "ellipsis": "..." }
]
```

The chain is validated on save (unknown types and bad options are rejected). It runs for every delivery **to this channel**, just before the adapter. The admin channel form has a "Middleware Pipeline" editor. See [middleware](middleware.md).

## Signature enforcement

`require_signature` controls unsigned inbound requests on `/inbound` and `/status`:

| Request | `require_signature: true` | `require_signature: false` |
| --- | --- | --- |
| Valid current signature (`t=...,v1=...`, or the provider's native scheme) | accepted | accepted |
| Valid legacy signature (`sha256=<hex>`, no timestamp) | `401` | accepted, deprecation warning logged |
| No signature | `401` | accepted, deprecation warning logged |
| Invalid signature | `401` | `401` |

New channels default to `true`. Migration [`20261008120000_add_require_signature_to_channels`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008120000_add_require_signature_to_channels.exs) backfilled existing channels with `false`, so old integrations kept working. `whatsapp_meta` verifies Meta's `X-Hub-Signature-256` with `config["app_secret"]`, and cannot require signatures without it. Timestamped signatures must be within `config :converger, :inbound_signature_tolerance_seconds` (default 300) of the server clock. Toggle the flag in the channel table ("Signature: required/optional"). Details: [webhooks](../webhooks.md).

## Retry policy

`retry_policy` overrides delivery retries for this channel. The effective policy is resolved by `Converger.Pipeline.RetryPolicy.for_channel/1`, which merges, in order: the global defaults (`config :converger, :retry_policy`), the adapter's `retry_policy/0` defaults, and the channel's own map.

| Key | Default | Meaning |
| --- | --- | --- |
| `max_attempts` | `5` | Attempts before the delivery is dead-lettered (`failed`). |
| `backoff` | `exponential` | `exponential` (`base_ms * 3^attempt`), `linear` (`base_ms * attempt`) or `fixed` (`base_ms`). |
| `base_ms` | `10000` | Backoff base in ms. |
| `max_ms` | `3600000` (1 h) | Backoff cap in ms. |
| `timeout_ms` | `15000` (`webhook`: `10000`) | Adapter request timeout. |

```json
{ "max_attempts": 8, "backoff": "linear", "base_ms": 5000, "max_ms": 600000 }
```

Values must be positive integers (or a valid `backoff` name), and unknown keys are rejected. With the defaults, retries come about 30 s, 90 s, 270 s and 810 s after attempts 1 to 4. A provider `Retry-After` overrides the backoff for the next attempt. See [deliveries](deliveries.md) and [ADR-0019](../adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md).

## Status

A channel is `active` or `inactive`. When a channel stops being active:

- its connected client sockets are disconnected (`ConvergerWeb.Sockets.disconnect_channel/1`), and cannot reconnect or rejoin while it stays inactive;
- inbound webhooks get `400 {"error": "Channel is inactive"}`;
- client-API requests with its tokens get `403 {"error": {"code": "Forbidden", "message": "Channel not found or inactive"}}`, and `tokens/generate` with its secret fails;
- new conversations cannot be created on it through `POST /api/v1/conversations`;
- it is skipped as a routing rule target.

Deleting a channel also disconnects its sockets, and cascades to its conversations, participants, deliveries and health checks.

## Health checks

`Converger.Workers.ChannelHealthWorker` runs every 5 minutes (Oban cron). For each **active** channel of type `webhook`, `whatsapp_meta` or `whatsapp_infobip`, it computes the delivery failure rate over the last 60 minutes and stores a row in `channel_health_checks`:

| Status | Failure rate (failed / total deliveries in window) |
| --- | --- |
| `healthy` | below 10% |
| `degraded` | 10% to below 50% |
| `unhealthy` | 50% or more |
| `unknown` | no deliveries in the window |

When the status differs from the previous check, the worker logs the change, broadcasts `health_changed` on the `channel_health` PubSub topic (the admin channel list shows a health dot), and POSTs to the tenant's [alert webhook](tenants.md#alert-webhook). Checks older than 7 days are pruned on every run. Per-channel circuit breakers are Planned ([#31](https://github.com/AimTune/converger/issues/31)).
