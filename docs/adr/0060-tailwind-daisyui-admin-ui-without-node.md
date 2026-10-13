---
title: "ADR-0060: Tailwind and daisyUI admin UI, built without Node.js"
sidebar_label: "0060 Tailwind admin UI"
description: The admin panel and tenant portal stay server-rendered LiveView, styled with Tailwind CSS v4 and daisyUI 5 (the Phoenix 1.8 default stack) and built by the standalone tailwind and esbuild binaries, so neither development nor the release image needs Node.js or a CDN.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#50](https://github.com/AimTune/converger/issues/50) |
| **Pull request** | [#162](https://github.com/AimTune/converger/pull/162) |
| **Related** | [ADR-0023](0023-platform-and-dependency-baseline.md), [ADR-0022](0022-deployment-hardening.md) |

## Context and problem statement

The admin panel (`/admin`) and the tenant portal (`/portal`) are about 5,400 lines of LiveView and controller
templates. They had no asset pipeline: three root layouts loaded `phoenix` and `phoenix_live_view` from jsDelivr,
bootstrapped the socket in an inline `<script>` and styled the pages with a `<style>` block plus inline `style=`
attributes in every template. `core_components.ex` was a 168-line remnant of an older generator. Forms, flashes,
tables and buttons looked different on every page, there was no dark mode, the browser fetched code from a third
party at runtime (the CSP allowed `cdn.jsdelivr.net`), and every new feature planned in
[#50](https://github.com/AimTune/converger/issues/50) (pagination and search, channel test-send, key rotation, live
tail) would have added more hand-written CSS.

We had to choose a UI foundation before building those features. Component libraries such as PrimeVue and PrimeReact
were considered, as was the Phoenix 1.8 default stack.

## Decision drivers

- Keep the admin UI in LiveView: server-rendered, the same auth hooks, `Phoenix.LiveViewTest` tests, changeset
  validation through `<.input>`, and the project guidelines in `AGENTS.md`.
- No new runtime or build dependency for operators and contributors: today the release image needs only Elixir,
  and Windows contributors already avoid native toolchains ([ADR-0057](0057-pluggable-password-hasher-and-dev-container.md)).
- Nothing loaded from a third-party origin at runtime; a tighter CSP.
- One consistent component set with light and dark themes and accessible defaults.

## Considered options

1. **Tailwind CSS v4 + daisyUI 5 + heroicons, standalone binaries** - the Phoenix 1.8 generator stack
2. **PrimeVue / PrimeReact inside LiveView** - Vue or React islands through LiveVue / LiveReact
3. **PrimeVue SPA** - a separate single-page app over a new JSON admin API
4. **Keep hand-written CSS** - move the inline styles into one stylesheet

### Pros and cons of the options

#### Tailwind + daisyUI

- Good, because it is what `mix phx.new` generates for Phoenix 1.8: the generated `core_components.ex` (flash,
  button, input, table with stream support, header, list, icon) works unchanged and the Phoenix and LiveView
  documentation applies directly.
- Good, because the `tailwind` and `esbuild` Hex packages download standalone binaries (also for Windows): no
  Node.js, no npm, no `package.json`. heroicons and daisyUI are sparse git dependencies read by Tailwind.
- Good, because daisyUI gives semantic components (card, table, badge, alert, menu, drawer) and themes, so dark mode
  is a second set of color variables, not a second stylesheet.
- Bad, because daisyUI has no data grid, date picker or chart: those are built from LiveView primitives or added
  later as a hook.

#### PrimeVue / PrimeReact islands

- Good, because it brings rich widgets (DataTable with column filters, calendars, charts) and a polished look.
- Bad, because the components are Vue or React only; every table and form becomes a client component that LiveView
  feeds with props, so state lives in two places and changeset errors, `phx-change` validation and `stream/3` no
  longer map onto the widgets.
- Bad, because it needs Vite, npm and a Node.js stage in the Docker build, and the tests would have to cover the
  JavaScript side too.

#### PrimeVue SPA

- Good, because it separates the UI from the server completely.
- Bad, because it rewrites all 16 pages, needs a new JSON admin API with its own authentication and audit, and
  loses LiveView's live updates. It is a separate project, not #50.

#### Hand-written CSS

- Good, because it adds no dependency.
- Bad, because it keeps the inconsistency problem and leaves forms, tables, themes and accessibility to us.

## Decision

Chosen option: **"Tailwind + daisyUI"**, because it is the only option that keeps the admin UI in LiveView and adds
no Node.js or CDN dependency, while still giving one component set with themes.

- `assets/css/app.css` imports Tailwind, the heroicons plugin (`assets/vendor/heroicons.js`, reading
  `deps/heroicons`) and daisyUI with a light and a dark Converger theme (the generator themes with a blue
  primary). `assets/js/app.js` bundles `phoenix_html`, `phoenix`, `phoenix_live_view` and topbar from `deps/`.
- `mix assets.build` (development, also part of `mix setup`) and `mix assets.deploy` (minified, digested, run by the
  `Dockerfile`) produce `priv/static/assets/`, which is not committed. In development the endpoint watchers rebuild
  on change.
- One root layout (`root.html.heex`) for every page. LiveViews render inside `<Layouts.app flash={@flash} nav={@nav}>`
  (sidebar drawer, navbar with the user and the theme toggle, flash group); `ConvergerWeb.Live.AuthHooks` assigns
  `nav` (section, user, tenant, current path). The login and password pages use `<Layouts.auth>`.
- The theme (system, light or dark) is applied by a short inline script in `<head>` before the first paint and
  stored in `localStorage`.
- No inline `style=` attributes in templates; colors come from daisyUI's semantic tokens so both themes work.

## Consequences

### Positive

- The browser loads only same-origin assets; `cdn.jsdelivr.net` is gone from the CSP.
- Every page shares the same frame, flash messages, tables, badges, buttons and inputs, in light and dark mode.
- The phoenix and LiveView JavaScript always matches the Hex versions in `mix.lock` instead of a hard-coded CDN URL.
- The remaining #50 work (pagination and search, test-send, key rotation, live tail) builds on generator
  components instead of new CSS.

### Negative and trade-offs

- The first `mix assets.setup` / Docker build downloads the tailwind and esbuild binaries (from GitHub and the npm
  registry) and the heroicons and daisyUI git tags. Air-gapped builds need those mirrored.
- Pages without `<Layouts.app>` render without navigation or flash messages; reviewers have to catch that (there
  is no implicit LiveView layout any more, as in Phoenix 1.8).
- `'unsafe-inline'` stays in `script-src` and `style-src`, for the theme script and the Oban Web dashboard.

### Follow-ups

- [#50](https://github.com/AimTune/converger/issues/50) part 2 (done): search, filters, sort and keyset **Load more** on every
  list, channel test-send and secret rotation, health sparkline, tenant editing, conversation live tail, viewer
  read-only enforcement; see [Admin panel and tenant portal](../admin-ui.md).
- A CSP nonce for the theme script and Oban Web (`csp_nonce_assign_key`) would allow dropping `'unsafe-inline'`.

## Implementation

- Build: `mix.exs` (`:tailwind`, `:esbuild`, `:heroicons`, `:daisyui`; `assets.setup`, `assets.build`,
  `assets.deploy` aliases), `config/config.exs` (binary versions and arguments), `config/dev.exs` (watchers),
  `config/prod.exs` (`cache_static_manifest`), `Dockerfile` (`mix assets.deploy`).
- UI: `assets/`, `lib/converger_web/components/layouts.ex`, `layouts/root.html.heex`, `core_components.ex`
  (generator components plus `badge`, `panel`, `stat`, `empty_state`), `lib/converger_web/live/auth_hooks.ex`.
- Tests: the existing LiveView and controller tests run against the new templates (ids, events and texts are kept).

## Links

- [Admin panel and tenant portal](../admin-ui.md)
- [Security overview: browser headers](../security/overview.md#browser-headers-and-uploads)
- [Contributing](../contributing.md)
- Phoenix 1.8 assets: [tailwind](https://hex.pm/packages/tailwind), [esbuild](https://hex.pm/packages/esbuild),
  [daisyUI](https://daisyui.com/)
