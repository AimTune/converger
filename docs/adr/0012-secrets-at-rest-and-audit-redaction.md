---
title: "ADR-0012: Encrypted channel secrets, hashed tenant API keys and recursive audit redaction"
sidebar_label: "0012 Secrets at rest"
description: Channel secrets and configs are encrypted with a Cloak AES-256-GCM vault, tenant API keys are stored only as SHA-256 hashes, and audit logs redact sensitive keys at any depth.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#12](https://github.com/AimTune/converger/issues/12) |
| **Pull request** | [#79](https://github.com/AimTune/converger/pull/79) |
| **Related** | [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0022](0022-deployment-hardening.md) |

Converger holds three kinds of credentials: tenant API keys (server-to-server auth on the tenant API), channel secrets (inbound signature keys and channel token issuance) and provider credentials inside `channels.config` (Meta `access_token`, `app_secret` and `verify_token`, Infobip `api_key`, webhook `headers.Authorization`). This ADR records how each is stored, how it is looked up without being a plaintext query key, and how it is kept out of audit logs and the admin UI.

## Context and problem statement

Before [#79](https://github.com/AimTune/converger/pull/79):

- **Audit logs leaked provider tokens.** `Converger.AuditLogs.Changes.serialize/1` dropped only the top-level fields `api_key`, `secret`, `password_hash` and `password`. `channels.config` is a nested map, so every channel create or update wrote `access_token`, `verify_token` and Infobip `api_key` into `audit_logs.changes` in clear text, readable by any admin viewer and kept indefinitely.
- **Plaintext at rest.** `tenants.api_key`, `channels.secret` and `channels.config` were plain columns. A database dump, a backup copy or read-only SQL access exposed every provider credential and every tenant API key.
- **Full keys in the UI.** The admin tenant list displayed every tenant's API key in full.
- **Secrets as lookup keys.** Channels were found with `Repo.get_by(secret: ...)`, so the full secret was the indexed lookup value and the comparison was not constant time.
- **A verify-token bypass.** The WhatsApp Meta `hub.verify_token` check compared `nil == nil` as a match when no `verify_token` was configured.

## Decision drivers

- A database dump alone must not reveal usable credentials.
- Values that Converger must use again (channel secrets for HMAC, provider tokens for outbound calls) need reversible encryption; values it only has to verify (tenant API keys) do not.
- Lookup by secret must keep working without storing or querying the plaintext.
- Key rotation for both the encryption key and the tenant API keys, without downtime.
- Migrations must run under `Converger.Release.migrate/0`, where only the application is loaded, not started.
- Audit logs must stay useful (which fields changed) without containing secrets, whatever the nesting depth.

## Considered options

1. **Application-level encryption with `cloak_ecto` for reversible secrets, SHA-256 hashes for API keys, recursive key-based redaction** - the proposal in the issue.
2. **Database-level encryption** (`pgcrypto` functions or transparent disk/tablespace encryption).
3. **External secret manager** (HashiCorp Vault, AWS KMS or Secrets Manager) holding the credentials, with only references in the database.
4. **Hash everything, including channel secrets.**

### Pros and cons of the options

**Option 1: Cloak + hashes + redaction**

- Good: ciphertext in every row, dump and backup; the key lives only in the release environment (`CLOAK_KEY`).
- Good: AES-256-GCM is authenticated, so tampered ciphertext fails to decrypt instead of yielding garbage.
- Good: Ecto types make encryption transparent to the rest of the code (`Converger.Encrypted.Binary`, `Converger.Encrypted.Map`).
- Good: built-in support for retired keys during rotation.
- Good: no new infrastructure.
- Bad: losing `CLOAK_KEY` loses every channel secret and config.
- Bad: encrypted columns cannot be queried or indexed by value, so a separate hash column is needed for lookups.

**Option 2: database-level encryption**

- Good: no application changes for disk-level encryption.
- Bad: transparent disk encryption does not protect against SQL access or logical dumps, which were the threat.
- Bad: `pgcrypto` puts the key in SQL statements, where it can end up in logs and `pg_stat_statements`.

**Option 3: external secret manager**

- Good: central audit and rotation, hardware-backed keys.
- Bad: a hard dependency on infrastructure many self-hosted deployments do not have.
- Bad: a network round trip on paths such as inbound verification unless cached, and the cache brings back the problem.
- Can be added later behind the vault (Cloak supports custom ciphers) without changing the schema.

**Option 4: hash everything**

- Good: nothing reversible is stored.
- Bad: impossible for channel secrets (needed as HMAC keys for inbound verification and outbound signing) and provider tokens (sent to Meta and Infobip).

## Decision

Chosen option: **"Cloak AES-GCM vault for reversible secrets, SHA-256 hashes for tenant API keys, recursive audit redaction"**, because it removes plaintext credentials from the database with no new infrastructure, keeps every existing integration working, and matches each secret type to the weakest storage that still lets Converger use it.

**Channel secrets and configs (reversible).**

- `Converger.Vault` is a Cloak vault using `Cloak.Ciphers.AES.GCM` with a 12-byte IV. The key comes from `CLOAK_KEY` (base64, 32 bytes); `CLOAK_RETIRED_KEYS` (comma-separated) lists keys still accepted for decryption.
- Each key's cipher tag is derived from its SHA-256 fingerprint (`AES.GCM.<8 hex chars>`), so a ciphertext names its own key and rotation needs no tag bookkeeping.
- `channels.secret` is `Converger.Encrypted.Binary` and `channels.config` is `Converger.Encrypted.Map`; both are `bytea` and marked `redact: true`, so they never appear in `inspect/1` output or logs.
- `channels.secret_hash` (SHA-256, unique index) serves lookups. `Channels.get_channel_by_secret/1` finds the row by hash and then compares the decrypted secret with `Plug.Crypto.secure_compare/2`. `validate_channel_secret/2` and the Meta `hub.verify_token` check also compare in constant time, and a missing `verify_token` now fails.
- `Converger.Vault.encrypt_offline!/1` encrypts from app config without the vault process, so the data migration works under `Release.migrate/0`.
- After a key rotation, `Converger.Release.reencrypt_secrets/0` (which calls `Channels.reencrypt_all/0`) rewrites every row with the current key.

**Tenant API keys (one-way).**

- New keys are `cvg_live_` followed by 43 URL-safe characters (32 random bytes). Only `api_key_hash` (SHA-256) and `api_key_prefix` (`cvg_live_` plus 4 characters, for display) are stored; `Tenant.api_key` is a virtual field set only on the struct returned by create or rotate.
- `Tenants.rotate_api_key/2` moves the current hash to `previous_api_key_hash` with `previous_api_key_expires_at` (default grace period 24 hours, `config :converger, :api_key_rotation_grace_period`, or the `grace_period:` option) and audits the action as `rotate_api_key`.
- `Tenants.get_tenant_by_api_key/1` accepts the current key, or the previous key until it expires.

**Redaction.**

- `Converger.Secrets.redact/1` walks maps and lists recursively and replaces the values of sensitive keys with `"[REDACTED]"` (`nil` stays `nil`). Sensitive keys, compared case-insensitively: `access_token`, `api_key`, `secret`, `token`, `password`, `password_hash`, `verify_token`, `app_secret`, `authorization`, `x-api-key`, `x-channel-token`, and anything ending in `_secret`, `_token` or `_hash`.
- `Changes.serialize/1` applies it and no longer serializes preloaded associations, which could carry their own secrets and are not JSON-encodable. Redacted top-level keys are present with the placeholder, so the audit trail still shows that a secret changed.
- The admin UI shows tenant keys as `cvg_live_abcd****` and config secrets as `****last4` (`Secrets.mask/1`). Full values appear once, in a "copy it now" card, after creation or rotation.

Hashing API keys with plain SHA-256 rather than a password hash (bcrypt, Argon2) is deliberate: the keys carry 256 bits of randomness, so brute force is not a concern, and the lookup runs on every API request.

## Consequences

### Positive

- Database dumps, backups and read replicas contain only ciphertext and hashes for credentials.
- The audit log for a WhatsApp channel update contains no token values.
- API key rotation has no downtime: the old key keeps working during the grace period.
- Lookups by secret no longer use the plaintext as an index key, and every secret comparison is constant time.
- The same `sensitive_key?/1` rules drive audit redaction and UI masking, so they cannot drift apart.

### Negative and trade-offs

- **`CLOAK_KEY` is required in production and must be set before running migrations**, because the data migration encrypts with it. Losing the key loses every channel secret and config; it has to be backed up with the database.
- **Irreversible migration**: `20261008100001_hash_tenant_api_keys` drops the plaintext column. Plaintext keys cannot be restored, and its `down` raises `Ecto.MigrationError`, so a rollback cannot pass it.
- Full API keys can no longer be shown after creation. To hand a key to someone, an admin rotates it.
- `Tenant.api_key` is `nil` on loaded tenants; scripts that read it from the database break.
- Two channels sharing one secret make the unique `secret_hash` index creation fail during migration (such channels could not authenticate by secret before either).
- Audit rows written before the upgrade may still contain plaintext secrets and have to be scrubbed manually.
- Encrypted columns cannot be filtered in SQL (for example "all channels with this phone number id"); such queries have to load and decrypt.
- Two later advisories against `cloak` / `cloak_ecto` (AES-CTR being unauthenticated, PBKDF2 ignoring its iteration count) have no fixed release. They are explicitly ignored in the `mix.exs` audit config, because only `AES.GCM` and the `Binary`/`Map` types are used; `test/converger/vault_test.exs` enforces that.

### Follow-ups

- [#51](https://github.com/AimTune/converger/issues/51): management API with scoped API keys (an `api_keys` table replacing the single tenant key) and channel secret rotation over REST.
- [#50](https://github.com/AimTune/converger/issues/50): admin and portal modernization, including key rotation UX.
- [#52](https://github.com/AimTune/converger/issues/52): auth hardening (token signing keys with `kid` and rotation).
- Leaked-secret detection at boot and the rotation runbook are covered by [ADR-0022](0022-deployment-hardening.md).

## Implementation

- Vault: [`lib/converger/vault.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/vault.ex) (`generate_key/0`, `encrypt_offline!/1`, `decrypt_offline!/1`).
- Ecto types: [`lib/converger/encrypted/binary.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/encrypted/binary.ex), [`lib/converger/encrypted/map.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/encrypted/map.ex).
- Channel schema and lookups: [`lib/converger/channels/channel.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/channel.ex), [`lib/converger/channels.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels.ex) (`get_channel_by_secret/1`, `validate_channel_secret/2`, `reencrypt_all/0`).
- Tenant keys: [`lib/converger/tenants/tenant.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/tenants/tenant.ex), [`lib/converger/tenants.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/tenants.ex) (`get_tenant_by_api_key/1`, `rotate_api_key/2`).
- Redaction and masking: [`lib/converger/secrets.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/secrets.ex), [`lib/converger/audit_logs/changes.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/audit_logs/changes.ex).
- Release task: [`lib/converger/release.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/release.ex) (`reencrypt_secrets/0`).
- Migrations: [`20261008100000_encrypt_channel_secrets.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008100000_encrypt_channel_secrets.exs) (encrypts every row in Elixir, swaps columns, unique index on `secret_hash`; `down` decrypts back) and [`20261008100001_hash_tenant_api_keys.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008100001_hash_tenant_api_keys.exs) (PostgreSQL 11+ `sha256()`, keeps the first 4 characters as prefix, drops `api_key`).
- Config: `CLOAK_KEY` and `CLOAK_RETIRED_KEYS` in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs); fixed dev and test keys in `config/dev.exs` and `config/test.exs`.

Key rotation runbook:

```bash
# 1. generate a new key
mix run -e 'IO.puts(Converger.Vault.generate_key())'
# 2. deploy with CLOAK_KEY=<new key> and CLOAK_RETIRED_KEYS=<old key>
# 3. re-encrypt every channel with the new key
bin/converger eval "Converger.Release.reencrypt_secrets()"
# 4. remove CLOAK_RETIRED_KEYS and deploy again
```

Tests: [`test/converger/secrets_at_rest_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/secrets_at_rest_test.exs) reads raw rows with `Repo.query!` and asserts they hold no plaintext and are not JSON, and covers transparent decryption, `inspect` redaction, hash lookup, rotation with a retired key, `reencrypt_all/0`, API key format, rotation and grace-period expiry, and the redaction and masking helpers. [`test/converger/audit_logs_integration_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/audit_logs_integration_test.exs) includes "WhatsApp channel update audit log contains no token values". [`test/converger/vault_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/vault_test.exs) pins the cipher choice.

## Links

- Issue [#12](https://github.com/AimTune/converger/issues/12), pull request [#79](https://github.com/AimTune/converger/pull/79)
- [Security overview](../security.md)
- [Deployment and environment variables](../deployment.md)
