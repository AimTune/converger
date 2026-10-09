import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :converger, Converger.Repo,
  username: System.get_env("DB_USERNAME") || "postgres",
  password: System.get_env("DB_PASSWORD") || "postgres",
  hostname: System.get_env("DB_HOSTNAME") || "localhost",
  database: System.get_env("DB_NAME") || "converger_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Only in tests, remove the complexity from the password hashing algorithm.
# Full-cost hashing makes login tests slow enough to straddle the 60 s
# login-lockout window (see test/converger_web/controllers/rate_limiting_test.exs).
config :bcrypt_elixir, :log_rounds, 1

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :converger, ConvergerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9Ov2AhAq9kITaSWzIOHQlF0OjtggqukSSK19U94ghQsnmuWqnKNRkQ/2PjUT9xNm",
  server: false

# No readiness grace period when the test app stops.
config :converger, :websocket, drain_delay_ms: 0

# In test we don't send emails
config :converger, Converger.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Configure Oban for testing
config :converger, Oban, testing: :inline

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Use inline pipeline for synchronous testing
config :converger, pipeline: [backend: Converger.Pipeline.Inline]

# No health probes against real providers in tests (tests enable them per case)
config :converger, :channel_health, probe_idle_channels: false

# Use a different port for metrics in test to avoid conflicts with dev server
config :converger, :prometheus_port, false

# Store test uploads in a temp dir (per partition)
config :converger, Converger.Uploads,
  storage: Converger.Uploads.LocalStorage,
  storage_opts: [
    dir:
      Path.join(
        System.tmp_dir!(),
        "converger_test_uploads#{System.get_env("MIX_TEST_PARTITION")}"
      )
  ],
  max_file_size: 1024 * 1024

# Disable OpenTelemetry span export in test
config :opentelemetry, traces_exporter: :none

# Deterministic DNS for the webhook SSRF guard (no network lookups in tests).
# Deliveries that are not stubbed with Req.Test fail fast instead of waiting
# for the default connect timeout.
config :converger, :webhook,
  resolver: {Converger.TestDnsResolver, :resolve},
  connect_timeout: 200,
  receive_timeout: 1_000

# Deterministic encryption key for tests only.
config :converger, Converger.Vault, key: Base.encode64("converger-tst-cloak-key-32bytes!")

# The SQL sandbox wraps every test in a transaction, and
# DETACH PARTITION ... CONCURRENTLY cannot run inside one. Partitions are not
# created on boot either: test/test_helper.exs creates them outside the sandbox.
config :converger, Converger.Partitions,
  detach_concurrently: false,
  ensure_on_boot: false

# Forward typing indicators and read receipts to external channels inline
# (Converger.Channels.Signals), so tests see the provider calls synchronously.
config :converger, :channel_signals_async, false
