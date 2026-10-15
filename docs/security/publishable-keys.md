---
title: Publishable keys
description: How a site without a backend gets client tokens safely with a channel's publishable key, what the key can and cannot do, allowed origins, resume, limits and rotation.
sidebar_position: 3
---

A **publishable key** (`cvg_pk_...`) is a channel credential that is safe to put in page source. It is for sites that
embed a chat widget but have no backend to hold the channel secret: static sites, CMS pages, landing pages.
**Implemented ([#195](https://github.com/AimTune/converger/issues/195), [ADR-0074](../adr/0074-publishable-keys-for-browser-clients.md)).**

If your site has a backend, keep using the channel secret there
(`POST /api/v1/converger/tokens/generate`, see [client tokens](client-tokens.md)): it lets you name your signed-in
users. **Never put the channel secret in a browser.** Anyone reading the page could mint tokens for any user id,
revoke other users' tokens and use up the channel's token limit.

## What the key can and cannot do

| With a publishable key a page can | It cannot |
| --- | --- |
| Get a token for a **new anonymous visitor** (`anon_...`, chosen by the server) | Choose or claim a user id |
| Use that token on **one conversation**, created for the visitor | Open, read or post to any other conversation of the channel |
| Continue its own conversation after a reload with the `resume` credential | Revoke tokens or list conversations |
| Do this only from the key's **allowed origins** | Be used from other websites in their visitors' browsers |

The token is an ordinary Converger token bound to the visitor's conversation (claim `conversation_id`), with
`src: "publishable"`. It works on the client API, the WebSocket (`/socket/converger/v1`), Server-Sent Events and
uploads, and refreshes with `POST /api/v1/converger/tokens/refresh` like any other.

## Setting it up

In the admin panel or the tenant portal (roles `owner` and `admin`), open **Channels**, click **Client access** on
the channel, enter the **allowed origins** and click **Save and enable key**. See [admin UI](../admin-ui.md#client-access).

Allowed origins are what browsers send in the `Origin` header:

- an exact origin: `https://shop.example.com`, `http://localhost:5173` (a default port is dropped:
  `https://example.com:443` is `https://example.com`);
- a subdomain wildcard: `https://*.example.com` matches `https://a.example.com` and `https://a.b.example.com`, not
  `https://example.com` (list it separately).

Paths, queries, credentials, other schemes and a bare `*` are refused. A channel allows at most 20 origins, and a key
needs at least one.

Then, in the page:

```js
const res = await fetch("https://converger.example.com/api/v1/converger/tokens/publishable", {
  method: "POST",
  headers: {
    authorization: "Bearer cvg_pk_...",
    "content-type": "application/json",
  },
  body: JSON.stringify({ resume: localStorage.getItem("converger-resume") ?? undefined }),
});
const { token, conversationId, resume } = await res.json();
localStorage.setItem("converger-resume", resume);
// Connect to wss://converger.example.com/socket/converger/v1 with `token`.
```

chativa does this for you with `PublishableKeyAuth` from `@chativa/connector-converger`
([connecting chat clients](../protocol/clients.md#publishable-keys)). The full request and response are in the
[client API](../api/client-api.md#publishable-keys).

## Resume

Every response carries `resume`, a credential signed by the server (`Phoenix.Token` with the endpoint's
`secret_key_base`) that names the channel, the conversation and the anonymous user. Send it on the next call to get a
fresh token for the same conversation as the same user (`resumed: true`). It cannot be forged or pointed at another
conversation.

When it is invalid, expired, for another channel, or its conversation is closed or gone, the call does **not** fail:
it starts a new conversation and says `resumed: false`, so replace what you stored. Credentials expire after 7 days
(`PUBLISHABLE_RESUME_MAX_AGE`, seconds). Rotating `SECRET_KEY_BASE` invalidates all of them.

## Limits

| Bucket | Default | Counted per | Applies to |
| --- | --- | --- | --- |
| `publishable_token_ip` | 10 per minute | client IP | `POST /tokens/publishable`, checked before the key is looked up |
| `publishable_token` | 300 per minute | channel (tenant override) | `POST /tokens/publishable`, and `POST /tokens/refresh` of tokens with `src: "publishable"` |

Behind a proxy, set `TRUSTED_PROXIES` so the client IP is the visitor's, not the proxy's. See
[rate limiting](../operations/rate-limiting.md).

## The origin check is not authentication

The `Origin` header stops other websites from using your key in their visitors' browsers: a browser always sends the
real origin and the request is refused (`403 origin_not_allowed`). A script outside a browser can send any `Origin`,
though. That is acceptable because all such a script can do is what any visitor can do, create anonymous
conversations, and the limits above bound how many.

## Rotating and disabling

**Rotate key** issues a new key; the old one stops working at once, so update the page. Tokens already issued keep
working until they expire (30 minutes) or are refreshed; resume credentials stay valid. **Disable key** stops new
tokens for the channel. Both, and every change to the origins, are in the audit log (`rotate_publishable_key`,
`disable_publishable_key`, `enable_publishable_key`, `update_allowed_origins`).

## CORS

On `/api/v1/converger/*`, Converger also allows (CORS) every origin listed by an active publishable key, in addition to
`CORS_ORIGINS`, so the widget's token, refresh, history and upload requests work from your site without an operator
change. Other paths (admin, portal, tenant API) never gain origins this way. Nodes cache the list for 30 seconds, so a
removed origin can still pass CORS on another node for that long; the token endpoint itself always checks the
database. The native WebSocket needs no CORS: it authenticates with the token, not cookies.
