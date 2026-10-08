---
title: "ADR-0009: Timestamped inbound signature scheme with per-channel enforcement"
sidebar_label: "0009 Inbound signatures"
description: Inbound and status webhooks are verified with a timestamped HMAC header (or a provider-native scheme), enforced per channel through require_signature.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#9](https://github.com/AimTune/converger/issues/9) |
| **Pull request** | [#77](https://github.com/AimTune/converger/pull/77) |
| **Related** | [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md) |

External systems push messages into Converger through `POST /api/v1/channels/:channel_id/inbound` and delivery receipts through `POST /api/v1/channels/:channel_id/status`. This ADR records how those requests are authenticated: which signature format is used, how replay is limited, how provider-native schemes fit in, and how existing integrations were migrated without breaking them.

## Context and problem statement

Before [#77](https://github.com/AimTune/converger/pull/77), `ConvergerWeb.InboundController.verify_inbound_signature/2` treated the signature as optional:

- If the `x-converger-signature` header was **absent**, the request was accepted. Anyone who knew a channel id could inject inbound messages and forge status updates for any active channel. Channel ids are UUIDs, but they appear in URLs, provider dashboards and logs, so they are not secrets.
- `ConvergerWeb.CacheBodyReader.should_cache?/1` only cached the raw body when the path contained `/inbound`. For `POST /channels/:id/status` the raw body was `nil`, so verification short-circuited to `:ok` even when a signature was sent. A tampered receipt was accepted.
- The old generic format (`sha256=<hex HMAC of the body>`) had no timestamp, so a captured request could be replayed forever.
- Provider-native signatures were ignored. WhatsApp Cloud API (Meta) signs every webhook with `X-Hub-Signature-256` (HMAC-SHA256 of the body, keyed with the app secret). That is the only signature Meta can send, so a WhatsApp Meta channel could not be protected at all.

Simply making the signature mandatory everywhere would have broken every existing integration that never signed its requests.

## Decision drivers

- Unsigned or tampered requests must be rejected with 401 on both `/inbound` and `/status`.
- Captured requests must not be replayable indefinitely.
- Providers sign with their own scheme; Converger cannot ask Meta to send a Converger header.
- Existing channels must keep working after the upgrade, with a visible migration path.
- Secret rotation must be possible without a window where valid requests fail.
- Verification must run over the exact bytes received, not over re-encoded JSON.

## Considered options

1. **Timestamped HMAC header plus per-channel `require_signature` flag and optional adapter callback** - `x-converger-signature: t=<unix>,v1=<hex>`, a tolerance window, a boolean per channel that new channels get as `true`, and an adapter hook for provider-native schemes.
2. **Keep the untimestamped `sha256=<hex>` header and make it mandatory globally** - smallest code change, flip a switch.
3. **Bearer token or shared secret in a header (or query string)** - the sender passes the channel secret (or a token) verbatim.
4. **Mutual TLS or IP allowlisting of providers** - authenticate the transport instead of the payload.

### Pros and cons of the options

**Option 1: timestamped HMAC, per-channel flag, adapter callback**

- Good: the timestamp bounds replay to the tolerance window (default 300 s).
- Good: the body is authenticated, so tampering is detected, including on `/status`.
- Good: the same scheme as Stripe-style webhooks, which integrators already know how to implement.
- Good: several `v1=` values in one header allow secret rotation.
- Good: adapters can plug in Meta's `X-Hub-Signature-256` (and later Slack signing secrets) without changing the controller.
- Good: the flag lets existing channels migrate at their own pace.
- Bad: requires synchronized clocks on the sender side.
- Bad: two code paths (strict and permissive) remain until legacy channels are migrated.

**Option 2: mandatory `sha256=<hex>`**

- Good: trivial to implement; existing signers keep working.
- Bad: no replay protection.
- Bad: breaks every unsigned integration on upgrade, with no migration window.
- Bad: still does nothing for WhatsApp Meta, which cannot send it.

**Option 3: bearer secret in a header**

- Good: simplest possible client implementation.
- Bad: the secret travels with every request and ends up in proxy logs and provider dashboards.
- Bad: does not authenticate the body, so a man in the middle or a misbehaving proxy can alter it.
- Bad: providers (Meta, Infobip) do not support it.

**Option 4: mTLS or provider IP allowlists**

- Good: no application-level crypto.
- Bad: provider IP ranges change and are shared across all customers of that provider, so an allowlist does not prove the request belongs to this channel.
- Bad: mTLS is not offered by the providers in scope and is heavy for small integrators.
- Bad: depends on correct client-IP resolution behind proxies (see [ADR-0011](0011-custom-trusted-proxies-plug.md)).

## Decision

Chosen option: **"Timestamped HMAC header plus per-channel `require_signature` flag and optional adapter callback"**, because it is the only option that authenticates the body, limits replay, works with provider-native schemes and can be rolled out without breaking existing channels.

The rules are:

- **Generic scheme** (`Converger.Channels.InboundSignature`): `x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256("<t>.<raw body>", channel.secret)>`. The timestamp must be within `config :converger, :inbound_signature_tolerance_seconds` (default 300) of the server clock. Several `v1=` entries are accepted; any match passes. Comparisons use `Plug.Crypto.secure_compare/2`.
- **Legacy scheme**: `sha256=<hex HMAC of the raw body>` is still recognized, but only as `:legacy`, never as `:ok`.
- **Provider-native schemes**: an adapter may implement the optional `verify_inbound_signature(channel, headers, raw_body)` callback returning `:ok | :legacy | :missing | {:error, reason}`. WhatsApp Meta verifies `X-Hub-Signature-256` with the channel config key `app_secret`. Adapters without the callback (webhook, WhatsApp Infobip) fall back to the generic scheme.
- **Policy** in `InboundController.verify_inbound_signature/2`:
  - a signature that is present but invalid is **always** rejected with 401, whatever the flag says;
  - on channels with `require_signature: true`, a missing or legacy signature is rejected with 401;
  - on channels with `require_signature: false`, missing and legacy signatures are accepted and a `DEPRECATED` warning is logged with the channel id.
- **Migration**: existing rows are backfilled with `require_signature = false`, then the column default becomes `true`, so every channel created after the upgrade is strict.
- **Raw body**: `CacheBodyReader` caches the body for every `/api/v1/channels/*` path and accumulates chunked (`:more`) reads, so `/status` is verified over the same bytes as `/inbound`.
- A WhatsApp Meta channel with `require_signature: true` must have `app_secret` in its config; the changeset rejects it otherwise.

The flag is per channel rather than global because the risk and the sender capabilities differ per integration: a Meta channel can always be strict, while an Infobip channel has no native scheme yet and may need a signing proxy.

## Consequences

### Positive

- Forged messages and forged receipts are rejected on every channel that has the flag on, which is every channel created after the upgrade.
- A tampered body on `/status` is rejected even on permissive channels, because an invalid signature always fails.
- Replay is bounded to the tolerance window.
- WhatsApp Meta webhooks are authenticated with the signature Meta actually sends.
- Secret rotation works by sending two `v1=` values during the changeover.
- Outbound webhooks reuse the same scheme, so receivers verify Converger requests with the same code they use to sign inbound ones ([ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md)).

### Negative and trade-offs

- **Breaking for new channels**: unsigned inbound and status webhooks are rejected by default. Integrators must sign or explicitly create the channel with `require_signature: false`.
- **WhatsApp Infobip** has no native scheme in Converger yet. New Infobip channels must send `x-converger-signature` (for example through a signing proxy) or be created with `require_signature: false`.
- Clients that previously sent wrong signatures to `/status` used to be accepted and now get 401.
- Senders need a clock within 5 minutes of the server.
- Within the tolerance window a captured request can still be replayed. Replayed inbound messages that carry a provider id are deduplicated by the idempotency key ([ADR-0015](0015-per-message-idempotent-inbound-batches.md)), but there is no nonce store.
- Permissive channels remain unauthenticated until an operator flips the flag. The deprecation log is the only signal.

### Follow-ups

- [#36](https://github.com/AimTune/converger/issues/36): adapter behaviour v2, which formalizes provider signature verification alongside `capabilities/0` and `config_schema/0`.
- [#39](https://github.com/AimTune/converger/issues/39): Slack adapter with signing-secret verification through the same callback.
- [#47](https://github.com/AimTune/converger/issues/47): server-side SDKs with signature helpers.
- A future release is expected to remove the permissive mode and the legacy `sha256=` format (the deprecation message announces this; no issue tracks it yet).

## Implementation

- Generic scheme, signing helper and tolerance: [`lib/converger/channels/inbound_signature.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/inbound_signature.ex) (`verify/3`, `sign/3`, `sign_legacy/2`, `tolerance_seconds/0`).
- Optional callback and fallback dispatch: [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex) (`verify_inbound_signature/3`).
- Meta `X-Hub-Signature-256`: [`lib/converger/channels/adapters/whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex).
- Policy: [`lib/converger_web/controllers/inbound_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex), used by both `create/2` and `status/2`.
- Raw body cache: [`lib/converger_web/cache_body_reader.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/cache_body_reader.ex), wired as the `Plug.Parsers` `body_reader` in [`lib/converger_web/endpoint.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex).
- Schema field and `app_secret` validation: [`lib/converger/channels/channel.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/channel.ex) (`require_signature`, default `true`).
- Migration: [`priv/repo/migrations/20261008120000_add_require_signature_to_channels.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008120000_add_require_signature_to_channels.exs) (backfill `false`, then default `true`).
- Config: `config :converger, inbound_signature_tolerance_seconds: 300` in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs).
- Admin UI: "Require signed inbound webhooks" on channel create, a per-row toggle, and an `app_secret` field for WhatsApp Meta.

Example of a valid header for a body `{"text":"hi"}` signed at `t=1760000000`:

```http
POST /api/v1/channels/<channel_id>/inbound HTTP/1.1
content-type: application/json
x-converger-signature: t=1760000000,v1=<hex HMAC-SHA256 of "1760000000.{\"text\":\"hi\"}">

{"text":"hi"}
```

Tests: [`test/converger_web/controllers/inbound_signature_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_signature_test.exs) covers unsigned requests, tampered bodies, wrong secrets, stale timestamps, malformed headers, legacy format accepted or rejected depending on the flag, the deprecation log, Meta valid/invalid/tampered/missing signatures, a generic signature not accepted for Meta, and `app_secret` validation. Other inbound and status tests sign their requests through the `ConnCase.signed_post/5` helper.

## Links

- Issue [#9](https://github.com/AimTune/converger/issues/9), pull request [#77](https://github.com/AimTune/converger/pull/77)
- [Outbound webhooks and signature verification](../webhooks.md)
- [Security overview](../security.md)
