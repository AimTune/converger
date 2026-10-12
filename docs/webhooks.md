---
sidebar_label: Webhook
description: The webhook channel adapter - outbound JSON delivery, request signing, SSRF guard, method allowlist, timeouts and response limits.
---

# Outbound webhooks

A `webhook` channel delivers every activity to the configured URL as JSON.

To receive tenant-wide events (every activity, delivery status changes, conversation lifecycle, channel health)
without a channel per conversation, use [platform event webhooks](platform-webhooks.md) instead. They share this
page's signature scheme and SSRF guard.

## Channel config

| Key | Default | Notes |
| --- | --- | --- |
| `url` | required | `http` or `https`. Private, loopback and link-local targets are rejected (see below). |
| `method` | `POST` | One of `POST`, `PUT`, `PATCH`. Anything else is a config validation error. |
| `headers` | `{}` | Extra headers, string values only. `host`, `content-length`, `content-type`, hop-by-hop headers (`connection`, `transfer-encoding`, ...) and `x-converger-*` are reserved. |
| `connect_timeout` | `5000` | Milliseconds, at most `30000`. |
| `receive_timeout` | `10000` | Milliseconds, at most `60000`. When unset, the channel's `retry_policy.timeout_ms` is used (see `Converger.Pipeline.RetryPolicy`). |
| `max_response_bytes` | `1048576` | Bytes of the response that are read, at most 10 MB. The rest is discarded. |

Redirects are not followed. A `3xx` response counts as a failed delivery.
Any `2xx` response is a success.

## Request headers

Every request carries:

```
content-type: application/json
x-converger-event: activity.created
x-converger-delivery-id: <delivery id, the same on every retry>
x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256>
```

Use `x-converger-delivery-id` to drop duplicate deliveries: a delivery is
retried after timeouts and errors, so your endpoint can see it more than once.

## Verifying the signature

The signature uses the same scheme as inbound requests. `v1` is the
lowercase hex HMAC-SHA256 of `"<t>.<raw request body>"`, keyed with the
channel `secret`.

1. Split the header on `,` and read `t` and `v1`.
2. Reject the request if `t` is more than 5 minutes away from your clock.
3. Compute the HMAC over `t + "." + raw_body`. Use the raw bytes you
   received, before any JSON parsing.
4. Compare with `v1` in constant time.

Details that matter for an exact match with the server:

- The header may carry several `v1` values (secret rotation); one match is enough. Parts are trimmed, unknown
  parts are ignored, and the order of `t` and `v1` does not matter.
- `t` is an integer (digits with an optional sign). A header without `t` or `v1`, or with a non-integer `t`, is
  malformed. Outbound webhooks never use the legacy `sha256=<hex>` form, so reject it.
- The boundary is inclusive: `|now - t| = 300` is accepted, 301 is not.
- `v1` is lowercase hex and is compared as sent; an uppercase hex value does not match.

### SDK helpers

The server-side SDKs implement exactly these rules, with constant-time comparison and secret lists for rotation:

| SDK | Call |
| --- | --- |
| Python | `converger.verify_signature(headers, raw_body, secret)` raises `WebhookSignatureError(reason)` ([Python SDK](sdk/python.md#webhook-signature-verification), with FastAPI and Flask examples) |
| Go | `converger.VerifySignature(r.Header, body, secret)` returns a `*SignatureError` ([Go SDK](sdk/go.md#webhook-signature-verification)) |
| Elixir | `ConvergerClient.Webhook.verify_signature(conn.req_headers, raw_body, secret)` returns `:ok` or `{:error, reason}` ([Elixir client](sdk/elixir.md#webhook-signature-verification)) |

The failure reasons are the same everywhere: `missing_signature`, `no_secret`, `malformed_signature`,
`timestamp_out_of_tolerance`, `invalid_signature`.

### Test vectors

```
secret:  whsec_test_secret
t:       1700000000
body:    {"id":"9b2f6c1e-0000-4000-8000-000000000001","text":"hello"}
header:  t=1700000000,v1=c8945aa2aa4e6d043cdd46907fdf4ab1d4cedd12737ea10bb6f246ed39533a8a
```

The full set is
[`packages/conformance/webhook-signatures.json`](https://github.com/AimTune/converger/blob/main/packages/conformance/webhook-signatures.json):
`sign` vectors (secret, timestamp, body, expected header; including a realistic activity body, non-ASCII UTF-8, an
empty body and significant whitespace) and `verify` vectors (headers, body, secret or secret list, a fixed `now`,
an optional `tolerance`, and the expected result or failure reason). The file is generated from the server's own
signer (`Converger.Channels.InboundSignature.sign/3`) by
`mix run --no-start packages/conformance/scripts/generate_signature_vectors.exs`, and
`test/converger/channels/webhook_signature_vectors_test.exs` fails if the signer and the file disagree. Every SDK
runs all of the vectors; use them to test your own verifier too.

### Node.js

```js
const crypto = require("crypto");

function verify(secret, header, rawBody, toleranceSeconds = 300) {
  const parts = Object.fromEntries(header.split(",").map((p) => p.trim().split("=", 2)));
  const t = Number(parts.t);
  if (!Number.isInteger(t) || Math.abs(Date.now() / 1000 - t) > toleranceSeconds) return false;
  const expected = crypto.createHmac("sha256", secret).update(`${t}.${rawBody}`).digest("hex");
  const given = Buffer.from(parts.v1 || "", "utf8");
  return given.length === expected.length && crypto.timingSafeEqual(given, Buffer.from(expected));
}
```

### Python

```python
import hashlib, hmac, time

def verify(secret: str, header: str, raw_body: bytes, tolerance: int = 300) -> bool:
    parts = dict(p.strip().split("=", 1) for p in header.split(","))
    t = int(parts["t"])
    if abs(time.time() - t) > tolerance:
        return False
    expected = hmac.new(secret.encode(), f"{t}.".encode() + raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, parts.get("v1", ""))
```

### Elixir

```elixir
def verify(secret, header, raw_body, tolerance \\ 300) do
  parts = header |> String.split(",") |> Map.new(&List.to_tuple(String.split(String.trim(&1), "=", parts: 2)))
  t = String.to_integer(parts["t"])
  expected = :crypto.mac(:hmac, :sha256, secret, "#{t}.#{raw_body}") |> Base.encode16(case: :lower)

  abs(System.system_time(:second) - t) <= tolerance and
    Plug.Crypto.secure_compare(expected, parts["v1"] || "")
end
```

## SSRF protection

Webhook URLs are checked when the channel is saved and again before every
request. A URL is rejected when its host is, or resolves to, a non-public
address:

- IPv4: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`,
  `169.254.0.0/16` (includes the `169.254.169.254` metadata endpoint),
  `172.16.0.0/12`, `192.168.0.0/16`, `192.0.0.0/24`, documentation and
  benchmarking ranges, multicast and reserved space.
- IPv6: `::/96` (includes `::` and `::1`), `fc00::/7` (includes
  `fd00:ec2::254`), `fe80::/10`, `fec0::/10`, `ff00::/8`, `2001:db8::/32`,
  and the IPv4-embedding prefixes `64:ff9b::/96`, `64:ff9b:1::/48` and
  `2002::/16`. IPv4-mapped addresses (`::ffff:a.b.c.d`) are checked as IPv4.

Before each request the host is resolved, every returned address must pass,
and the connection is pinned to a checked address (the original host name is
still used for the `Host` header, TLS SNI and certificate checks). A DNS
answer that changes after the check (DNS rebinding) cannot redirect the
request to an internal address. A host that cannot be resolved when the
channel is saved is accepted, and fails delivery until it resolves.

To reach internal services on purpose, an operator can allow them:

| Variable | Example |
| --- | --- |
| `WEBHOOK_ALLOWED_TARGETS` | `hooks.internal,*.svc.cluster.local,10.20.0.0/16` |
| `WEBHOOK_ALLOW_PRIVATE_TARGETS` | `true` (disables the guard, development only) |

Host entries match the URL host exactly (case-insensitive), `*.` matches any
subdomain, and IP/CIDR entries match resolved addresses. In development,
`localhost`, `127.0.0.0/8` and `::1` are allowed by `config/dev.exs`.

## Inbound requests

`POST /api/v1/channels/:id/inbound` on a webhook channel returns `422` when a
`message` has neither text (`text`, `message` or `body`) nor attachments.

## Retries

Failed deliveries are retried according to the channel's `retry_policy`
(`max_attempts`, `backoff`, `base_ms`, `max_ms`; see
`Converger.Pipeline.RetryPolicy`). A `429` honours `Retry-After`. Other `4xx`
responses, redirects, an invalid `method` and targets blocked by the SSRF
guard are permanent: the delivery is dead-lettered after one attempt. `408`,
`425`, `5xx`, transport errors and hosts that cannot be resolved are retried.
