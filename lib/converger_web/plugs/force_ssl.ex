defmodule ConvergerWeb.Plugs.ForceSSL do
  @moduledoc """
  Runtime-configurable `Plug.SSL`: redirects plain HTTP requests to HTTPS and
  sets the `strict-transport-security` (HSTS) header on HTTPS responses.

  Phoenix's built-in `force_ssl` endpoint option is read at compile time and
  trusts `X-Forwarded-Proto` from any client when `rewrite_on` is set. This
  plug instead reads `:converger, :force_ssl` on every call (configured from
  `FORCE_SSL` and the `HSTS_*` env vars in `config/runtime.exs`) and only
  honours `X-Forwarded-Proto` when the TCP peer is a trusted proxy, i.e. when
  `ConvergerWeb.Plugs.TrustedProxies` has accepted the request's forwarding
  headers (it records the peer in `conn.private[:peer_remote_ip]`). A client
  connecting directly can therefore not claim to be on HTTPS.

  It must run after `ConvergerWeb.Plugs.TrustedProxies`.

  When `:force_ssl` is `nil` or `false` (the default outside production) the
  plug does nothing. Otherwise it is a keyword list of `Plug.SSL` options
  (`:hsts`, `:expires`, `:subdomains`, `:preload`, `:exclude`, `:host`, ...);
  `:rewrite_on` is managed by this plug and any configured value is ignored.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case Keyword.get_lazy(opts, :config, fn -> Application.get_env(:converger, :force_ssl) end) do
      config when config in [nil, false] ->
        conn

      config when is_list(config) ->
        ssl_opts =
          config
          |> Keyword.delete(:rewrite_on)
          |> Keyword.put_new(:host, {ConvergerWeb.Endpoint, :host, []})
          |> maybe_rewrite_on(conn)

        Plug.SSL.call(conn, Plug.SSL.init(ssl_opts))
    end
  end

  defp maybe_rewrite_on(ssl_opts, conn) do
    if trusted_proxy?(conn) do
      Keyword.put(ssl_opts, :rewrite_on, [:x_forwarded_proto])
    else
      ssl_opts
    end
  end

  defp trusted_proxy?(conn), do: Map.has_key?(conn.private, :peer_remote_ip)
end
