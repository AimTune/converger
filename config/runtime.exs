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

# Configurable CORS origins and admin IP whitelist
if cors_origins = System.get_env("CORS_ORIGINS") do
  config :converger,
    cors_origins: String.split(cors_origins, ",", trim: true)
end

if admin_ips = System.get_env("ADMIN_IP_WHITELIST") do
  config :converger,
    admin_ip_whitelist: String.split(admin_ips, ",", trim: true)
end

# File storage for attachments (see docs/storage.md). Only applied when
# UPLOAD_STORAGE is set, and never in the test environment.
if config_env() != :test and System.get_env("UPLOAD_STORAGE") do
  env = &System.get_env/1
  blank_to_nil = fn v -> if v in [nil, ""], do: nil, else: v end
  truthy? = fn v -> v in ~w(true 1 yes) end

  {storage, storage_opts} =
    case System.get_env("UPLOAD_STORAGE") do
      "local" ->
        {Converger.Uploads.LocalStorage, [dir: env.("UPLOAD_DIR") || "priv/uploads"]}

      s3 when s3 in ["s3", "minio", "r2"] ->
        {Converger.Uploads.S3Storage,
         [
           bucket: System.fetch_env!("S3_BUCKET"),
           access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
           secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
           session_token: blank_to_nil.(env.("S3_SESSION_TOKEN")),
           region: blank_to_nil.(env.("S3_REGION")),
           endpoint: blank_to_nil.(env.("S3_ENDPOINT")),
           path_style:
             truthy?.(env.("S3_PATH_STYLE") || if(s3 == "s3", do: "false", else: "true"))
         ]}

      "gcs" ->
        {Converger.Uploads.GCSStorage,
         [
           bucket: System.fetch_env!("GCS_BUCKET"),
           access_key_id: System.fetch_env!("GCS_HMAC_ACCESS_ID"),
           secret_access_key: System.fetch_env!("GCS_HMAC_SECRET"),
           endpoint: blank_to_nil.(env.("GCS_ENDPOINT"))
         ]}

      "azure" ->
        {Converger.Uploads.AzureBlobStorage,
         [
           account: System.fetch_env!("AZURE_STORAGE_ACCOUNT"),
           account_key: System.fetch_env!("AZURE_STORAGE_KEY"),
           container: System.fetch_env!("AZURE_STORAGE_CONTAINER"),
           endpoint: blank_to_nil.(env.("AZURE_STORAGE_ENDPOINT"))
         ]}

      other ->
        raise "UPLOAD_STORAGE must be one of local, s3, minio, r2, gcs, azure (got #{inspect(other)})"
    end

  cdn =
    case blank_to_nil.(env.("CDN_TYPE")) do
      nil ->
        nil

      "cloudfront" ->
        private_key =
          blank_to_nil.(env.("CLOUDFRONT_PRIVATE_KEY")) ||
            File.read!(System.fetch_env!("CLOUDFRONT_PRIVATE_KEY_FILE"))

        [
          type: :cloudfront,
          base_url: System.fetch_env!("CDN_BASE_URL"),
          path_prefix: env.("CDN_PATH_PREFIX") || "",
          key_pair_id: System.fetch_env!("CLOUDFRONT_KEY_PAIR_ID"),
          private_key: private_key
        ]

      "google_cdn" ->
        [
          type: :google_cdn,
          base_url: System.fetch_env!("CDN_BASE_URL"),
          path_prefix: env.("CDN_PATH_PREFIX") || "",
          key_name: System.fetch_env!("GOOGLE_CDN_KEY_NAME"),
          key: System.fetch_env!("GOOGLE_CDN_KEY")
        ]

      "plain" ->
        [
          type: :plain,
          base_url: System.fetch_env!("CDN_BASE_URL"),
          path_prefix: env.("CDN_PATH_PREFIX") || "",
          sign_origin: truthy?.(env.("CDN_SIGN_ORIGIN"))
        ]

      other ->
        raise "CDN_TYPE must be one of cloudfront, google_cdn, plain (got #{inspect(other)})"
    end

  allowed =
    case blank_to_nil.(env.("UPLOAD_ALLOWED_TYPES")) do
      nil -> nil
      types -> String.split(types, ",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :converger, Converger.Uploads,
    storage: storage,
    storage_opts: Enum.reject(storage_opts, fn {_k, v} -> is_nil(v) end),
    max_file_size: String.to_integer(env.("UPLOAD_MAX_BYTES") || "#{10 * 1024 * 1024}"),
    signed_url_ttl: String.to_integer(env.("UPLOAD_SIGNED_URL_TTL") || "300"),
    allowed_content_types: allowed,
    cdn: cdn
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
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :converger, ConvergerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

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
