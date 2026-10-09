# Contributing to Converger

The full contributing guide is part of the documentation site:
**https://converger.aimtune.dev/contributing** (source: [`docs/contributing.md`](docs/contributing.md)).

The short version:

1. Set up the toolchain from `.tool-versions` and follow
   [Getting started](https://converger.aimtune.dev/getting-started) (Windows: `bcrypt_elixir` needs the MSVC build
   tools).
2. Use conventional commits (`feat:`, `fix:`, `docs:`, `ci:`, `chore:` ...) and run `mix precommit` before pushing.
3. **Documentation with every change.** Every PR updates the relevant pages under [`docs/`](docs/). An architectural
   decision (made or changed) needs a new or superseding ADR in [`docs/adr/`](docs/adr/) based on
   [`docs/adr/template.md`](docs/adr/template.md). Preview with `cd website && npm ci && npm start`.
4. Follow the [code of conduct](CODE_OF_CONDUCT.md). Contributions are licensed under the [MIT License](LICENSE). Report
   security problems privately as described in [SECURITY.md](SECURITY.md), never in a public issue.
5. The **Docs required** check fails when `lib/`, `config/` or `priv/repo/migrations/` change without any change under
   `docs/`. If a change truly has no documentation impact, say why in the PR description and a maintainer adds the
   **`no-docs`** label; the check re-runs and passes.
