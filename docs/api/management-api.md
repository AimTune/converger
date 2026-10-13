---
title: Management API
description: Provision tenants, channels, routing rules, webhook subscriptions, portal users, settings and scoped API keys over REST - /api/v1/manage and /api/v1/admin, scopes, ETags and If-Match.
sidebar_position: 2.5
---

Everything you can set up in the admin panel or the tenant portal can also be done over REST. Use it to provision a
channel from your own onboarding flow, or to manage Converger with infrastructure as code (Terraform, Pulumi, a CI
script). There are two parts:

| Part | Prefix | Who | Credential |
| --- | --- | --- | --- |
| Management API | `/api/v1/manage/...` | A tenant, for its own configuration | Tenant API key with the `manage` scope (`x-api-key`) |
| Admin API | `/api/v1/admin/...` | The platform operator | `ADMIN_API_TOKEN` (`Authorization: Bearer`), from an IP in the admin allowlist |

Routing rules, platform webhook subscriptions and channel pause/resume already have tenant API routes
([routing rules](tenant-api.md#routing-rules), [webhooks](tenant-api.md#platform-event-webhooks),
[channel delivery state](tenant-api.md#pause-and-resume-deliveries)). They stay where they are, and changing them
needs the `manage` scope. The design is recorded in
[ADR-0061](../adr/0061-scoped-api-keys-and-the-management-api.md).

Every operation is in the [OpenAPI document](openapi.md) under the **Management** and **Admin** tags.

## API keys and scopes

A tenant has two kinds of key, both sent in `x-api-key` and both shaped `cvg_live_...`:

- **The primary key** is issued with the tenant and rotated by an operator (admin panel, or
  [`rotate_api_key`](#tenants)). It has every scope, so existing integrations keep working unchanged.
- **Scoped keys** have only some of the scopes, an optional expiry, and a name. Create them with
  [`POST /api/v1/manage/api_keys`](#api-keys) or the [admin API](#tenant-api-keys-admin). Revoking a key stops it at
  once. A revoked key is still listed.

| Scope | Allows |
| --- | --- |
| `read` | Every `GET` of the tenant API (conversations, activities, deliveries, routing rules, webhook subscriptions and events, channel state, templates and outbox), and the routing dry-run |
| `write` | Changes to conversation data: post activities, close and reopen conversations, retry deliveries, acknowledge the pull outbox, redeliver webhook events |
| `manage` | Configuration: everything under `/api/v1/manage`, creating, changing and deleting routing rules and webhook subscriptions (and rotating their secrets), pausing and resuming channels |

The scopes are separate: `manage` does not include `read` or `write`. A key for a Terraform pipeline needs only
`manage`. A bot that posts and reads messages needs `read` and `write`. A dashboard needs only `read`.

A call without the scope it needs is refused with `403` and code `insufficient_scope`. `details.required` names the
missing scope:

```json
{ "error": { "code": "insufficient_scope", "message": "The API key lacks the write scope",
             "details": { "required": "write" }, "request_id": "..." } }
```

The deprecated channel token (`x-channel-token`) keeps every scope on the routes that accept it. `/api/v1/manage`
does not accept it and answers `403 forbidden`.

`last_used_at` is updated at most once a minute per key. Only a key's SHA-256 is stored, so the key itself is
returned once, by the create call.

## Conventions

- **Stable ids.** Every resource has a UUID. It never changes, and Terraform state can hold it.
- **Request bodies** wrap the resource: `{"channel": {...}}`, `{"user": {...}}`, `{"settings": {...}}`,
  `{"tenant": {...}}`, `{"api_key": {...}}`. Unknown fields and fields the API does not let you set (a channel's
  `tenant_id` or `secret`, a tenant's key hashes) are ignored.
- **`PUT` and `PATCH`** are the same operation: the fields you send are set, the others are kept. Sending the same
  body twice leaves the resource in the same state, so a `PUT` is safe to retry.
- **ETags.** `GET`, `POST`, `PUT` and `PATCH` responses of channels, users, settings and tenants carry an `ETag`
  header, which changes whenever the resource changes. Send it back in `If-Match` on `PUT`, `PATCH` or `DELETE`. If
  someone changed the resource since you read it, the request is refused with `412 precondition_failed`, and
  `details.current_etag` holds the ETag to fetch again. Without `If-Match` the request applies unconditionally.
  `If-Match: *` always matches.
- **Errors** use the [error envelope](errors.md). Validation errors are `422 validation_failed`, with the errors per
  field in `details`.
- **Audit.** Every change is written to the audit log in the same transaction. The actor is `tenant_api` with the
  key's id (the tenant id for the primary key), or `admin_api` for the admin token.
- **Secrets are returned once:** a channel's `secret` (create and `rotate_secret`), a tenant's primary `api_key`
  (create and `rotate_api_key`), and a scoped key's `key` (create).

## Channels

`/api/v1/manage/channels`, scope `manage`.

| Method and path | Does |
| --- | --- |
| `GET /api/v1/manage/channels` | Lists every channel of the tenant, sorted by name (not paginated, capped at `lookup_limit`) |
| `POST /api/v1/manage/channels` | Creates a channel. `201` with the channel **and its `secret`** |
| `GET /api/v1/manage/channels/:id` | Gets one channel |
| `PUT\|PATCH /api/v1/manage/channels/:id` | Updates a channel (honours `If-Match`) |
| `DELETE /api/v1/manage/channels/:id` | Deletes the channel and its conversations. Their activities and deliveries are purged in the background (honours `If-Match`) |
| `POST /api/v1/manage/channels/:id/rotate_secret` | Issues a new channel secret, returned once. The old one stops working at once |

Writable fields: `name` (required on create), `type` (default `webhook`), `mode`, `status` (`active` or
`inactive`), `require_signature`, `config`, `transformations`, `retry_policy` and `rate_limit`. Validation is the same
as in the admin panel: each [channel type](../channels/overview.md) checks its own `config`.

```bash
curl -X POST https://converger.example.com/api/v1/manage/channels \
  -H "x-api-key: $MANAGE_KEY" -H "content-type: application/json" \
  -d '{"channel": {"name": "crm", "type": "webhook", "mode": "outbound",
                   "config": {"url": "https://crm.example.com/hook",
                              "headers": {"authorization": "Bearer crm-token"}}}}'
```

```json
{
  "data": {
    "id": "8f0c...", "tenant_id": "1b2e...", "name": "crm", "type": "webhook", "mode": "outbound",
    "status": "active", "require_signature": true,
    "config": { "url": "https://crm.example.com/hook", "headers": { "authorization": "[REDACTED]" } },
    "transformations": [], "retry_policy": {}, "rate_limit": null, "circuit_state": "closed",
    "secret": "q3V...", "inserted_at": "...", "updated_at": "..."
  }
}
```

**Secret config values are never returned.** Fields that the channel type marks as secret, and keys that look
like credentials (`authorization`, `api_key`, `*_token`, `*_secret`, `*_password`, ...), come back as
`[REDACTED]`. A `config` you send replaces the stored one. Any value that is still `[REDACTED]`, at any depth,
keeps the stored value. So a tool that reads a channel and sends the `config` back with one change does not wipe
the channel's credentials.

Rotating the secret does not invalidate Converger tokens that were already issued. Revoke them with
[`POST /api/v1/converger/tokens/revoke`](client-api.md) if that is the goal.

## Portal users

`/api/v1/manage/users`, scope `manage`.

| Method and path | Does |
| --- | --- |
| `GET /api/v1/manage/users` | Lists the tenant's portal users, newest first |
| `POST /api/v1/manage/users` | Creates a user: `email`, `name`, `password` (the [password policy](../security/overview.md#password-policy) applies), `role` (`owner`, `admin`, `member` or `viewer`; default `member`), `status` |
| `GET /api/v1/manage/users/:id` | Gets one user |
| `PUT\|PATCH /api/v1/manage/users/:id` | Changes `email`, `name`, `role` or `status` (honours `If-Match`). `password` is ignored. Users change their own password in the portal or by password reset. Setting `inactive` ends the user's sessions |
| `DELETE /api/v1/manage/users/:id` | Deletes the user and ends their sessions (honours `If-Match`) |

A user is returned as `id`, `tenant_id`, `email`, `name`, `role`, `status`, `totp_enabled`, `inserted_at` and
`updated_at`. The password hash and 2FA secret are never returned.

## Settings

`/api/v1/manage/settings`, scope `manage`. `GET` returns the tenant. `PUT` or `PATCH` with `{"settings": {...}}`
changes the settings a tenant manages itself:

| Field | Meaning |
| --- | --- |
| `retention_days` | Days before activities and deliveries are archived and removed ([retention](../operations/retention.md)); at least the configured minimum |
| `alert_webhook_url` | Where channel health alerts are posted (a [managed platform webhook subscription](../platform-webhooks.md)); `null` clears it |
| `allowed_upload_types` | MIME types end users may upload; `null` for the default list |
| `limits` | [Rate-limit overrides](../operations/rate-limiting.md): `{bucket: {"limit": n, "scale_ms": ms}}`. This **replaces** every override. `{}` resets all of them to the defaults |

The `name`, `status` and delivery `tier` are platform settings, which an operator changes through the admin API.
They are ignored here. Invalid `limits` reject the whole request, so nothing is changed.

## API keys

`/api/v1/manage/api_keys`, scope `manage`.

| Method and path | Does |
| --- | --- |
| `GET /api/v1/manage/api_keys` | Lists the tenant's scoped keys, newest first, including revoked ones |
| `POST /api/v1/manage/api_keys` | Issues a key: `name`, `scopes` (at least one), optional `expires_at` (ISO 8601, in the future). `201` with the key's `key` |
| `GET /api/v1/manage/api_keys/:id` | Gets one key, without the key itself |
| `DELETE /api/v1/manage/api_keys/:id` | Revokes the key. `204`; it stays listed with `revoked_at` |

A key can only issue keys with scopes that it has itself. A `manage`-only key cannot mint a `write` key; it gets
`403 insufficient_scope`. The primary key has every scope.

```json
{ "data": { "id": "c41d...", "tenant_id": "1b2e...", "name": "terraform", "prefix": "cvg_live_Ab3x",
            "scopes": ["manage"], "expires_at": null, "last_used_at": null, "revoked_at": null,
            "created_by": "tenant_api:1b2e...", "key": "cvg_live_Ab3x...", "inserted_at": "...", "updated_at": "..." } }
```

## Admin API

The admin API is off until `ADMIN_API_TOKEN` is set: a random string of at least 32 characters, for example from
`openssl rand -base64 48` ([configuration](../operations/configuration.md#network-trust-and-admin-access)). Send it as
`Authorization: Bearer <token>`. Requests must also come from an address in `ADMIN_IP_WHITELIST`, like the admin
panel. Otherwise the answer is `403`. Without a token configured, or with a wrong one, the answer is `401`. Tenant
API keys never unlock it.

Treat the token like a root password: it can create and delete any tenant. Rotate it by changing the variable and
restarting the nodes. Per-admin personal access tokens are a possible follow-up.

### Tenants

| Method and path | Does |
| --- | --- |
| `GET /api/v1/admin/tenants` | Lists every tenant, sorted by name |
| `POST /api/v1/admin/tenants` | Creates a tenant: `name` (required), `status`, `tier` (`high`, `default`, `bulk`), `retention_days`, `alert_webhook_url`, `allowed_upload_types`, `limits`. `201` with the tenant **and its primary `api_key`** |
| `GET /api/v1/admin/tenants/:id` | Gets one tenant |
| `PUT\|PATCH /api/v1/admin/tenants/:id` | Updates any of the fields above (honours `If-Match`). `status: "inactive"` blocks all the tenant's keys |
| `DELETE /api/v1/admin/tenants/:id` | Deletes the tenant with its channels, conversations, users and keys. Activities and deliveries are purged in the background (honours `If-Match`) |
| `POST /api/v1/admin/tenants/:id/rotate_api_key` | Issues a new primary key, returned once. The old one keeps working for the rotation grace period (24 h by default). Scoped keys are unaffected |

### Tenant API keys (admin)

| Method and path | Does |
| --- | --- |
| `GET /api/v1/admin/tenants/:tenant_id/api_keys` | Lists the tenant's scoped keys |
| `POST /api/v1/admin/tenants/:tenant_id/api_keys` | Issues a scoped key with any scopes |
| `DELETE /api/v1/admin/tenants/:tenant_id/api_keys/:id` | Revokes a key |

## Example: provision a tenant from a script

This sets up a tenant end to end with nothing but the API: a tenant, a manage-only key, two channels, a routing
rule between them, and a platform webhook subscription.

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE=https://converger.example.com/api/v1
J='content-type: application/json'

# 1. Operator: create the tenant (the primary key is returned once).
PRIMARY=$(curl -sf -X POST "$BASE/admin/tenants" -H "authorization: Bearer $ADMIN_API_TOKEN" -H "$J" \
  -d '{"tenant": {"name": "acme"}}' | jq -r .data.api_key)

# 2. A manage-only key for the automation.
MANAGE=$(curl -sf -X POST "$BASE/manage/api_keys" -H "x-api-key: $PRIMARY" -H "$J" \
  -d '{"api_key": {"name": "provisioning", "scopes": ["manage"]}}' | jq -r .data.key)

# 3. Channels.
WEB=$(curl -sf -X POST "$BASE/manage/channels" -H "x-api-key: $MANAGE" -H "$J" \
  -d '{"channel": {"name": "web", "type": "websocket"}}' | jq -r .data.id)
CRM=$(curl -sf -X POST "$BASE/manage/channels" -H "x-api-key: $MANAGE" -H "$J" \
  -d '{"channel": {"name": "crm", "type": "webhook", "mode": "outbound",
                   "config": {"url": "https://crm.example.com/hook"}}}' | jq -r .data.id)

# 4. Route every web message to the CRM.
curl -sf -X POST "$BASE/routing_rules" -H "x-api-key: $MANAGE" -H "$J" \
  -d "{\"routing_rule\": {\"name\": \"web to crm\", \"source_channel_id\": \"$WEB\",
                          \"target_channel_ids\": [\"$CRM\"]}}" > /dev/null

# 5. Get told when deliveries fail.
curl -sf -X POST "$BASE/webhook_subscriptions" -H "x-api-key: $MANAGE" -H "$J" \
  -d '{"webhook_subscription": {"url": "https://ops.example.com/converger", "events": ["delivery.failed"]}}' \
  | jq -r .data.secret
```

The test `test/converger_web/controllers/management_api_test.exs` runs this same sequence.

## Related

- [ADR-0061: scoped API keys and the management API](../adr/0061-scoped-api-keys-and-the-management-api.md)
- [Tenant API](tenant-api.md) and [API overview](overview.md#authentication)
- [Security model](../security/overview.md#tenant-api-keys)
- [Errors](errors.md): `insufficient_scope`, `precondition_failed`
