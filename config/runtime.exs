import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/converger start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :converger, ConvergerWeb.Endpoint, server: true
end

config :converger,
       :prometheus_port,
       String.to_integer(System.get_env("PROMETHEUS_PORT") || "9568")

# Configurable CORS origins and admin IP whitelist.
# CORS origins are read per request by ConvergerWeb.Endpoint, so this takes
# effect on releases without recompiling.
if cors_origins = System.get_env("CORS_ORIGINS") do
  config :converger,
    cors_origins:
      cors_origins
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
end

if admin_ips = System.get_env("ADMIN_IP_WHITELIST") do
  config :converger,
    admin_ip_whitelist: admin_ips |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Reverse proxies / load balancers allowed to set X-Forwarded-For
# (comma-separated IPs or CIDR ranges, e.g. "10.0.0.0/8,fd00::/8").
# When unset, forwarding headers are ignored and conn.remote_ip is the TCP peer.
if trusted_proxies = System.get_env("TRUSTED_PROXIES") do
  config :converger,
    trusted_proxies: trusted_proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# OpenTelemetry trace export.
#
# Spans are exported over OTLP only when an endpoint is configured through the
# standard OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT env
# vars; otherwise export is disabled (`traces_exporter: :none`) so no requests
# are attempted. The exporter itself reads the remaining standard OTLP vars
# (OTEL_EXPORTER_OTLP_PROTOCOL, OTEL_EXPORTER_OTLP_HEADERS,
# OTEL_EXPORTER_OTLP_COMPRESSION and their *_TRACES_* variants), and the SDK
# honours OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES and OTEL_SDK_DISABLED.
# Export is always disabled in the test environment.
otel_endpoint =
  Enum.find_value(
    ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_ENDPOINT"],
    fn var ->
      case System.get_env(var) do
        nil -> nil
        value -> if String.trim(value) == "", do: nil, else: value
      end
    end
  )

if otel_endpoint && config_env() != :test do
  config :opentelemetry, traces_exporter: {:opentelemetry_exporter, %{}}
else
  config :opentelemetry, traces_exporter: :none
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :converger, Converger.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  if byte_size(secret_key_base) < 64 do
    raise """
    environment variable SECRET_KEY_BASE is too short (#{byte_size(secret_key_base)} bytes).
    It must be at least 64 bytes. Generate one with: mix phx.gen.secret
    """
  end

  # SHA-256 fingerprints of secrets that were published in this repository
  # (the SECRET_KEY_BASE formerly hardcoded in docker-compose.yml
  # and the demo CLOAK_KEY proposed alongside it). They are public knowledge,
  # so refuse to boot with them. See docs/security.md.
  leaked_secret_fingerprints = [
    "d759ffb9f77efdcea1576616cc59e9b9834eed3e84c1a67f95c265dd9d06ab5b",
    "43cf796f773e59d3e3729463263820ec49ca51bf04431344a7803931ee46d16c"
  ]

  for {var, value} <- [
        {"SECRET_KEY_BASE", secret_key_base},
        {"CLOAK_KEY", System.get_env("CLOAK_KEY")}
      ],
      is_binary(value),
      Base.encode16(:crypto.hash(:sha256, value), case: :lower) in leaked_secret_fingerprints do
    raise """
    environment variable #{var} is set to a value that was published in the
    Converger git repository and must be considered compromised.
    Generate a new secret and rotate it (see docs/security.md).
    """
  end

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :converger, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :converger, ConvergerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Allowed origins for browser WebSocket connections (LiveView and the
  # Phoenix sockets). Comma-separated, e.g.
  # "https://converger.example.com,//*.example.com". When unset, Phoenix only
  # accepts the host of the endpoint `url` (PHX_HOST). Non-browser clients
  # that send no Origin header are not affected.
  if check_origin = System.get_env("CHECK_ORIGIN") do
    origins =
      check_origin
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if origins == [] do
      raise "environment variable CHECK_ORIGIN is set but contains no origins"
    end

    config :converger, ConvergerWeb.Endpoint, check_origin: origins
  end

  # HTTPS enforcement (ConvergerWeb.Plugs.ForceSSL). Enabled by default in
  # production: plain HTTP requests are redirected to https://PHX_HOST and
  # HTTPS responses carry an HSTS header. Behind a TLS-terminating proxy, set
  # TRUSTED_PROXIES so its X-Forwarded-Proto header is honoured; the header is
  # ignored from any other peer. Set FORCE_SSL=false only when TLS is
  # enforced elsewhere and the app never receives plain HTTP from clients.
  truthy? = fn var, default ->
    case System.get_env(var) do
      nil -> default
      value -> String.downcase(String.trim(value)) in ~w(true 1 yes on)
    end
  end

  if truthy?.("FORCE_SSL", true) do
    exclude_paths =
      (System.get_env("FORCE_SSL_EXCLUDE_PATHS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :converger, :force_ssl,
      hsts: truthy?.("HSTS", true),
      expires: String.to_integer(System.get_env("HSTS_MAX_AGE") || "31536000"),
      subdomains: truthy?.("HSTS_INCLUDE_SUBDOMAINS", false),
      preload: truthy?.("HSTS_PRELOAD", false),
      exclude: [hosts: ["localhost", "127.0.0.1"], paths: exclude_paths]
  else
    config :converger, :force_ssl, false
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :converger, ConvergerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # HTTP -> HTTPS redirects and HSTS are handled by the FORCE_SSL settings
  # above (ConvergerWeb.Plugs.ForceSSL), not by the endpoint's compile-time
  # `force_ssl` option.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :converger, Converger.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
