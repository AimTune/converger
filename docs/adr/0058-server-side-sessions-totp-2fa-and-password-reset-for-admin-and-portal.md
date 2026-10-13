---
title: "ADR-0058: Server-side sessions, TOTP 2FA and password reset for the admin panel and the portal"
sidebar_label: "0058 Admin/portal sessions, 2FA, reset"
description: Admin and portal logins become hashed server-side session rows with absolute and idle expiry, TOTP 2FA with nimble_totp (required for super_admin), hashed single-use email reset tokens and one shared password policy.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#52](https://github.com/AimTune/converger/issues/52) (part 2: admin panel and tenant portal) |
| **Pull request** | [#160](https://github.com/AimTune/converger/pull/160) |
| **Related** | [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0022](0022-deployment-hardening.md), [ADR-0057](https://github.com/AimTune/converger/issues/52) (part 1: client tokens) |

## Context and problem statement

The admin panel (`/admin`) and the tenant portal (`/portal`) authenticated with an email and a password and kept
the user id in the signed Phoenix cookie session. That had several gaps, collected in
[#52](https://github.com/AimTune/converger/issues/52):

- **Sessions never ended.** The cookie had no `max_age` and the server had no record of it: a stolen cookie
  worked until `SECRET_KEY_BASE` was rotated, and "log out" only cleared one browser's cookie. Nobody could see
  or revoke the sessions of an account, and a password change or deactivation left other browsers logged in
  (deactivation was only noticed because the plugs reload the user).
- **One factor.** A phished or reused password was enough, also for `super_admin`, which can create admins and
  read every tenant's data. The IP whitelist protects `/admin` only, not the portal.
- **No recovery.** A forgotten password needed an operator with database access.
- **Weak policy.** The only rule was eight characters; bcrypt silently ignores everything after 72 bytes.

Part 1 of #52 (token revocation, refresh rotation and scoped client tokens,
[ADR-0057](https://github.com/AimTune/converger/issues/52)) covers the JWT side and is a separate pull request.

## Decision drivers

- Revocation must be immediate and complete: logout everywhere, password change, deactivation, reset.
- No new infrastructure (no Redis), works the same on one node and in a cluster.
- Secrets at rest (TOTP secrets, tokens) follow [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md): encrypted
  when they must be read back, hashed when they only need to be compared.
- Nothing may reveal whether an account exists (reset form, timing kept close to the login form's).
- Small, well-understood dependencies; standard authenticator apps must work.
- Existing users and tests must keep working (no forced password changes).

## Considered options

### Sessions

1. **Keep cookie sessions, add `max_age` and a per-user "sessions valid after" timestamp** - expiry and a crude
   "log out everywhere" without a table.
2. **Server-side session table, cookie holds a random token (hash stored)** - like `phx.gen.auth`.
3. **Store sessions in ETS / Redis** - fast lookups, but per-node state or a new dependency.

### Second factor

1. **TOTP with `nimble_totp`** - RFC 6238, any authenticator app, ~200 lines, no dependencies.
2. **TOTP with `pot`** - Erlang library, HOTP and TOTP, more surface.
3. **WebAuthn / passkeys** - phishing resistant, but a JavaScript ceremony, an asset pipeline we do not have and
   a much larger library (`wax`).

### Password reset tokens

1. **Random token, SHA-256 stored in a table, single use** - revocable, auditable, invalidated by any password
   change.
2. **Signed stateless token (`Phoenix.Token`) with the password hash in the payload** - no table, but cannot be
   revoked individually and leaks timing of the hash comparison into the token format.

### Pros and cons of the options

#### Sessions: cookie + "valid after" timestamp

- Good, because no table and no query per request.
- Bad, because single sessions cannot be listed or revoked, the idle timeout needs a cookie write on every
  request, and open LiveViews are not disconnected.

#### Sessions: server-side table (chosen)

- Good, because every session can be listed (IP, browser, last activity) and revoked one by one or all at
  once; absolute and idle expiry are enforced on the server; the cookie holds no user id.
- Good, because a session row gives LiveViews a socket id to disconnect (`live_socket_id`).
- Bad, because every request and LiveView mount reads one indexed row, and `last_seen_at` is written (at most
  once a minute per session).

#### Sessions: ETS / Redis

- Good, because no database read per request.
- Bad, because ETS is per node (a cluster would need replication) and Redis is new infrastructure.

#### TOTP with `nimble_totp` (chosen)

- Good, because it is tiny, maintained by Dashbit, has no dependencies and supports reuse prevention (`since`)
  and arbitrary times (clock-skew window).
- Bad, because TOTP codes can be phished in real time (no origin binding).

#### TOTP with `pot`

- Good, because it also does HOTP and multiple windows.
- Bad, because more API surface than needed and an Erlang interface.

#### WebAuthn

- Good, because it is phishing resistant.
- Bad, because the admin and portal pages have no asset pipeline and the ceremony needs JavaScript and a larger
  dependency; it can be added later next to TOTP.

#### Reset tokens in a table (chosen)

- Good, because tokens are single use, expire after one hour, are deleted on any password change and are void
  when the account's email changes (`sent_to`), and only a hash is stored.
- Bad, because one more table and a prune job.

#### Stateless signed reset tokens

- Good, because no table.
- Bad, because a token can only be invalidated indirectly (by changing what it signs) and cannot be single use
  without state.

## Decision

- **Server-side sessions** (`user_sessions`): a login inserts a row with a random 32-byte token's SHA-256, the
  client IP and user agent; the cookie session keeps only the token (`admin_session_token` /
  `tenant_session_token`) and `live_socket_id` (`user_sessions:<id>`). `ConvergerWeb.Plugs.Auth` and
  `ConvergerWeb.Live.AuthHooks` validate the row on every request and mount: present, younger than the absolute
  lifetime (`SESSION_MAX_AGE_SECONDS`, 12 h, also the cookie `max_age`), used within the idle timeout
  (`SESSION_IDLE_TIMEOUT_SECONDS`, 30 min; `last_seen_at` bumped at most once a minute), active user. Deleting
  rows broadcasts `disconnect` to their LiveViews. Rows are deleted on logout, "log out everywhere", per-session
  sign out, password change (all but the current), reset, deactivation and deletion, and by a `super_admin` for
  another admin. `SessionPruneWorker` (Oban cron, every 10 minutes) deletes expired rows and disconnects their
  LiveViews, which also ends idle LiveViews that make no HTTP requests.
- **TOTP 2FA with `nimble_totp`** for admin and tenant users: a 20-byte secret, encrypted with `Converger.Vault`
  (`Converger.Encrypted.Binary`), shown as base32 and `otpauth://` URI, enabled only after a valid code. Codes of
  the current and previous 30 s step are accepted; the accepted step is stored in `totp_last_step` with a
  conditional `UPDATE ... WHERE totp_last_step < step`, so a code works once even under concurrent requests. With
  2FA on, the password step stores only a pending login (user id and time, five minutes) in the cookie session;
  the session row is created after the code. Wrong codes are counted by `LoginThrottle` per IP and per
  `<type>-2fa:<user id>` account. Turning 2FA off needs a code or the password; a `super_admin` (admins), a
  tenant `owner`/`admin` (their tenant's users) or `Converger.Release.reset_admin_2fa/1` can reset it; all
  audit-logged.
- **Required 2FA by role**: `ADMIN_REQUIRE_2FA_ROLES` (default `super_admin`) lists admin roles that are
  redirected to `/admin/security` until they enroll, like `must_change_password`. It is a configuration list
  rather than a per-user flag so operators can extend it to `admin` without a migration; `config/test.exs` sets
  it to `[]` and tests that cover the enforcement set it explicitly.
- **Password reset by email**: random 32-byte URL-safe token in the link, SHA-256 in `account_tokens`
  (`user_type`, `user_id`, `context`, `sent_to`), valid one hour, single use, deleted on any password change. The
  request form always answers the same; requests are limited per IP (`password_reset_ip`, 429) and per account
  (`password_reset_account`, silently no mail). A reset clears `must_change_password`, deletes all sessions and
  is audit-logged. Mail goes through `Converger.Mailer` from `MAILER_FROM`; `SMTP_*` configures an SMTP relay.
- **One password policy** (`Converger.Accounts.PasswordPolicy`) for both account types whenever a password is
  set: at least `PASSWORD_MIN_LENGTH` (12) characters, at most 72 bytes, not containing the email. Existing
  hashes are not re-checked.

## Consequences

### Positive

- Sessions can be seen and revoked, and they end on their own; a stolen cookie is worth at most 12 hours, or 30
  minutes when unused.
- `super_admin` accounts need a second factor by default.
- Users recover from a forgotten password without an operator; operators recover a lost authenticator with one
  release command.
- Security events (2FA changes, resets, password changes, session revocation) appear in the audit log.

### Negative and trade-offs

- One indexed read per admin/portal request and LiveView mount, plus at most one write per session per minute.
- The upgrade logs everyone out once (old cookies carry a user id), and existing `super_admin` accounts must
  enroll at their next request.
- TOTP is phishable in real time; WebAuthn would not be.
- An idle LiveView that makes no requests stays connected until the next prune run (up to 10 minutes after the
  idle timeout).
- The reset request does a little more work when the account exists (token insert and mail send), a timing
  difference smaller than the network jitter but not zero.
- Production needs an SMTP relay (`SMTP_HOST`) for reset emails; without it the links are never delivered.
- No recovery codes: a user who loses the authenticator needs another admin, a tenant owner or the release
  command.

### Follow-ups

- Recovery codes and WebAuthn as a second second-factor.
- An admin view of every user's sessions (today: own sessions on `/admin/security`, and "Sign out" per admin).

## Implementation

- Migration `20261013160000_create_user_sessions_account_tokens_and_totp.exs`: `user_sessions`,
  `account_tokens`, `totp_secret` / `totp_enabled_at` / `totp_last_step` on `admin_users` and `tenant_users`.
- `Converger.Accounts.Sessions`, `Converger.Accounts.TOTP`, `Converger.Accounts.PasswordReset`,
  `Converger.Accounts.PasswordPolicy`, `Converger.Accounts.UserNotifier`, `Converger.Workers.SessionPruneWorker`,
  `Converger.Release.reset_admin_2fa/1`; `Converger.Accounts.change_own_password/4` and `revoke_sessions/2`.
- Web: `ConvergerWeb.UserAuth` (login, logout, pending 2FA), `ConvergerWeb.Plugs.Auth`,
  `ConvergerWeb.Live.AuthHooks`, `ConvergerWeb.TwoFactorLoginController` (`/admin/login/totp`,
  `/portal/login/totp`), `ConvergerWeb.SecurityController` (`/admin/security`, `/portal/security`),
  `ConvergerWeb.PasswordResetController` (`/admin/password/reset`, `/portal/password/reset`); the session plug in
  `ConvergerWeb.Endpoint` reads `max_age` at runtime. Admin users and portal users LiveViews reset 2FA.
- Config: `:sessions`, `:password_min_length`, `:require_2fa_roles`, `:mailer_from` (`config/config.exs`), env
  variables in `config/runtime.exs`; rate limit buckets `password_reset_ip`, `password_reset_account`.
- Tests: `test/converger/accounts/{sessions,totp,password_reset,password_policy}_test.exs`,
  `test/converger_web/controllers/account_security_test.exs` (expiry, log out everywhere with the LiveView
  disconnect broadcast, 2FA login, reuse, throttle, required 2FA for `super_admin`, resets),
  `test/converger_web/controllers/password_reset_controller_test.exs`. `ConnCase.log_in_admin/2` and
  `log_in_tenant_user/2` create real session rows.

## Links

- [Security model](../security/overview.md#sessions)
- [Configuration: accounts, sessions and email](../operations/configuration.md#accounts-sessions-and-email)
- [Rate limiting](../operations/rate-limiting.md)
- [Upgrades](../operations/upgrades.md)
- [`nimble_totp`](https://hexdocs.pm/nimble_totp), [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238)
