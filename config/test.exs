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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :converger, ConvergerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9Ov2AhAq9kITaSWzIOHQlF0OjtggqukSSK19U94ghQsnmuWqnKNRkQ/2PjUT9xNm",
  server: false

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

# Use a different port for metrics in test to avoid conflicts with dev server
config :converger, :prometheus_port, 9569
