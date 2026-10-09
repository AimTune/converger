---
title: Security model
description: How Converger authenticates admins, tenants, channels and end users, isolates tenants, protects secrets at rest, signs webhooks, limits abuse and hardens the HTTP edge.
sidebar_position: 1
---

This page is the map of Converger's security controls: who can authenticate with what, how tenants are kept
apart, how secrets are stored, and which protections sit at the HTTP edge. Each section links to the page or
ADR with the details. Client IPs, reverse proxies, the admin IP whitelist and leaked-secret rotation are covered
in depth in [Security: client IPs, proxies and admin access](../security.md); this page does not repeat them.

## Actors and credentials

| Actor | Credential | Where it is checked | Stored as |
| --- | --- | --- | --- |
| Operator (admin panel `/admin`) | Email + password, cookie session | `ConvergerWeb.Plugs.AdminAuth` (IP whitelist), `ConvergerWeb.Plugs.Auth` (session), LiveView `on_mount` hooks | `admin_users.password_hash` (bcrypt) |
| Tenant staff (portal `/portal`) | Tenant name + email + password, cookie session | `ConvergerWeb.Plugs.Auth`, LiveView `on_mount` hooks | `tenant_users.password_hash` (bcrypt) |
| Tenant backend (server to server) | `x-api-key: cvg_live_...` | `ConvergerWeb.Plugs.TenantAuth` | `tenants.api_key_hash` (SHA-256) |
| Channel integration | Channel secret as `Authorization: Bearer ...` on `POST /api/v1/converger/tokens/generate` | `ConvergerWeb.Plugs.ConvergerAuth` (`mode: :secret`) | `channels.secret` (AES-GCM encrypted) + `channels.secret_hash` (SHA-256, for lookup) |
| End-user client (widget, SDK) | Converger token (JWT) as Bearer or socket `token` param | `ConvergerWeb.Plugs.ConvergerAuth` (`mode: :token`), `ConvergerWeb.ConvergerSocket` | Not stored (stateless JWT) |
| Legacy client (deprecated, see [migrating](../api/migrating-from-legacy.md)) | Channel token in `x-channel-token`, conversation token on `/socket` | `ConvergerWeb.Plugs.TenantAuth`, `ConvergerWeb.UserSocket` | Not stored (stateless JWT) |
| External provider (WhatsApp, webhook sender) | Request signature over the raw body | `ConvergerWeb.InboundController` + `Converger.Channels.InboundSignature` or the adapter's own scheme | Uses the channel secret / adapter config |

## Authentication

### Admin users

Admin accounts live in `admin_users` with the roles `super_admin`, `admin` and `viewer`
([`Converger.Accounts.AdminUser`](https://github.com/AimTune/converger/blob/main/lib/converger/accounts/admin_user.ex)).
Passwords are hashed with bcrypt (`bcrypt_elixir`, default cost) and must be at least 8 characters.
`Converger.Accounts.authenticate_admin/2` runs `Bcrypt.no_user_verify/0` when the email is unknown, so response
time does not reveal whether an account exists.

Every `/admin` route goes through two layers:

1. `ConvergerWeb.Plugs.AdminAuth` rejects clients whose IP is not in `ADMIN_IP_WHITELIST` (default
   `127.0.0.1,::1`) with `403`. The client IP is only taken from `X-Forwarded-For` when the TCP peer is in
   `TRUSTED_PROXIES` (see [../security.md](../security.md)).
2. The session plugs (`fetch_admin_user`, `require_admin_user`) and the LiveView hook
   `ConvergerWeb.Live.AuthHooks.ensure_admin_user` require an active admin user in the session.

There is no default password. The first `super_admin` is created by `Converger.Release.seed_admin/0` (or
`priv/repo/seeds.exs` in development) from `ADMIN_EMAIL` / `ADMIN_PASSWORD`. When `ADMIN_PASSWORD` is unset a
random password is printed once and the account gets `must_change_password: true`. That flag is set
programmatically (never cast from form input); while it is set, `require_admin_user` redirects every admin page
to `/admin/password`, and changing the password clears it. See
[Initial admin account](../deployment.md#initial-admin-account).

The Oban Web dashboard at `/admin/oban` uses the same pipelines, and `ConvergerWeb.ObanResolver` maps roles to
access: `super_admin` and `admin` get full access, `viewer` is read-only.

### Tenant users

Tenant users (`tenant_users`, roles `owner`, `admin`, `member`, `viewer`) sign in at `/portal/login` with the
tenant name, email and password. The portal is not behind the IP whitelist. Email uniqueness is scoped to the
tenant, and the tenant must be `active`. Authorization inside the portal is role based (viewers are read-only,
owners and admins manage users).

### Sessions

Both panels use Phoenix cookie sessions (`_converger_key`, signed with `SECRET_KEY_BASE`, `SameSite=Lax`).
The cookie is signed, not encrypted: it holds only the user id. Sessions are renewed (`configure_session(renew:
true)`) on login and logout, and the `:browser` pipeline enables CSRF protection (`protect_from_forgery`).
Sessions have no server-side expiry yet; see [Planned hardening](#planned-hardening).

### Tenant API keys

A tenant API key is `cvg_live_` followed by 32 random bytes (URL-safe base64). Only its SHA-256 digest is stored
(`tenants.api_key_hash`) together with a short display prefix (`api_key_prefix`, shown as `cvg_live_abcd****`).
The plaintext is returned once, when the tenant is created or the key is rotated, and can never be shown again.

Rotation (`Converger.Tenants.rotate_api_key/2`) keeps the previous key valid for a grace period (default 24 hours,
`config :converger, :api_key_rotation_grace_period` in seconds) through `previous_api_key_hash` and
`previous_api_key_expires_at`, so clients can be switched without downtime. Lookups hash the presented key and
compare digests in the database; inactive tenants are rejected with `401`.

### Channel secrets

Each channel has a random secret (generated if none is given). It authenticates the channel integration on
`POST /api/v1/converger/tokens/generate`, signs outbound webhooks and verifies inbound signatures. It is stored
encrypted; a SHA-256 digest in `channels.secret_hash` (unique index) is used for the lookup, followed by a
constant-time comparison with the decrypted value (`Converger.Channels.get_channel_by_secret/1`).

### Tokens (JWT)

All tokens are HS256 JWTs created with Joken. They share one signer,
[`Converger.Auth.Signer`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/signer.ex), whose key
is the endpoint's `SECRET_KEY_BASE`.

| Token | Module | Claims | Lifetime | Issued by |
| --- | --- | --- | --- | --- |
| Converger token | `Converger.Auth.ConvergerToken` | `type: "converger"`, `channel_id`, `tenant_id`, `sub`, optional `conversation_id` and `user_id` | 1800 s | `POST /api/v1/converger/tokens/generate` (channel secret), `POST /api/v1/converger/tokens/refresh` (valid token) |
| Conversation token (legacy, deprecated) | `Converger.Auth.Token` | `conversation_id`, `tenant_id`, `sub` | 3600 s | `POST /api/v1/tokens` |
| Channel token (legacy, deprecated) | `Converger.Auth.Token.generate_channel_token/1` | `channel_id`, `tenant_id`, `sub: "channel_<id>"` | 3600 s | Shown on the admin channel page (`/admin/channels`) |

Because the signer is shared, every verifier also checks the token's shape
([ADR-0026](../adr/0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md)):

- `x-channel-token` (`TenantAuth`, `POST /api/v1/tokens`, `POST /api/v1/conversations`) accepts only channel tokens
  (`Converger.Auth.Token.verify_channel_token/1`: `channel_id`, no `conversation_id`, no `type` claim). Conversation
  tokens and Converger tokens are refused with `401`. Before [#23](https://github.com/AimTune/converger/issues/23)
  any Converger-signed JWT was accepted there, so a conversation token sent as `x-channel-token` acted as the whole
  tenant.
- The legacy socket `/socket` accepts only conversation tokens (`verify_conversation_token/1`).
- Converger tokens are rejected by both legacy verifiers.

The legacy tokens and the legacy socket are deprecated; see
[migrating from the legacy surfaces](../api/migrating-from-legacy.md).

Converger tokens are rejected unless `type` is `"converger"`, and every authenticated request re-checks that the
token's channel is still `active` (`403` otherwise). Consequences of the stateless design:

- A token cannot be revoked before it expires. Deactivating a channel blocks its tokens on the next request and
  disconnects its sockets.
- `refresh` mints a new token from any valid one, without rotation or reuse detection.
- Rotating `SECRET_KEY_BASE` invalidates every token and every session at once (see
  [Rotating leaked secrets](../security.md#rotating-leaked-secrets)).

Revocation, refresh rotation, scoped tokens and a dedicated signing key with `kid` are Planned
([#52](https://github.com/AimTune/converger/issues/52)).

### WebSocket authentication

| Socket | Connect parameter | Join rule |
| --- | --- | --- |
| `/socket/converger` (`ConvergerWeb.ConvergerSocket`) | `token`: a Converger token; the channel must be active for the token's tenant | `converger:conversation:<id>`: allowed when the token's `conversation_id` equals `<id>`, or, for a channel-level token, when the conversation belongs to the token's tenant and channel |
| `/socket` (`ConvergerWeb.UserSocket`, legacy, deprecated) | `token`: a conversation token (Converger tokens and channel tokens are refused at connect) | `conversation:<id>`: only the conversation named in the token, and only while its channel is active |

Sockets get a per-subject id (`converger_socket:<tenant_id>:user:<user_id>` or `...:conversation:<id>`), never a
per-channel one, so a forced disconnect affects one end user only
([`ConvergerWeb.Sockets`](https://github.com/AimTune/converger/blob/main/lib/converger_web/sockets.ex),
[ADR-0020](../adr/0020-per-subject-socket-ids-and-presence.md)). Browser connections are also checked against
`CHECK_ORIGIN` (default: the `PHX_HOST` host); clients that send no `Origin` header are not affected. The wire
format is Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21),
[#63](https://github.com/AimTune/converger/issues/63)).

## Authorization and tenant isolation

Converger is multi-tenant in one database, so isolation is enforced in code on every path:

- **The tenant always comes from the credential, never from the request.** `TenantAuth` assigns the tenant from
  the API key or channel token, Converger tokens carry `tenant_id` and `channel_id`, and controllers merge those
  values into the attributes they persist (for example conversation creation overwrites `tenant_id` and
  `channel_id` from the token).
- **Lookups are scoped.** Context functions take the tenant (`Conversations.get_conversation/2`,
  `Channels.get_active_channel/2`); a resource of another tenant is reported as not found. Attachments of another
  tenant, or of another conversation for a conversation-bound token, return `404`
  ([../storage.md](../storage.md)).
- **System fields are not client-settable.** Activities use separate client and system changesets, so a client
  cannot set `tenant_id`, `seq`, delivery state and similar fields
  ([ADR-0005](../adr/0005-separate-client-and-system-changesets.md)).
- **Cross-tenant references are rejected.** Routing rules validate that the source and every target channel
  belong to the same tenant.
- **Listing other users' data requires the API key.** `GET /api/v1/conversations` refuses channel tokens,
  because a channel token is held by end-user clients.
- **Programmatically set fields are never cast** (for example `must_change_password`, `api_key_hash`,
  `secret_hash`).

## Secrets at rest

### Encryption with Cloak

[`Converger.Vault`](https://github.com/AimTune/converger/blob/main/lib/converger/vault.ex) is a Cloak vault
using `Cloak.Ciphers.AES.GCM` (AES-256-GCM, 12-byte IV, authenticated). Each configured key gets a cipher tag
derived from its SHA-256 fingerprint (`AES.GCM.<8 hex chars>`), so ciphertexts are self-describing and any
configured key can decrypt them.

| Data | Protection |
| --- | --- |
| `channels.secret` | Encrypted (`Converger.Encrypted.Binary`) + SHA-256 `secret_hash` for lookup |
| `channels.config` (provider access tokens, `app_secret`, `verify_token`, Infobip `api_key`, webhook headers, ...) | Encrypted as a whole map (`Converger.Encrypted.Map`) |
| `tenants.api_key_hash`, `previous_api_key_hash` | SHA-256 digest only; plaintext never stored |
| `admin_users.password_hash`, `tenant_users.password_hash` | bcrypt |
| Activities, attachments, `tenants.alert_webhook_url`, audit logs | Not encrypted by the application; rely on database and storage encryption |

Sensitive schema fields are also declared with `redact: true`, so `inspect/1` (and therefore crash reports) does
not print them.

### CLOAK_KEY

`CLOAK_KEY` is a base64-encoded 32-byte key, required in production: `config/runtime.exs` refuses to boot
without it, and the vault raises on a key that does not decode to 32 bytes. Generate one with
`openssl rand -base64 32` or `mix run -e 'IO.puts(Converger.Vault.generate_key())'`. Development and test use
fixed, non-secret keys from `config/dev.exs` and `config/test.exs`.

Back the key up separately from the database: a database backup cannot decrypt channel secrets without it
([Backups and restore](../deployment.md#backups-and-restore)).

### Key rotation

1. Generate a new key and set it as `CLOAK_KEY`.
2. Move the old key into `CLOAK_RETIRED_KEYS` (comma-separated; still accepted for decryption).
3. Deploy, then re-encrypt every channel with the new key:

   ```bash
   bin/converger eval "Converger.Release.reencrypt_secrets()"
   ```

4. Remove the retired key once the command reports the re-encrypted channel count.

If the old key may have leaked, also rotate the channel secrets themselves. Details:
[ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md).

## Audit logs and log redaction

Administrative changes to tenants (including API key rotation and rate-limit overrides), channels, routing
rules, admin users and tenant users are written to `audit_logs` (resource types `tenant`, `channel`,
`routing_rule`, `admin_user`, `tenant_user`). When the change is made with an actor (admin panel, portal), the
entry is inserted in the same `Ecto.Multi` transaction as the change, with the actor and a before/after snapshot. [`Converger.AuditLogs.Changes`](https://github.com/AimTune/converger/blob/main/lib/converger/audit_logs/changes.ex)
serializes the structs, drops associations (they are audited as their own resources), and passes the result
through `Converger.Secrets.redact/1`, which replaces values **recursively**, including inside nested maps such as
`channels.config`:

- keys `access_token`, `api_key`, `secret`, `token`, `password`, `password_hash`, `verify_token`, `app_secret`,
  `authorization`, `x-api-key`, `x-channel-token` (case-insensitive), and
- any key ending in `_secret`, `_token` or `_hash`.

Values become `"[REDACTED]"`; `nil` stays `nil`. Audit logs are browsable at `/admin/audit_logs`.

Production logs are JSON (LoggerJSON on the default handler, see [Observability](../operations/observability.md))
with `LoggerJSON.Redactors.RedactKeys` for `api_key`, `secret`, `token`, `password`, `access_token`,
`app_secret`, `verify_token`, `x-api-key`, `x-channel-token` and `authorization` in log metadata.

## Inbound request signatures

Inbound webhooks (`POST /api/v1/channels/:channel_id/inbound` and `/status`) are verified against the raw request
body, which `ConvergerWeb.CacheBodyReader` keeps before JSON parsing:

- Generic scheme: `x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">`, keyed with
  the channel secret. The timestamp must be within 300 seconds of the server clock
  (`config :converger, :inbound_signature_tolerance_seconds`). Several `v1` values are accepted, for secret
  rotation.
- Adapters with a native scheme (WhatsApp Meta `X-Hub-Signature-256` with `app_secret`) verify that instead.
- A signature that is present but invalid is always rejected with `401`.
- `channels.require_signature` (default `true` for new channels) also rejects missing and legacy
  `sha256=<hex>` signatures. Channels that existed before the column was added were backfilled with `false`; they
  still accept unsigned or legacy requests and log a `DEPRECATED` warning for each.

Details and rationale: [ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md).

## Outbound webhooks: signing and SSRF guard

Every outbound webhook request carries `x-converger-signature` in the same format, plus `x-converger-event` and
a stable `x-converger-delivery-id` for deduplication. Webhook URLs pass through `Converger.Channels.UrlGuard`
when the channel is saved and again before every request: private, loopback, link-local, metadata and other
non-public addresses are rejected, every resolved address must pass, and the connection is pinned to the checked
address so DNS rebinding cannot redirect it. Redirects are not followed. Operators can allow internal targets
with `WEBHOOK_ALLOWED_TARGETS` (or disable the guard with `WEBHOOK_ALLOW_PRIVATE_TARGETS=true`, development
only).

Verification code, the test vector and the full blocked-range list are in
[Outbound webhooks](../webhooks.md#verifying-the-signature); the design is in
[ADR-0014](../adr/0014-webhook-ssrf-guard-and-outbound-signing.md).

:::note
The SSRF guard applies to `webhook` channel deliveries. The tenant health-alert URL
(`tenants.alert_webhook_url`, posted by `Converger.Channels.Health`) is only validated as an `http`/`https` URL
and is set by operators, not by end users.
:::

## Rate limiting and login lockout

Hammer 7 counters (node-local ETS, optionally replicated across the cluster over PubSub) protect activity
creation, uploads, inbound webhooks and token endpoints, and failed logins are counted per client IP and per
account (5 failures per minute each by default) with a lockout before the password is checked. Rejected requests
get `429` with `Retry-After`. See [Rate limiting](../operations/rate-limiting.md) and
[ADR-0013](../adr/0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md).

## HTTP edge

| Control | Implementation | Configuration |
| --- | --- | --- |
| Client IP behind proxies | `ConvergerWeb.Plugs.TrustedProxies` (first plug in the endpoint); forwarding headers only from trusted peers | `TRUSTED_PROXIES`, see [../security.md](../security.md) and [ADR-0011](../adr/0011-custom-trusted-proxies-plug.md) |
| Admin network restriction | `ConvergerWeb.Plugs.AdminAuth` | `ADMIN_IP_WHITELIST`, see [../security.md](../security.md) |
| HTTPS redirect + HSTS | `ConvergerWeb.Plugs.ForceSSL` (runtime `Plug.SSL`; `X-Forwarded-Proto` honoured only from trusted proxies), on by default in production | `FORCE_SSL`, `HSTS`, `HSTS_MAX_AGE`, `HSTS_INCLUDE_SUBDOMAINS`, `HSTS_PRELOAD`, `FORCE_SSL_EXCLUDE_PATHS`, see [TLS, HSTS and WebSocket origins](../deployment.md#tls-hsts-and-websocket-origins) |
| WebSocket origin check | Phoenix `check_origin` | `CHECK_ORIGIN` |
| CORS | `CORSPlug`, origins read per request | `CORS_ORIGINS` |

Design notes for the edge and boot checks: [ADR-0022](../adr/0022-deployment-hardening.md).

### Browser headers and uploads

The `:browser` pipeline (admin panel and portal) sets Phoenix's secure browser headers
(`x-content-type-options: nosniff`, `referrer-policy: strict-origin-when-cross-origin`,
`x-permitted-cross-domain-policies: none`) and this Content Security Policy:

```http
content-security-policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'
```

`'unsafe-inline'` and `cdn.jsdelivr.net` are needed because the layouts load Phoenix and LiveView from jsDelivr
with an inline bootstrap script (there is no asset pipeline).

Uploaded files are typed by magic bytes (the declared type is ignored), checked against an allowlist, and served
only through the authenticated, tenant-scoped download endpoint with `nosniff`, a sandboxing CSP and a
`Content-Disposition` header; SVG and HTML are served as `text/plain`. See
[File storage and attachments](../storage.md).

## Fail-fast configuration checks

The release refuses to boot (`config/runtime.exs`, `Converger.Vault`, `Converger.Pipeline.Broadway`) rather
than run insecurely when:

- `DATABASE_URL`, `SECRET_KEY_BASE` or `CLOAK_KEY` is missing;
- `SECRET_KEY_BASE` is shorter than 64 bytes;
- `SECRET_KEY_BASE` or `CLOAK_KEY` matches the SHA-256 fingerprint of a value that was once published in this
  repository (see [Rotating leaked secrets](../security.md#rotating-leaked-secrets));
- a Cloak key does not decode to 32 bytes;
- `CHECK_ORIGIN` is set but contains no origins;
- `RATE_LIMIT_BACKEND`, `UPLOAD_STORAGE` or `CDN_TYPE` has an unknown value;
- the non-durable Broadway `:memory` producer is configured in production without
  `allow_memory_producer_in_prod: true`.

`docker-compose.yml` uses `${VAR:?message}` for every secret, so `docker compose up` stops instead of starting
with a weak default. No secret is committed; `.env` is gitignored.

## Static analysis and supply chain

CI ([`.github/workflows/ci.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/ci.yml)) runs
on every pull request:

- **Sobelow** (`mix sobelow --config`, `.sobelow-conf`, threshold `low`). `Config.HTTPS` is ignored because TLS
  terminates at the proxy, and `Config.CSWH` because `check_origin` comes from `CHECK_ORIGIN` at runtime (a test
  fails if any config other than `dev.exs` disables it). Individually accepted findings carry an inline
  `# sobelow_skip [...]` with a justification.
- **`mix deps.audit`** (known vulnerabilities) and **`mix hex.audit`** (retired packages). Advisories that do
  not affect Converger are acknowledged in `mix.exs` under `hex: [ignore_advisories: ...]`, each with the reason
  (currently two `cowlib` CVEs reachable only from the Prometheus listener, and two `cloak` / `cloak_ecto` CVEs in
  ciphers and types Converger does not use, enforced by `test/converger/vault_test.exs`).
- **Credo** (`--strict`), **Dialyzer**, and compile with warnings as errors.

The Docker workflow builds the image on every pull request and scans it with Trivy (report-only for now, SARIF
uploaded to code scanning). Dependabot opens dependency updates. See
[ADR-0021](../adr/0021-ci-quality-gates-and-lf-line-endings.md).

## Planned hardening

Tracked in [#52](https://github.com/AimTune/converger/issues/52) (Planned):

- token revocation (`jti` denylist), refresh-token rotation with reuse detection, scoped tokens;
- a dedicated JWT signing key with `kid` and rollover, independent of `SECRET_KEY_BASE`;
- TOTP two-factor authentication for admins (required for `super_admin`), password reset, password policy;
- session `max_age`, idle timeout and "log out everywhere".

Other known limitations: the login form reports "Your account has been deactivated" for an inactive account
before the password is checked, and unauthenticated health endpoints for load balancers are Planned
([#29](https://github.com/AimTune/converger/issues/29)).

## Reporting a vulnerability

Do not open a public issue for security problems. Open a private security advisory on GitHub
(**Security** tab, **Report a vulnerability**) at
[github.com/AimTune/converger/security/advisories/new](https://github.com/AimTune/converger/security/advisories/new),
with the affected version or commit, reproduction steps and impact. There is no `SECURITY.md` yet.

## Related ADRs

- [ADR-0009: Inbound signature scheme and per-channel enforcement](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md)
- [ADR-0011: Custom trusted proxies plug](../adr/0011-custom-trusted-proxies-plug.md)
- [ADR-0012: Secrets at rest and audit redaction](../adr/0012-secrets-at-rest-and-audit-redaction.md)
- [ADR-0013: Cluster-wide rate limiting with Hammer and PubSub](../adr/0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)
- [ADR-0014: Webhook SSRF guard and outbound signing](../adr/0014-webhook-ssrf-guard-and-outbound-signing.md)
- [ADR-0022: Deployment hardening](../adr/0022-deployment-hardening.md)

## Authorization boundaries

These rules were tightened after a review of the token and URL handling (see the
[CHANGELOG](https://github.com/AimTune/converger/blob/main/CHANGELOG.md)):

- **Tenant API credentials.** Only the tenant API key and channel tokens unlock the tenant API.
  All JWTs share one signing key, so `TenantAuth` checks what a token *is*: conversation tokens and
  Converger client tokens carry a `tenant_id` too, but they belong to end users and are rejected.
  See [API authentication](../api/overview.md).
- **Channel binding.** A Converger client token is bound to its channel: conversations, activities,
  uploads and attachments of other channels are `404`, even in the same tenant. Joining a conversation
  over the WebSocket needs a conversation-bound token.
- **Tenant ownership is immutable.** A routing rule's `tenant_id` is set on create from the
  authenticated tenant and cannot be changed by an update.
- **Delivery receipts are scoped.** A status webhook updates only deliveries of the channel it was
  sent to, whether it identifies them by `provider_message_id` or by `delivery_id`.
- **SSRF guard everywhere the server makes requests to configured URLs.** Webhook targets, the tenant
  `alert_webhook_url` and the WhatsApp Infobip `base_url` are checked when saved and again before each
  request (DNS can change, and older configurations were saved before the guard existed). Private,
  loopback, link-local and metadata targets are refused unless explicitly allowed
  (`WEBHOOK_ALLOWED_TARGETS`, see [webhooks](../webhooks.md)).
