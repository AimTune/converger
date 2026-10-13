defmodule Converger.MixProject do
  use Mix.Project

  def project do
    [
      app: :converger,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      # Acknowledged advisories (Hex >= 2.5.1). `mix hex.audit` lists them
      # without failing and warns once an entry no longer matches: remove it
      # when a fixed version ships.
      hex: [
        ignore_advisories: [
          # cloak 1.1.4 / cloak_ecto 1.3.0, no fixed releases yet. Neither
          # affected code path is used (enforced by test/converger/vault_test.exs):
          # EEF-CVE-2026-95105: Cloak.Ciphers.AES.CTR is unauthenticated; the
          # Vault only configures Cloak.Ciphers.AES.GCM (authenticated).
          "CVE-2026-95105",
          # EEF-CVE-2026-94206: Cloak.Ecto.PBKDF2 ignores the iteration count;
          # we only use Cloak.Ecto.Binary / Cloak.Ecto.Map fields.
          "CVE-2026-94206"
        ]
      ],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: false
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Converger.Application, []},
      extra_applications: [:logger, :runtime_tools, :opentelemetry, :opentelemetry_exporter]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.3"},
      {:mail, "~> 0.5.2"},
      {:req, "~> 0.7"},
      {:open_api_spex, "~> 3.22"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:msgpax, "~> 2.4"},
      {:libcluster, "~> 3.4"},
      {:bandit, "~> 1.12"},
      {:oban, "~> 2.24"},
      {:oban_web, "~> 2.13"},
      {:joken, "~> 2.7"},
      {:logger_json, "~> 7.0"},
      {:phoenix_live_view, "~> 1.2.12"},
      # Admin/portal assets (ADR-0060): standalone tailwind + esbuild binaries, no
      # Node.js. heroicons and daisyUI are sparse git checkouts read by tailwind.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:jsv, "~> 0.26", only: :test},
      # Discord Gateway client (ADR-0055); also the WebSocket client of the tests.
      {:mint_web_socket, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:cors_plug, "~> 3.0"},
      {:broadway, "~> 1.3"},
      # Broker channels (kafka, rabbitmq adapters, ADR-0047; nats, redis_streams,
      # ADR-0054). Patch-level pins: the consumers rely on their ack /
      # offset-commit semantics.
      {:broadway_kafka, "~> 0.7.0"},
      {:brod, "~> 4.7.0"},
      {:broadway_rabbitmq, "~> 0.8.2"},
      {:amqp, "~> 4.3.0"},
      # gRPC transport for Protocol v1 (ADR-0056). Patch-level pins: the stream
      # handler relies on the server adapter's send_reply / request-stream semantics.
      {:grpc_server, "~> 1.0.5"},
      {:grpc, "~> 1.0.5"},
      {:protobuf, "~> 0.17.1"},
      {:gnat, "~> 1.18.1"},
      {:redix, "~> 1.9.2"},
      {:hammer, "~> 7.5"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, "~> 1.2"},
      {:opentelemetry_req, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      # Password hashing (Converger.Accounts.PasswordHasher, ADR-0057). Both implement
      # Comeonin; pbkdf2_elixir is pure Elixir, see password_hasher_deps/0.
      {:pbkdf2_elixir, "~> 2.3"},
      # TOTP two-factor authentication for admin and portal users (ADR-0058).
      {:nimble_totp, "~> 1.0"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ] ++ password_hasher_deps()
  end

  # bcrypt_elixir is a C NIF; on Windows it needs the MSVC build tools (#53).
  # CONVERGER_PASSWORD_HASHER=pbkdf2 leaves it out and hashes with pbkdf2_elixir
  # instead (config/config.exs reads the same variable). Default: bcrypt.
  defp password_hasher_deps do
    case System.get_env("CONVERGER_PASSWORD_HASHER", "bcrypt") do
      "bcrypt" ->
        [{:bcrypt_elixir, "~> 3.0"}]

      "pbkdf2" ->
        []

      other ->
        Mix.raise("CONVERGER_PASSWORD_HASHER must be bcrypt or pbkdf2, got: #{inspect(other)}")
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind converger", "esbuild converger"],
      "assets.deploy": [
        "tailwind converger --minify",
        "esbuild converger --minify",
        "phx.digest"
      ],
      # The committed OpenAPI 3.1 document, priv/static/openapi.json (ADR-0050).
      # `--check` fails on drift (CI). Replaces open_api_spex's own task,
      # which writes OpenAPI 3.0.
      "openapi.spec.json": ["converger.openapi"],
      # Mirrors the CI "lint" and "test" jobs (.github/workflows/ci.yml), but
      # fixes formatting / unused lock entries instead of only checking them.
      # Dialyzer is slow, so it is a separate step: `mix dialyzer`.
      precommit: [
        "compile --warnings-as-errors --force",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "sobelow --config",
        "hex.audit",
        "deps.audit",
        "test --warnings-as-errors"
      ]
    ]
  end
end
