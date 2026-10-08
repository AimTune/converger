---
title: "ADR-0014: Webhook SSRF guard with DNS pinning, outbound HMAC signing and bounded requests"
sidebar_label: "0014 Webhook hardening"
description: Webhook targets are resolved and checked against non-public ranges at config time and before every request, the request is pinned to the checked IP, and every delivery is signed, method-allowlisted, time-limited and size-limited.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#14](https://github.com/AimTune/converger/issues/14) |
| **Pull request** | [#87](https://github.com/AimTune/converger/pull/87) |
| **Related** | [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0011](0011-custom-trusted-proxies-plug.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) |

The generic `webhook` channel adapter lets a tenant configure an arbitrary URL that Converger will call with every activity. That makes the delivery worker an HTTP client whose target is chosen by a tenant, which is the textbook setup for server-side request forgery (SSRF). This ADR records the guard against that, and the other hardening applied to the same adapter at the same time: outbound signatures, the method allowlist, timeouts, response limits and header rules.

## Context and problem statement

`Converger.Channels.Adapters.Webhook` had several independent problems:

- **SSRF**: there was no check on the target. A tenant could point a webhook at `http://169.254.169.254/` (cloud instance metadata, often including credentials), `localhost:5432`, or any internal service reachable from the Converger node, and read the response status (and body length and timing) through delivery results. Redirects were followed by default, so even a public URL could bounce the request inward.
- **Crash on an unknown method**: `String.to_existing_atom/1` on `config["method"]` raised `ArgumentError` when the atom (for example `:patch`) had never been loaded, crashing the delivery job instead of failing it.
- **Unsigned requests**: receivers could not verify that a payload came from Converger, which was asymmetric with the inbound `x-converger-signature` ([ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md)).
- **Unbounded requests**: a fixed 10 s timeout, no connect timeout, and an unbounded response body read. A slow or huge response tied up a delivery worker and its memory.
- **Header override**: `config["headers"]` could set `host` or `content-length`, producing malformed or misrouted requests.
- **Empty inbound activities**: `parse_inbound/2` silently fell back to an `"external"` sender with `nil` text, creating empty activities.

## Decision drivers

- No tenant-controlled request may reach loopback, private, link-local (metadata), or otherwise non-public addresses, including through DNS tricks or redirects.
- Operators must be able to allow specific internal targets deliberately (for example a service in the same cluster).
- Receivers need a verifiable signature with a simple, documented algorithm, ideally the same as inbound.
- Misconfiguration must be caught when the channel is saved, and must fail a delivery cleanly (never crash a worker) for rows saved earlier.
- Retries belong to the delivery pipeline, not to the HTTP client.
- Tests must not perform real DNS lookups.

## Considered options

1. **Resolve the host, reject every non-public address, pin the connection to a checked IP, disable redirects** - validated at config time and again before every request.
2. **Validate the URL string only at config time** - reject IP literals in private ranges and names like `localhost`.
3. **Route all webhook traffic through an egress proxy** (for example Smokescreen) that enforces the policy.
4. **Network-level egress policy only** (firewall or Kubernetes `NetworkPolicy`).

For signing, the realistic alternatives were reusing the inbound `t=<unix>,v1=<hmac>` scheme, an untimestamped HMAC, or asymmetric signatures (Ed25519 with a published public key).

### Pros and cons of the options

**Option 1: resolve, check all addresses, pin, no redirects**

- Good: closes DNS rebinding: the IP that passed the check is the IP the socket connects to, and the original host name is kept for the `Host` header, TLS SNI and certificate verification (`connect_options: [hostname: host]`).
- Good: every resolved address (IPv4 and IPv6) must pass, so a name with one public and one private record is rejected.
- Good: works in every deployment without extra infrastructure.
- Bad: one DNS resolution per delivery.
- Bad: a block list must be maintained in code.

**Option 2: string check at config time only**

- Good: trivial.
- Bad: a public DNS name can resolve to `127.0.0.1` or change its answer after the check (rebinding).
- Bad: misses IPv4-mapped IPv6, decimal or octal IP spellings and NAT64 or 6to4 prefixes.

**Option 3: egress proxy**

- Good: central policy, also covers other outbound HTTP.
- Bad: another service to deploy and operate; not available in docker compose or simple setups.
- Could still be layered on top of option 1.

**Option 4: network policy only**

- Good: enforced outside the application.
- Bad: depends entirely on the operator; the default deployment would remain open.
- Recommended as defense in depth, not as the only control.

**Signing: reuse inbound scheme vs alternatives**

- Reusing `t=<unix>,v1=<hex HMAC-SHA256(secret, "t.body")>` gives replay protection, needs no new key material (the channel secret already exists) and lets one verification snippet serve both directions.
- An untimestamped HMAC has no replay protection.
- Ed25519 avoids shared secrets but needs key management, publication and rotation that Converger does not have yet.

## Decision

Chosen option: **"Resolve, check every address, pin the connection, disable redirects"** for SSRF, and **the inbound `t=...,v1=...` scheme** for outbound signing, because together they close SSRF including DNS rebinding with no new infrastructure, and give receivers a signature they can verify with the same code Converger documents for inbound requests.

**`Converger.Channels.UrlGuard`**

- Only `http` and `https` URLs with a host are accepted.
- Blocked ranges: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10` (CGNAT), `127.0.0.0/8`, `169.254.0.0/16` (link-local and metadata), `172.16.0.0/12`, `192.0.0.0/24`, `192.0.2.0/24`, `192.88.99.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, and for IPv6 `::/96`, `64:ff9b::/96`, `64:ff9b:1::/48`, `100::/64`, `2001:db8::/32`, `2002::/16`, `fc00::/7`, `fe80::/10`, `fec0::/10`, `ff00::/8`. IPv4-mapped IPv6 is checked as IPv4 (through the shared `ConvergerWeb.IpMatcher`, see [ADR-0011](0011-custom-trusted-proxies-plug.md)).
- `check/1` runs during channel config validation. A host that cannot be resolved at that moment is accepted, because it is checked again at request time.
- `resolve/1` runs before every request: it resolves all A and AAAA records, requires every address to pass, and returns the IP to pin (IPv4 preferred). IP literals are checked directly and need no pinning.
- Escape hatches: `config :converger, :webhook, allowed_targets: [...]` (exact hosts, `*.suffix` wildcards, IPs or CIDR ranges) and `allow_private_targets: true`. Releases set them with `WEBHOOK_ALLOWED_TARGETS` and `WEBHOOK_ALLOW_PRIVATE_TARGETS`. Dev allows `localhost`, `127.0.0.0/8` and `::1`.
- The resolver is configurable (`resolver:`); tests use `Converger.TestDnsResolver`.

**Request construction in the webhook adapter**

- The body is the canonical activity JSON plus `timestamp`, encoded once; that exact string is both signed and sent.
- Headers: `x-converger-signature: t=<unix>,v1=<hex HMAC-SHA256(channel.secret, "<t>.<body>")>` (omitted only if the channel has no secret), `x-converger-event: activity.created`, `x-converger-delivery-id` (stable across retries), and `content-type: application/json`.
- Method allowlist `POST` (default), `PUT`, `PATCH`, case-insensitive, mapped through a static map instead of atom conversion. Any other value fails config validation; a bad value already stored fails the delivery with a permanent error.
- `redirect: false` (a `3xx` is a failed delivery) and `retry: false` (the pipeline owns retries).
- Limits per channel config, capped: `connect_timeout` (default 5 s, max 30 s), `receive_timeout` (default 10 s, max 60 s), `max_response_bytes` (default 1 MB, max 10 MB; the rest of the body is discarded and the connection closed). App-wide defaults can be changed under `config :converger, :webhook`.
- User headers may not set `host`, `content-length`, `content-type`, hop-by-hop headers or anything starting with `x-converger-`; values must be strings. They are rejected at validation and stripped at request time for channels saved earlier.

**Inbound side**: `parse_inbound/2` returns `{:error, :empty_inbound_message}` (HTTP 422) for a `message` with no text and no attachments.

## Consequences

### Positive

- Tenants cannot use webhooks to reach metadata endpoints, databases or internal services, including through DNS rebinding or redirects.
- Receivers can verify origin and freshness with the documented snippets (Node.js, Python, Elixir) and a test vector in [`docs/webhooks.md`](../webhooks.md).
- `x-converger-delivery-id` lets receivers deduplicate retried deliveries.
- A slow or oversized response can no longer pin a worker or exhaust memory.
- Unknown methods are configuration errors, not worker crashes.

### Negative and trade-offs

- **Breaking**: webhooks pointing at private, loopback or link-local addresses (including hosts that resolve to them, such as `localhost`) are rejected; existing channels like that start failing deliveries until `WEBHOOK_ALLOWED_TARGETS` covers them.
- Redirects are no longer followed; receivers that relied on them must publish the final URL.
- `method` and `headers` are validated when a channel is saved, so editing an old channel may require fixing its config.
- An inbound `message` with no text or attachments returns 422 instead of creating an empty activity.
- One DNS lookup per delivery, with a 5 s resolver timeout. An unresolvable host is treated as transient and retried; a blocked target is permanent.
- `allow_private_targets: true` disables the guard entirely; it is meant for development.
- The guard is only wired into the webhook adapter. The WhatsApp adapters call fixed provider hosts and need it less, but the per-tenant `alert_webhook_url` (health alerts, set in the admin tenant UI and sent through `Converger.HTTP.post/2` in `Converger.Channels.Health`) is a configurable URL that does **not** go through `UrlGuard` today. It is admin-controlled rather than tenant-controlled, which limits the exposure.

### Follow-ups

- [#49](https://github.com/AimTune/converger/issues/49): platform event webhooks, which are to reuse this signing scheme and should reuse the guard; migrating `alert_webhook_url` there brings it under the same rules.
- [#47](https://github.com/AimTune/converger/issues/47): SDKs with signature verification helpers.
- [#31](https://github.com/AimTune/converger/issues/31): per-channel circuit breaker so a dead webhook does not consume the shared delivery queue.
- Retry classification of webhook errors (`DeliveryError`) and the per-channel timeout fallback were added later by [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md): when the channel config has no explicit `receive_timeout`, the channel retry policy's `timeout_ms` (capped at 60 s) is used.

## Implementation

- Guard: [`lib/converger/channels/url_guard.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/url_guard.ex) (`check/1`, `resolve/1`, `blocked_ip?/1`, `resolve_host/1`).
- Adapter: [`lib/converger/channels/adapters/webhook.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex) (`validate_config/1`, `deliver_activity/2`, header and limit helpers).
- Signing helper shared with inbound: [`lib/converger/channels/inbound_signature.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/inbound_signature.ex) (`sign/3`).
- Config: `WEBHOOK_ALLOWED_TARGETS` and `WEBHOOK_ALLOW_PRIVATE_TARGETS` in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs); dev allowlist in `config/dev.exs`; deterministic resolver in `config/test.exs` and [`test/support/test_dns_resolver.ex`](https://github.com/AimTune/converger/blob/main/test/support/test_dns_resolver.ex).
- Test hook: `config :converger, :webhook_req_options` (for example `plug: {Req.Test, ...}`) is merged into the Req options.

Example channel config:

```json
{
  "url": "https://hooks.example.com/converger",
  "method": "POST",
  "headers": {"authorization": "Bearer <token>"},
  "connect_timeout": 5000,
  "receive_timeout": 10000,
  "max_response_bytes": 1048576
}
```

Tests: [`test/converger/channels/adapters/webhook_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/webhook_test.exs) (method allowlist, reserved headers, limit validation, empty inbound messages); [`test/converger/channels/adapters/webhook_delivery_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/webhook_delivery_test.exs) (signature verifies with `InboundSignature.verify/3`, the documented test vector, delivery id through the real pipeline, header stripping, PATCH, invalid stored method, IP pinning, no redirect follow, response truncation, DNS rebinding rejected at request time, stored private literals, unresolvable host, allowlist and `allow_private_targets`); [`test/converger_web/controllers/inbound_mode_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_mode_test.exs) (422 for an empty inbound message).

## Links

- Issue [#14](https://github.com/AimTune/converger/issues/14), pull request [#87](https://github.com/AimTune/converger/pull/87)
- [Outbound webhooks: config, headers, verification, SSRF protection](../webhooks.md)
