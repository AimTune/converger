---
title: Client tokens
description: How Converger client tokens are signed with rotatable keys, restricted with permissions, rotated on refresh with reuse detection, and revoked across the cluster within a second.
sidebar_position: 2
---

Converger tokens are the credential of end-user clients (widgets, apps, agent consoles) on the
[client API](../api/client-api.md), the WebSocket, the native Protocol v1 endpoint, Server-Sent Events and gRPC.
They are short-lived HS256 JWTs (1800 s). Since [#52](https://github.com/AimTune/converger/issues/52) they are
signed with dedicated keys, carry permissions, rotate on refresh and can be revoked
([ADR-0057](../adr/0057-client-token-keys-revocation-rotation-and-permissions.md)).

## Claims

| Claim | Meaning |
| --- | --- |
| `type` | Always `"converger"`; other token kinds are refused. |
| `channel_id`, `tenant_id`, `sub` | The channel (and its tenant) the token was issued for. |
| `exp`, `iat` | Expiry and issue time (unix seconds). |
| `jti` | Unique id of this token. |
| `fam` | Family id: the `jti` of the token generated from the channel secret. Every token derived from it (`POST /conversations`, `GET /conversations/:id`) or refreshed from it keeps it. Revocation works per family. |
| `conversation_id` | Optional. Restricts the token to one conversation. |
| `user_id` | Optional. The end user (`user.id` on generate), used for per-user socket ids and per-user revocation. |
| `scope` | Optional, only `"channel"`: may follow every conversation of the channel (agent console). |
| `perms` | Optional. Permissions, a subset of `read`, `write`, `typing`. Without it the token may do everything. |

The JWT header carries the `kid` of the signing key.

## Signing keys and rotation

Tokens are signed with the keys in `TOKEN_SIGNING_KEYS`: comma-separated `kid:secret` pairs, signing key first.
Every listed key verifies; a token whose `kid` is not listed is refused (`401 unauthorized`). Secrets must be at
least 32 bytes, for example `openssl rand -base64 48`.

```bash
TOKEN_SIGNING_KEYS="2026-10:$(openssl rand -base64 48)"
```

To rotate (for example yearly, or after a leak):

1. Put the new key first and keep the old one: `TOKEN_SIGNING_KEYS="2027-01:<new>,2026-10:<old>"`. Deploy. New
   tokens are signed with `2027-01`; tokens of `2026-10` still verify.
2. After one token lifetime (30 minutes), remove the old key. Deploy.

After a leak, skip the wait: remove the leaked key at once. Clients holding its tokens get `401` and fetch a new
token from your backend.

Because the keys are separate from `SECRET_KEY_BASE`, rotating `SECRET_KEY_BASE` (which logs out every admin and
portal session) no longer logs out WebSocket clients. When `TOKEN_SIGNING_KEYS` is unset, tokens are signed with
`SECRET_KEY_BASE` under the kid `default`, as before #52. Tokens issued before #52 have no `kid` and are verified
with `SECRET_KEY_BASE` while `TOKEN_ACCEPT_UNKEYED` is true (the default); set it to `false` once they have
expired, 30 minutes after the upgrade.

The legacy tokens (`x-channel-token`, the `/socket` conversation token) are unchanged: they are still signed with
`SECRET_KEY_BASE` and are deprecated ([migrating](../api/migrating-from-legacy.md)).

## Permissions

`POST /api/v1/converger/tokens/generate` takes `"permissions": ["read"]` (any non-empty subset of `read`, `write`,
`typing`). Derived and refreshed tokens keep the restriction and cannot widen it; on the native endpoint a mid-session
`auth` refresh must carry the same permissions.

| Permission | REST | WebSocket |
| --- | --- | --- |
| `read` | Show a conversation, list activities, SSE stream, download attachments | Join a conversation (and with it acks, read receipts, `sync`) |
| `write` | Start, close and reopen conversations, post activities, upload | `postActivity`, `text` frames, starting a conversation on `hello` |
| `typing` | - | Typing indicators |

Missing permission: `403 insufficient_permission` (REST, `details.required`), `insufficient_permission` error frame
(WebSocket; on `hello` the socket is then closed with 4403). Requests authenticated with the channel secret are not
restricted.

## Refresh rotation and reuse detection

`POST /tokens/refresh` (and the in-session refresh it enables) returns a new token of the same family and marks the
presented one **rotated**:

- For `TOKEN_ROTATION_GRACE_SECONDS` (default 30) the rotated token keeps working, so requests in flight with it, or
  a second tab refreshing the same token, still succeed.
- After the grace period it is refused with `401 token_revoked`.
- Refreshing it again after the grace period is **reuse**: someone else holds a copy of the token. The whole family
  is revoked, the legitimate holder's new token included, and its sockets are disconnected. Both parties need a new
  token from the backend, which can re-authenticate the user.

The rotation is atomic across nodes (a primary key insert), so of two concurrent refreshes exactly one rotates.

A token derived on `POST /conversations` or `GET /conversations/:id` never outlives the token that asked for it.
Before #52 every `GET /conversations/:id` minted a fresh 30-minute token, an unrotated way to keep a leaked token
alive indefinitely.

## Revocation

`POST /api/v1/converger/tokens/revoke`:

- **with a Converger token** (no body): revokes that token's family. Clients call it on logout.
- **with the channel secret** and `{"token": "..."}`: revokes that token's family (tokens of other channels: `403`).
- **with the channel secret** and `{"user": {"id": "..."}}`: revokes every token of that end user on the channel
  issued until now. Use it when you ban a user; tokens you generate for the user later are valid again.

Each revocation also disconnects the sockets of the token's subject (end user, agent console or conversation) on
every node. Holders of other valid tokens of the same subject reconnect normally; the revoked token is refused at
connect.

Deactivating a channel still blocks all of its tokens on the next request and disconnects its sockets; that needs
no revocation.

### How a revocation reaches every node

Revocations are rows of `revoked_tokens`: `fam:<family>` and `user:<channel>:<user>` rows for revocations,
`jti:<jti>` rows for rotated tokens. Every node keeps them in an ETS table (`Converger.Auth.RevocationCache`), so
checking a token costs one ETS lookup per claim and never a query:

1. The revoking node writes the row, inserts it into its own cache and only then answers.
2. It broadcasts the row on `Converger.PubSub`; every other node's cache inserts it on arrival (milliseconds in a
   healthy cluster). The two-node suite asserts that node B refuses a token revoked on node A within a second
   (`mix test --only cluster`).
3. Every node also re-reads recently revoked rows every 60 s, so a node that missed a broadcast (partitioned,
   restarting) catches up. A starting node loads the whole table.

Rows are kept until every token they can match has expired (at most the token lifetime plus a minute) and are then
deleted by the daily prune job. The table holds roughly one row per refresh in the last 30 minutes plus one per
revocation, which stays small even with many clients.

If the database is unavailable when a node starts, its cache starts empty and is loaded on the next sync: until then
the node accepts tokens that were revoked elsewhere. Readiness is already degraded in that situation
([database pressure](../operations/database.md)).

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `TOKEN_SIGNING_KEYS` | unset (`SECRET_KEY_BASE`, kid `default`) | Comma-separated `kid:secret` pairs, signing key first; secrets of at least 32 bytes. |
| `TOKEN_ROTATION_GRACE_SECONDS` | `30` | How long a refreshed token stays valid, and the window in which refreshing it again is not reuse. |
| `TOKEN_ACCEPT_UNKEYED` | `true` | Accept tokens without a `kid` (issued before #52, signed with `SECRET_KEY_BASE`). |

Application config: `config :converger, Converger.Auth.RevocationCache, sync_interval_ms: 60_000`. See
[configuration](../operations/configuration.md#client-tokens).
