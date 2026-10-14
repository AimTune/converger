This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

## Documentation

The documentation site (https://converger.aimtune.dev) is built with Docusaurus from `website/`, and its content is the
repository's `docs/` folder (single source of truth). Documentation is part of every change:

- **Every PR must update the relevant `docs/` pages** in the same PR: behaviour, API shapes, config/env vars, adapters,
  operations, security. Planned features are marked with their issue number.
- **When an architectural decision is made or changed, add a new ADR (or supersede an existing one) in `docs/adr/`**
  using `docs/adr/template.md`, and add it to `docs/adr/index.md`. See `docs/adr/how-we-write-adrs.md`.
- New pages need front matter (`title`, `description`, `sidebar_position`); new folders need a `_category_.json`.
  `.md` files are CommonMark (not MDX); link other docs by relative path with the `.md` extension.
- Run `cd website && npm ci && npm run build` when you change docs; broken links fail the build.
- CI enforces this: the "Docs required" job (`.github/workflows/docs.yml`) fails when `lib/`, `config/` or
  `priv/repo/migrations/` change without any change under `docs/`. Only for changes with genuinely no documentation
  impact may a maintainer add the `no-docs` label, with the reason stated in the PR description.

## Changelog and releases

`CHANGELOG.md` is written **only when a release is cut**, never in feature or fix PRs (parallel PRs kept
conflicting on it). PR descriptions carry the details instead; the release notes are compiled from them.

- **Do not edit `CHANGELOG.md` in a PR.** Put user-facing changes, **Breaking changes** and **Deployment notes**
  in the PR description.
- **Cutting a release** (only when the maintainer asks for one):
  1. Collect what changed since the last tag: `git describe --tags --abbrev=0` (no tag yet: since the start),
     `git log <last-tag>..origin/main --merges --first-parent`, and the merged PRs' titles and descriptions
     (`gh pr list --state merged --search "merged:>=<date of last tag>"`).
  2. Draft the release notes (Keep a Changelog groups: Added / Changed / Fixed / Deprecated / Removed / Security,
     plus Breaking changes and Deployment notes, each line linking its PR or issue) and the proposed version
     (SemVer: breaking → major, features → minor, fixes → patch).
  3. **Show the draft and the version to the maintainer and wait for approval.** Do not commit, tag or push before
     that.
  4. After approval: one `chore(release): vX.Y.Z` PR that adds the `## [X.Y.Z] - YYYY-MM-DD` section to
     `CHANGELOG.md` (and bumps `version` in `mix.exs`); once it is merged, tag that commit `vX.Y.Z` and create
     the GitHub release from the same notes (`gh release create vX.Y.Z --notes-file ...`).

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->