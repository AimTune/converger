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
| `/admin` | `/portal` | Dashboard: counts, delivery status totals, channel health (live) |
| `/admin/tenants` | | Tenants, API key reveal-once and rotation, status, delivery tier, retention |
| `/admin/channels` | `/portal/channels` | Channels, per-type configuration, secret reveal-once, circuit breaker |
| `/admin/conversations` | `/portal/conversations` | Conversations with filters and **Load more**; transcript with delivery badges |
| `/admin/routing_rules` | `/portal/routing_rules` | Routing rules and the dry run (`/admin/routing_rules/dry_run`) |
| `/admin/deliveries` | `/portal/deliveries` | Dead letters and replay, CSV export ([Deliveries page](delivery.md#deliveries-page)) |
| `/admin/webhooks` | `/portal/webhooks` | [Platform event webhooks](platform-webhooks.md) |
| `/admin/audit_logs` | | Audit log |
| `/admin/users`, `/admin/tenant_users` | `/portal/users` | Admin users, tenant users |
| `/admin/oban` | | Oban Web job dashboard ([Delivery](delivery.md#oban-web-dashboard)) |

Planned in [#50](https://github.com/AimTune/converger/issues/50): search and sort on every list, a "send test
message" action on channels, secret rotation and config forms generated from the adapter's `config_schema/0`, a
live tail on the conversation transcript.

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
