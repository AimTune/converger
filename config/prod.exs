import Config

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Req

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Use structured JSON logging in production
config :logger_json, :backend,
  formatter: LoggerJSON.Formatters.Basic,
  metadata: :all,
  redactors: [
    {LoggerJSON.Redactors.Generic, ~w(api_key secret token password x-api-key x-channel-token)}
  ]

config :logger, :default_formatter,
  format: {LoggerJSON.Formatters.Basic, :format},
  metadata: :all

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
