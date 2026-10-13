---
title: "ADR-0061: Scoped API keys and the management API"
sidebar_label: "0061 Scoped API keys and management API"
description: Scoped tenant API keys (read, write, manage) next to the full-access primary key, a /api/v1/manage namespace for new configuration resources, a token-authenticated /api/v1/admin API, and ETag/If-Match on managed resources.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#51](https://github.com/AimTune/converger/issues/51) |
| **Pull request** | To be linked |
| **Related** | [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0050](0050-openapi-spec-error-envelope-and-api-versioning.md), [ADR-0053](0053-platform-event-webhooks.md), [ADR-0059](0059-client-token-keys-revocation-rotation-and-permissions.md) |

## Context and problem statement

Channels, tenants and portal users could only be created in the LiveView UIs. An integrator could not provision a
channel from their own onboarding flow, and could not keep Converger's configuration in infrastructure as code. A
tenant had exactly one API key (`tenants.api_key_hash`), and it could do everything: a read-only dashboard or a
bot that only posts messages had to hold a key that could also delete routing rules. Only routing rules and
webhook subscriptions had REST endpoints.

Issue #51 asks for a management API for the tenant's configuration and the platform's tenants, scoped API keys
`read`, `write` and `manage`, an audit entry for every management call with the key as the actor, and
Terraform-friendly semantics: stable ids, idempotent `PUT`, `If-Match` ETags.

## Decision drivers

- No existing integration may break: SDKs, the load harness, the chaos suite and every tenant hold a single key.
- Least privilege: a key should carry only what its holder needs, and a key must not be able to mint a broader one.
- One way to do each thing: no resource reachable under two URLs with two operation ids in the OpenAPI document.
- Platform operations (creating tenants) must not be reachable with any tenant credential.
- Every change is audited in the same transaction as the change, as the rest of the code base does.

## Considered options

1. **Replace `tenants.api_key_hash` with an `api_keys` table.** Migrate every tenant's key into it and drop the
   tenant columns.
2. **Add `api_keys` for scoped keys and keep the tenant's key as a primary key with every scope.**
3. **Scopes on the tenant row** (one key, configurable scopes).

For the URL layout:

- **A.** Move or duplicate routing rules, webhook subscriptions and pause/resume under `/api/v1/manage`.
- **B.** Put only the new configuration resources under `/api/v1/manage`, and gate the existing configuration
  routes with the `manage` scope.

### Pros and cons of the options

#### Option 1: replace the tenant key

- Good, because there is one credential model.
- Bad, because the admin panel's create and rotate flows, the rotation grace period (`previous_api_key_hash`), the
  fixtures of hundreds of tests, the load and chaos harnesses and the SDK conformance suite would all change in
  the same PR, for no behaviour gain.

#### Option 2: primary key plus scoped keys

- Good, because existing keys keep working unchanged, as keys with every scope.
- Good, because scoped keys get their own lifecycle (name, expiry, revocation, `last_used_at`) without touching
  the tenant row.
- Bad, because there are two kinds of key to explain.

#### Option 3: scopes on the tenant row

- Bad, because one key per tenant cannot serve a dashboard and a bot with different rights.

#### Option A: everything under `/manage`

- Good, because the namespace matches the issue's sketch.
- Bad, because duplicated routes yield duplicate OpenAPI operations, and moved routes break clients.

#### Option B: new resources under `/manage`, scope on the rest

- Good, because no route moves and every operation keeps one id.
- Bad, because configuration is spread over two prefixes. The docs list both.

## Decision

Chosen: **option 2 with layout B**.

- **`api_keys` table**: `tenant_id`, `name`, `key_hash` (SHA-256, unique), `prefix` (display), `scopes` (subset of
  `read`, `write`, `manage`), `expires_at`, `last_used_at`, `revoked_at`, `created_by`. Keys are `cvg_live_...` like
  the primary key, so secret scanners match both. They are revoked, never deleted, so an audit entry's `actor_id`
  always resolves.
- **The primary key** (`tenants.api_key_hash`) has every scope. The deprecated channel token keeps every scope on
  the routes that accept it.
- **Scope enforcement in `ConvergerWeb.Plugs.TenantAuth`**, so it fails closed. Every action needs a scope:
  `read` for `GET`/`HEAD`, `write` otherwise. A controller can override this per action (`scopes:`) or for all
  actions (`scope:`). A missing scope is `403 insufficient_scope`, with `details.required`. The scopes are
  separate: `manage` does not include `read` or `write`.
- **What `manage` covers**: everything under `/api/v1/manage` (channels with `rotate_secret`, portal users,
  settings, API keys), changes to routing rules and webhook subscriptions, and channel pause/resume (a channel
  change). The routing dry-run only reads, so it needs `read`.
- **No escalation**: a key can only issue keys whose scopes are a subset of its own.
- **`/api/v1/manage` takes API keys only**, not channel tokens (`403 forbidden`).
- **The admin API** (`/api/v1/admin`: tenants CRUD, `rotate_api_key`, API key issuance) authenticates with
  `ADMIN_API_TOKEN` (bearer, at least 32 characters, compared as SHA-256 digests in constant time), behind the
  same IP allowlist as the admin panel. Unset, it answers `401` to everything. It is a separate pipeline, so no
  tenant credential reaches it. Personal access tokens per admin user are left for later.
- **Audit**: management calls go through the context functions that already write the audit entry in the same
  transaction. The actor is `tenant_api` with the credential's id (the scoped key id, the tenant id for the primary
  key, the channel id for a channel token), or `admin_api` with id `admin_api_token`. New vocabulary: actor type
  `admin_api`, resource `api_key`, actions `revoke` and `rotate_secret`.
- **Terraform semantics**: UUIDs are stable. `PUT` and `PATCH` are the same partial update, so a repeated `PUT` is
  a no-op. Responses carry a strong `ETag` derived from the id and `updated_at`. `PUT`, `PATCH` and `DELETE` honour
  `If-Match` and answer `412 precondition_failed` (with `details.current_etag`) when it does not match.
- **Secrets**: a channel's config is returned with secret fields as `[REDACTED]` (the adapter's `secret: true`
  fields and every key `Converger.Secrets` treats as sensitive). A `[REDACTED]` value sent back keeps the stored
  value, so read-modify-write does not wipe credentials. The channel secret, the tenant's primary key and a scoped
  key's key are returned only by the call that creates or rotates them.

## Consequences

### Positive

- Integrators can provision a tenant, its channels, routing rules and webhook subscriptions with only the API.
  The acceptance test does exactly that.
- Least-privilege keys: a `read` key cannot post activities, and a `write` key cannot change configuration.
- No existing integration changes behaviour.

### Negative and trade-offs

- Two kinds of tenant key. The primary key cannot be scoped down. A tenant that wants least privilege everywhere
  issues scoped keys and keeps the primary key in a vault.
- `last_used_at` costs one conditional `UPDATE` per key per minute.
- A single shared `ADMIN_API_TOKEN` cannot attribute admin API calls to a person. The audit log records
  `admin_api`.
- `PUT` is not a full replacement: omitted fields are kept. This is simpler for clients, but a `PUT` cannot reset
  an omitted field to its default.

### Follow-ups

- Portal and admin panel pages to issue and revoke scoped keys (the API exists).
- Personal access tokens for admin users, so admin API calls are attributable.
- Creating a resource with a client-chosen id (`PUT` to a new id) if Terraform providers need it.

## Implementation

- Migration `priv/repo/migrations/20261013175100_create_api_keys.exs`. Schema `Converger.ApiKeys.ApiKey`. Context
  `Converger.ApiKeys` (`authenticate/1`, `create_api_key/3`, `revoke_api_key/2`). `Converger.ApiKeys.Credential`.
- `ConvergerWeb.Plugs.TenantAuth` (scopes, `actor/1`), `ConvergerWeb.Plugs.AdminApiAuth`, `ConvergerWeb.ETag`.
- Controllers `ConvergerWeb.Manage.{ChannelController, TenantUserController, SettingsController, ApiKeyController}`
  and `ConvergerWeb.AdminAPI.{TenantController, ApiKeyController}`. Scope overrides on `RoutingRuleController`,
  `WebhookSubscriptionController` and `ChannelDeliveryController`.
- `Converger.Channels.rotate_secret/2`, `Converger.Tenants.update_tenant_and_limits/3`, and
  `Converger.Accounts.get_tenant_user/2`.
- New error codes `insufficient_scope` (403) and `precondition_failed` (412). `ConvergerWeb.ApiSpec` adds a `403`
  response to every operation behind an API key, plus the `adminToken` security scheme.
- `ADMIN_API_TOKEN` in `config/runtime.exs`.
- Tests: `test/converger_web/controllers/management_api_test.exs` (acceptance script, scopes, escalation, ETags,
  redaction, admin API) and the management and admin sections of `test/converger_web/api_contract_test.exs`.

## Links

- [Management API](../api/management-api.md)
- [API overview: authentication](../api/overview.md#authentication)
- [Security model](../security/overview.md)
- [Configuration](../operations/configuration.md)
