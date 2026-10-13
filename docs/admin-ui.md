---
title: Admin panel and tenant portal
description: The pages of the admin panel (/admin) and the tenant portal (/portal), the shared layout and themes, and how their Tailwind/daisyUI assets are built and changed.
sidebar_position: 9
---

Converger ships two browser UIs, both Phoenix LiveView:

- the **admin panel** at `/admin`, for operators (admin users, behind `ADMIN_IP_WHITELIST` and a session,
  see [Security](security.md));
- the **tenant portal** at `/portal`, for the users of one tenant (tenant name, email and password).

They share one design system: [Tailwind CSS](https://tailwindcss.com) v4 with [daisyUI](https://daisyui.com) 5
components and [heroicons](https://heroicons.com), the Phoenix 1.8 default stack
([ADR-0060](adr/0060-tailwind-daisyui-admin-ui-without-node.md)).

## Pages

| Admin panel | Tenant portal | What it shows |
| --- | --- | --- |
| `/admin` | `/portal` | Dashboard: counts, delivery status totals, channel health (live); every tile links to its filtered list |
| `/admin/tenants` | | Tenants, API key reveal-once and rotation, status, delivery tier; **Edit** for retention, tier, alert webhook and rate limit overrides |
| `/admin/channels` | `/portal/channels` | Channels, per-type configuration, health sparkline, circuit breaker pause/resume, **Send test**, **Rotate secret** |
| `/admin/conversations` | `/portal/conversations` | Conversations; transcript with live tail, delivery badges, participant panel, close/reopen |
| `/admin/routing_rules` | `/portal/routing_rules` | Routing rules and the dry run (`/admin/routing_rules/dry_run`) |
| `/admin/deliveries` | `/portal/deliveries` | Dead letters and replay, CSV export ([Deliveries page](delivery.md#deliveries-page)) |
| `/admin/webhooks` | `/portal/webhooks` | [Platform event webhooks](platform-webhooks.md): subscriptions, secret rotation, paged event log |
| `/admin/audit_logs` | | Audit log |
| `/admin/users`, `/admin/tenant_users` | `/portal/users` | Admin users, tenant users, 2FA reset, sign out |
| `/admin/security` | `/portal/security` | Own 2FA, password and active sessions ([ADR-0058](adr/0058-server-side-sessions-totp-2fa-and-password-reset-for-admin-and-portal.md)) |
| `/admin/oban` | | Oban Web job dashboard ([Delivery](delivery.md#oban-web-dashboard)) |

## Lists: search, filters, sort and Load more

Every list page has a filter bar and loads rows in pages of `default_limit` (50, `config :converger, :pagination`)
with **Load more**, using keyset pagination ([ADR-0018](adr/0018-keyset-pagination.md)). The filters are part of the
URL, so a filtered view can be bookmarked or shared; the dashboard links use this (for example
`/admin/deliveries?status=failed`). **Sort** is *Newest first* (default) or *Oldest first* by creation time
(deliveries: by the last status change). Search is case-insensitive and matches a part of the text; `%` and `_`
are matched literally.

| List | Search matches | Other filters |
| --- | --- | --- |
| Tenants | name, or the exact tenant id | status |
| Channels | name, type | tenant (admin), mode, status |
| Conversations | the exact conversation id, or a part of the participant's external id or display name | tenant (admin), channel, status |
| Routing rules | name | tenant (admin), enabled |
| Deliveries | the exact activity id, or a part of `last_error` | tenant (admin), channel, status, from/to date |
| Audit logs | the exact resource id, or a part of the actor id | tenant, actor type, action, resource type, from/to date |
| Admin users | name, email | role, status |
| Tenant users | name, email | tenant (admin), role, status |
| Webhook subscriptions | a part of the URL | |

The CSV export and **Retry all failed** on the Deliveries page use the same filters, including the search.

## Channels

- **Send test** posts a text `message` activity from `bot` into a dedicated conversation of the channel
  (`metadata.converger_test: true`, created on first use and reused), through the normal pipeline: the channel's
  outbox, retries and middleware apply, and so do its routing rules, so rule targets receive it too. The delivery
  status updates live in the panel. Inbound-only and inactive channels cannot send. Providers that need a
  recipient (WhatsApp, Telegram, SMS and similar) record a failed delivery, because the test conversation has no
  participant. Audited as `send_test_message`.
- **Rotate secret** replaces the channel secret. The new one is shown once; the old one stops working at once
  (inbound signatures, `tokens/generate`), so update the integration right away. Open sockets stay connected.
  Audited as `rotate_secret`, with the secret values redacted.
- The **health** column draws the failure rate of the last 20 health checks
  ([channel health](concepts/channels.md)) as a sparkline, with a text summary for screen readers.
- **Pause / Resume** holds and releases the channel's deliveries ([circuit breaker](delivery.md)).

## Conversations

The transcript is live: new activities and delivery status changes appear without reloading (the page subscribes
to the conversation's PubSub topic), marked by a **Live** badge. Each activity shows its delivery status as text
(pending, sent, delivered, read, failed). The participant panel shows the external id, display name, channel,
opt-out date and profile metadata. **Close** and **Reopen** change the conversation's status; on the admin panel
they are audited (`close`, `reopen`).

## Permissions

| Action | Admin panel | Tenant portal |
| --- | --- | --- |
| Browse every page | all roles | all roles (own tenant) |
| Create, edit, delete tenants, channels, routing rules; rotate secrets; send tests; pause/resume | `super_admin`, `admin` | channels: `owner`, `admin` (enable/disable also `member`); routing rules: enable/disable for `owner`, `admin`, `member` |
| Close / reopen conversations | `super_admin`, `admin` | `owner`, `admin`, `member` |
| Manage users | admin users: `super_admin`; tenant users: `super_admin`, `admin` | `owner`, `admin` |

`viewer`s (admin and portal) are read-only: the forms and action buttons are hidden, and the server refuses the
action if it is sent anyway. Deliveries and webhooks have their own matrix, see
[Deliveries page](delivery.md#deliveries-page) and [Platform event webhooks](platform-webhooks.md).

## Layout and themes

Every page has the same frame: a sidebar with the section's navigation (a drawer on small screens), a top bar with
the tenant (portal), the signed-in user and role, the theme toggle and **Logout**, and toast-style flash messages.
The login and password pages use a centered card.

The theme toggle switches between **system** (follows the operating system's light or dark preference), **light**
and **dark**. The choice is stored in the browser's `localStorage` (`phx:theme`) and applied before the page is
painted, so there is no flash of the wrong theme.

## Assets

The CSS and JavaScript are built from `assets/` into `priv/static/assets/` (not committed) by the standalone
`tailwind` and `esbuild` binaries, which the Hex packages of the same name download on first use. Node.js and npm
are not needed, and nothing is loaded from a CDN at runtime.

| Command | What it does |
| --- | --- |
| `mix assets.setup` | Downloads the tailwind and esbuild binaries (also run by `mix setup`) |
| `mix assets.build` | Builds `app.css` and `app.js` for development (also run by `mix setup`) |
| `mix assets.deploy` | Builds minified assets and digests them (`phx.digest`); used by the `Dockerfile` |
| `mix phx.server` | In development, the endpoint watchers rebuild the assets on every change |

The versions are pinned in `config/config.exs` (`config :tailwind, version:` and `config :esbuild, version:`), and
heroicons and daisyUI in `mix.exs` (git tags). An air-gapped build needs the binaries from GitHub
(`tailwindlabs/tailwindcss` releases) and the npm registry (`@esbuild/<platform>`), and the two git repositories,
mirrored.

| File | Purpose |
| --- | --- |
| `assets/css/app.css` | Tailwind entry: sources, the heroicons plugin, daisyUI and the light/dark themes |
| `assets/js/app.js` | LiveSocket, `phoenix_html` (for `method="delete"` links and `data-confirm`) and the topbar |
| `assets/vendor/` | The heroicons Tailwind plugin and topbar |

## Writing pages

- Wrap every LiveView's `render/1` in `<Layouts.app flash={@flash} nav={@nav}>`. There is no implicit LiveView
  layout: a page without it has no navigation and shows no flash messages. `nav` is assigned by
  `ConvergerWeb.Live.AuthHooks`. Controller pages use `<Layouts.auth flash={@flash} title="...">`.
- Use the components in `ConvergerWeb.CoreComponents`: `<.header>`, `<.panel>`, `<.table>` (works with
  `stream/3`), `<.input>`, `<.button>` (`variant` and `size`), `<.badge value={status} />` (colored by value),
  `<.stat>`, `<.empty_state>`, `<.icon name="hero-...">`.
- Style with Tailwind utilities and daisyUI's semantic colors (`text-base-content/60`, `bg-base-200`,
  `text-error`) so both themes work. No inline `style=` attributes.
- Give every form with `phx-change` or `phx-submit` an `id`; use `data-confirm` for confirmation dialogs.

## Security

The `:browser` pipeline's Content Security Policy only allows same-origin scripts and styles, plus
`'unsafe-inline'` for the theme script and the Oban Web dashboard. See
[Security overview: browser headers](security/overview.md#browser-headers-and-uploads).
