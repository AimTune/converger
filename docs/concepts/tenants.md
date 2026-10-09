---
title: Tenants
description: Tenants isolate customers of a Converger installation - hashed API keys with rotation, status, per-tenant rate limits, health alert webhooks, and portal users.
sidebar_position: 2
---

A tenant is an isolated customer of a Converger installation. Every channel, conversation, participant, activity, routing rule, attachment and tenant user belongs to exactly one tenant. Every API path derives the tenant from its credentials (API key, token, channel secret) or from the channel an inbound webhook targets, never from a tenant id in the request, and all queries are scoped to it.

Source: [`lib/converger/tenants/tenant.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/tenants/tenant.ex), [`lib/converger/tenants.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/tenants.ex).

## Schema

Table `tenants`:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | uuid | Primary key. |
| `name` | text | Required. Tenant users type it to log in to the portal. |
| `api_key_hash` | binary | SHA-256 digest of the current API key. Unique, never shown. |
| `api_key_prefix` | text | The first characters of the key, for display only (`cvg_live_abcd****`). |
| `previous_api_key_hash` | binary | Digest of the key replaced by the last rotation. |
| `previous_api_key_expires_at` | utc_datetime_usec | Until when the previous key is still accepted. |
| `status` | text | Defaults to `"active"`. Only active tenants authenticate. The admin panel toggles between `active` and `inactive`. |
| `alert_webhook_url` | string | Optional `http`/`https` URL for channel health alerts. |
| `limits` | map, default `{}` | Per-tenant rate-limit overrides (see below). |
| `allowed_upload_types` | text array | Optional MIME allowlist for uploads. `NULL` or empty means the global default ([storage](../storage.md)). |
| `inserted_at`, `updated_at` | utc_datetime_usec | |

`api_key` also exists as a **virtual**, redacted field. It holds the plaintext key only on the struct returned right after creation or rotation, so it can be shown once. It is never persisted.

## API keys

### Format and storage

`Tenant.generate_api_key/0` produces `cvg_live_` followed by 32 random bytes in unpadded URL-safe Base64. On insert, the changeset generates a key, stores `Converger.Secrets.hash/1` (SHA-256) as `api_key_hash`, and keeps the first 13 characters (the `cvg_live_` prefix plus 4 random characters) as `api_key_prefix`.

The migration [`20261008100001_hash_tenant_api_keys`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008100001_hash_tenant_api_keys.exs) replaced the plaintext `tenants.api_key` column with these hashes (issue [#12](https://github.com/AimTune/converger/issues/12)). Existing keys kept working: the digest of each old value was stored, with `left(api_key, 4)` as its prefix. The migration is irreversible: plaintext keys cannot be recovered, and a lost key can only be rotated. See [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md).

### Authentication

Server-to-server routes under `/api/v1` (conversations, activities, routing rules) authenticate with the `x-api-key` header through `ConvergerWeb.Plugs.TenantAuth`. The presented key is hashed and looked up by `api_key_hash`, or by `previous_api_key_hash` while `previous_api_key_expires_at` is in the future. The tenant must have `status: "active"`. Otherwise the response is `401` with `{"error": "Unauthorized: Invalid or inactive API Key"}`.

The same plug also accepts a channel token in `x-channel-token`, and then resolves the tenant from the token's `tenant_id` claim. Only channel tokens are accepted there: end-user tokens (legacy conversation tokens and Converger API tokens) are refused with `401` `Unauthorized: Invalid token`. `x-channel-token` is deprecated; `x-api-key` is not (see [migrating from the legacy surfaces](../api/migrating-from-legacy.md)). Listing conversations (`GET /api/v1/conversations`) requires the API key specifically, because it exposes other end users' conversations. See the [tenant API](../api/tenant-api.md).

### Rotation

`Converger.Tenants.rotate_api_key/2` (the **Rotate** button on **Admin, Tenants**):

1. moves the current hash to `previous_api_key_hash` and sets `previous_api_key_expires_at = now + grace`;
2. generates a new key and shows it once;
3. writes an audit log entry with action `rotate_api_key` when an actor is given.

| Setting | Default | Description |
| --- | --- | --- |
| `config :converger, :api_key_rotation_grace_period` | `86400` (24 h) | Seconds during which the previous key remains valid. `rotate_api_key/2` also accepts `grace_period:` per call. |

Only one previous key is kept. A second rotation inside the grace period invalidates the first key immediately.

## Status

Tenants are created `active`. An inactive tenant:

- fails `x-api-key` authentication on `/api/v1`;
- fails `x-channel-token` authentication (`"Unauthorized: Tenant is not active"`);
- cannot obtain conversation tokens from the legacy, deprecated `POST /api/v1/tokens` (`403`).

The client API (`/api/v1/converger`) and its sockets check the **channel**'s status. Deactivating a channel disconnects its sockets ([channels](channels.md#status)). Deleting a tenant cascades to all its data.

## Rate-limit overrides

Rate limits are fixed-window counters (Hammer 7) on the hot paths ([ADR-0013](../adr/0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [deployment](../deployment.md#rate-limiting)). Four buckets can be overridden per tenant through `tenants.limits` (migration [`20261009130000_add_limits_to_tenants`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009130000_add_limits_to_tenants.exs)):

| Bucket | Default | Counted per | Applies to |
| --- | --- | --- | --- |
| `activity_create` | 100 per 1000 ms | tenant | `POST /api/v1/conversations/:id/activities`, `POST /api/v1/converger/conversations/:id/activities` |
| `upload` | 10 per 1000 ms | tenant | `POST /api/v1/converger/conversations/:id/upload` |
| `inbound` | 500 per 1000 ms | channel | `POST /api/v1/channels/:id/inbound`, `POST /api/v1/channels/:id/status` |
| `token_generate` | 10 per 60000 ms | channel | `POST /api/v1/converger/tokens/generate`, `/tokens/refresh` |

The value maps a bucket name to exactly two positive integers:

```json
{
  "activity_create": { "limit": 200, "scale_ms": 1000 },
  "inbound": { "limit": 2000, "scale_ms": 1000 }
}
```

An empty map means the installation defaults apply. Set overrides with `Converger.Tenants.update_tenant_limits/3`, for example from a remote console:

```elixir
tenant = Converger.Tenants.get_tenant!("3f2a1b0c-...")
Converger.Tenants.update_tenant_limits(tenant, %{"inbound" => %{"limit" => 2000, "scale_ms" => 1000}})
```

`Tenant.limits_changeset/2` rejects unknown buckets, non-positive or non-integer values, and extra keys. Overrides are cached for 30 s per node (`override_cache_ttl_ms`) and invalidated cluster-wide on update. There is no admin UI or REST endpoint for limits yet. The management API is Planned ([#51](https://github.com/AimTune/converger/issues/51)).

## Alert webhook

When `alert_webhook_url` is set, the channel health worker (`Converger.Workers.ChannelHealthWorker`, every 5 minutes) POSTs a JSON alert whenever the health status of one of the tenant's channels changes ([channels](channels.md#health-checks)):

```json
{
  "event": "channel_health_changed",
  "channel_id": "8d1e...",
  "channel_name": "support-webhook",
  "tenant_id": "3f2a...",
  "previous_status": "healthy",
  "new_status": "degraded",
  "failure_rate": 0.25,
  "total_deliveries": 40,
  "failed_deliveries": 10,
  "checked_at": "2026-10-09T10:20:00.000000Z"
}
```

The request is fire-and-forget (a `Task`, 10 s receive timeout). It is not retried, and only the outcome is logged. Durable, signed platform event webhooks are Planned ([#49](https://github.com/AimTune/converger/issues/49)).

## Admin users and tenant users

Converger has two kinds of human accounts, both with bcrypt-hashed passwords (minimum 8 characters) and status `active`/`inactive`:

| | Admin users (`admin_users`) | Tenant users (`tenant_users`) |
| --- | --- | --- |
| Scope | The whole installation. | One tenant (`tenant_id`). Email is unique per tenant. |
| UI | Admin panel, `/admin` | Tenant portal, `/portal` |
| Network | IP allowlist `ADMIN_IP_WHITELIST` (default `127.0.0.1,::1`), proxy-aware through `TRUSTED_PROXIES` | No IP allowlist |
| Login | `/admin/login` with email and password | `/portal/login` with **tenant name**, email and password |
| Roles | `super_admin`, `admin`, `viewer` | `owner`, `admin`, `member`, `viewer` |
| Created by | `Converger.Release.seed_admin/0` or `priv/repo/seeds.exs` (first `super_admin`), then **Admin, Users** | **Admin, Tenant Users**, or portal users with role `owner`/`admin` |

Role effects in the current UI:

- Admin: only a `super_admin` manages admin users. A `viewer` cannot change tenant users and has read-only access to the Oban dashboard (`/admin/oban`). `super_admin` and `admin` have full access.
- Portal: `owner`, `admin` and `member` can toggle channel status and edit routing rules. `owner` and `admin` manage the tenant's users. `viewer` is read-only. Portal users cannot create channels or rotate API keys.

The first admin created without `ADMIN_PASSWORD` gets a generated password and `must_change_password: true`. It is redirected to `/admin/password` until the password is changed. Login attempts are throttled per IP and per account (5 failures per minute each). See [Getting started](../getting-started.md#4-create-the-first-admin-account) and [security](../security.md).

Create, update, delete, status-toggle and key-rotation operations made through the admin panel (and routing rule changes made through the tenant API) write an audit log entry. Sensitive values are redacted ([ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md)).
