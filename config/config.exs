# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :converger,
  ecto_repos: [Converger.Repo],
  generators: [timestamp_type: :utc_datetime],
  cors_origins: ["http://127.0.0.1:5500", "http://localhost:5500"],
  admin_ip_whitelist: ["127.0.0.1", "::1"],
  pipeline: [backend: Converger.Pipeline.Oban]

# Configures the endpoint
config :converger, ConvergerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ConvergerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Converger.PubSub,
  live_view: [signing_salt: "a84R5GFm"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :converger, Converger.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use LoggerJSON for structured logging in production/dev if desired,
# but usually we keep console logger for dev and structured for prod.
# However, user asked for "Setup structured logging".
# Let's add it but comment out or use env check?
# Or just replace the console logger?
# The user wants structured logging, so I will configure it as a second backend or replace default.
# For now, I'll add Oban config here.

config :converger, Oban,
  repo: Converger.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 3600 * 24},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Converger.Workers.ConversationExpirationWorker}
     ]}
  ],
  queues: [default: 10, deliveries: 20]

# Configure Hammer for Rate Limiting
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

# Configure OpenTelemetry
config :opentelemetry,
  resource: %{service: %{name: "converger"}},
  processors: [
    {:otel_batch_processor,
     %{
       exporter:
         {:otel_exporter_otlp,
          %{
            protocol: :http_protobuf,
            endpoints: ["http://localhost:4318"]
          }}
     }}
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
