import Config

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Req

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Structured JSON logging in production (LoggerJSON 6 is an Erlang :logger
# formatter: it is configured on the default handler, not as a backend or
# as a `format:` callback, either of which crashes or is ignored).
config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: :all,
     redactors: [
       {LoggerJSON.Redactors.RedactKeys,
        ~w(api_key secret token password access_token app_secret verify_token x-api-key x-channel-token authorization)}
     ]}

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
