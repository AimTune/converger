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
          # cowlib 2.20.0, no fixed release yet. cowlib is only pulled in for
          # the Prometheus metrics listener (plug_cowboy); the app is served by
          # Bandit. Neither affected function is reachable with client input:
          # EEF-CVE-2026-43966: cow_http_struct_hd:escape_string/2 (encoding
          # structured response headers, not used by the metrics endpoint).
          "CVE-2026-43966",
          # EEF-CVE-2026-43969: cow_cookie:cookie/1 builds client Cookie
          # request headers; we never act as a cowboy/gun HTTP client.
          "CVE-2026-43969",
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
      {:req, "~> 0.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.12"},
      {:oban, "~> 2.24"},
      {:oban_web, "~> 2.13"},
      {:joken, "~> 2.6"},
      {:logger_json, "~> 7.0"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:gettext, "~> 0.20"},
      {:cors_plug, "~> 3.0"},
      {:broadway, "~> 1.3"},
      {:hammer, "~> 7.5"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, "~> 1.2"},
      {:opentelemetry_req, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:bcrypt_elixir, "~> 3.0"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
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
