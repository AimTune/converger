---
title: "ADR-0074: Publishable keys mint anonymous, conversation-bound tokens for browsers"
sidebar_label: "0074 Publishable keys"
description: A per-channel publishable key, usable only from allowed origins, lets a site without a backend get client tokens; each call mints an anonymous end user and a token bound to one conversation, continued with a signed resume credential.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Issue** | [#195](https://github.com/AimTune/converger/issues/195) (and [#194](https://github.com/AimTune/converger/issues/194), test tokens) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0059](0059-client-token-keys-revocation-rotation-and-permissions.md), [ADR-0065](0065-chativa-as-reference-client-and-history-cursor.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md) |

## Context and problem statement

A client token comes from `POST /api/v1/converger/tokens/generate`, authenticated with the channel secret. That
works when the site embedding a chat widget has a backend to hold the secret. Many sites do not: static sites, CMS
pages, landing pages. Their only option today is to put the channel secret in the page, and then anyone who reads
the page source can:

- mint tokens for **any** `user.id`, so impersonate the site's real users (their conversations, their identity in
  agent consoles);
- use the channel's per-channel `token_generate` bucket (10 per minute), so lock every visitor out;
- revoke other users' tokens with `tokens/revoke`, which also accepts the secret.

A second, smaller need came up while trying chativa against a local hub: an operator who wants to try a channel has
to keep the secret (shown once) and run curl to get a token ([#194](https://github.com/AimTune/converger/issues/194)).

## Decision drivers

- A credential in page source must not let its reader act as anyone other than a new anonymous visitor.
- One abusive client must not be able to lock a channel for everyone.
- A visitor who reloads the page continues the same conversation.
- No new infrastructure, and nothing that weakens the secret-based flow.
- Self-service: a tenant can embed a widget on its own site without an operator changing `CORS_ORIGINS`.

## Considered options

1. **Secret in the browser** - document the risk and leave it to tenants.
2. **Publishable key that mints unscoped tokens** - like `tokens/generate`, without a caller-chosen user id.
3. **Publishable key that mints conversation-bound tokens, with a signed resume credential** - the endpoint creates
   the conversation and the anonymous user; continuing needs a credential only the server can sign.
4. **Publishable key with a client-chosen visitor id** - the client keeps a random id and sends it back.

### Pros and cons of the options

#### Option 1

- Good, because there is nothing to build.
- Bad, because every risk above stays, and it is the path of least resistance for every static site.

#### Option 2

- Good, because the widget works like today's flow (create a conversation, then use it).
- Bad, because an unscoped token can open **any** conversation of its channel by id
  (`GET /conversations/:id` returns a token bound to it, see `ConvergerWeb.Helpers.Authorization`). Conversation ids
  are random UUIDs, but they appear in links, logs and agent tools; a public key must not turn knowing an id into
  reading the conversation.

#### Option 3

- Good, because a minted token can only ever reach the conversation created for it; no existing authorization rule
  changes.
- Good, because the resume credential is unforgeable (`Phoenix.Token`, signed with `secret_key_base`) and names the
  channel, the conversation and the user, so it cannot be replayed against another channel or pointed elsewhere.
- Bad, because every call without `resume` creates a conversation, so the per-IP and per-channel limits matter.

#### Option 4

- Good, because it needs no signing.
- Bad, because a visitor id is a bearer credential the client invents: anyone who learns it (or guesses a weak one)
  becomes that visitor, and nothing stops a client from sending an id that a backend uses for a real user.

## Decision

Chosen option: **"Publishable key that mints conversation-bound tokens, with a signed resume credential"** (3),
because it is the only option where the key's reader can do nothing but be a new anonymous visitor.

- **The key.** A channel may have one publishable key (`cvg_pk_` + 32 random bytes, base64url), stored in plain text
  (it is public) with a partial unique index, and a list of **allowed origins** (exact `scheme://host[:port]` or a
  subdomain wildcard `https://*.example.com`, at most 20). A key needs at least one origin. Enabling, rotating
  (the old key stops at once) and disabling are audited, as is changing the origins.
- **The endpoint.** `POST /api/v1/converger/tokens/publishable` with `Authorization: Bearer cvg_pk_...`. Checks, in
  order: the per-IP limit `publishable_token_ip` (10/min, before any database work), the key (active channel), the
  `Origin` header against the allowed origins (missing or not allowed: `403 origin_not_allowed`), the per-channel
  limit `publishable_token` (300/min, tenant-overridable).
- **What it mints.** An anonymous user `anon_` + 16 random bytes, a new conversation (`metadata.source:
  "publishable_key"`) and a token bound to it with the claim `src: "publishable"`. The response carries `resume`.
- **Resume.** A `Phoenix.Token` over `{channel, conversation, user}`, valid 7 days (`PUBLISHABLE_RESUME_MAX_AGE`).
  A valid credential for an open conversation of the same channel returns a fresh token for it (`resumed: true`);
  anything else starts a new conversation (`resumed: false`) rather than failing, so a stale browser recovers.
- **Refresh.** `tokens/refresh` keeps `src`, and a token with `src: "publishable"` refreshes against the
  `publishable_token` bucket instead of the secret flow's 10/min `token_generate`, which a busy widget would exhaust.
- **CORS.** On `/api/v1/converger/*` only, the endpoint's CORS origin function also allows the request's origin when
  an active publishable key lists it (`Converger.Channels.PublishableOrigins`, cached per node for 30 s and
  invalidated on change). The native WebSocket has no origin check (tokens, not cookies), so the widget needs nothing
  else. Admin, portal and tenant API paths never gain origins this way.
- **Test tokens (#194).** The channel page's Client access panel (admin roles `super_admin`/`admin`, portal roles
  `owner`/`admin`) issues an unscoped token for an operator-chosen user id, exactly what `tokens/generate` returns,
  audited as `test_token` with the token's `jti`. The same panel manages the publishable key.

## Consequences

### Positive

- Sites without a backend can embed a widget safely; the secret never needs to leave a server.
- A leaked or abused key is contained: it cannot impersonate, cannot read other conversations, cannot revoke, and is
  limited per IP; rotating it stops it at once.
- Operators try a channel from the panel without handling the secret.

### Negative and trade-offs

- The `Origin` check stops other websites from using the key in their visitors' browsers; it is **not**
  authentication. A script outside a browser can send any `Origin`. The limits, not the origin check, bound what such
  a script can do (create anonymous conversations).
- Every call without `resume` creates a conversation; abandoned ones accumulate like any other and are handled by
  retention.
- Rotating `SECRET_KEY_BASE` invalidates every resume credential: visitors start new conversations.
- An origin added to one channel's key is allowed by CORS on the whole client API (CORS preflights carry no
  credential, so the channel is unknown at that point). The client API authenticates with bearer tokens, never
  cookies, so this exposes nothing a page could not already reach with a token.
- Up to 30 s after a change, other nodes may still allow a removed origin in CORS (the token endpoint itself checks
  the database every time).

### Follow-ups

- chativa: `PublishableKeyAuth` in `@chativa/connector-converger` and the sandbox's credential modes
  ([AimTune/chativa#91](https://github.com/AimTune/chativa/issues/91)).
- Identified visitors on top of publishable keys (a site's own login signing the user id) are out of scope.

## Implementation

- Migrations `20261015180000_add_publishable_key_to_channels` (columns) and
  `20261015180100_add_publishable_key_index_to_channels` (concurrent partial unique index).
- `Converger.Channels.Origins` (normalizing and matching), `Converger.Channels.Channel.client_access_changeset/3`,
  `Converger.Channels.update_client_access/4`, `get_channel_by_publishable_key/1`, `issue_test_token/3`.
- `Converger.Auth.PublishableResume`, the `src` claim in `Converger.Auth.ConvergerToken`.
- `ConvergerWeb.ConvergerAPI.PublishableTokenController`, the refresh bucket choice in
  `ConvergerWeb.ConvergerAPI.TokenController`, `ConvergerWeb.Endpoint.cors_origins/1`,
  `Converger.Channels.PublishableOrigins`.
- `ConvergerWeb.Live.ChannelAccess` and `ConvergerWeb.ChannelComponents.client_access_panel/1`.
- Tests: `test/converger/channels/origins_test.exs`,
  `test/converger_web/controllers/publishable_token_controller_test.exs`,
  `test/converger_web/live/channel_access_live_test.exs`.

## Links

- [Publishable keys](../security/publishable-keys.md)
- [Client API](../api/client-api.md#publishable-keys)
- [Admin UI](../admin-ui.md#client-access)
- [Connecting chat clients](../protocol/clients.md)
