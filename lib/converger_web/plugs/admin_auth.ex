defmodule ConvergerWeb.Plugs.AdminAuth do
  @moduledoc """
  Restricts access to the admin interface by client IP.

  The whitelist is read from `:converger, :admin_ip_whitelist` (set at runtime
  from `ADMIN_IP_WHITELIST`) and accepts single addresses as well as CIDR
  ranges, e.g. `["127.0.0.1", "::1", "10.0.0.0/8", "fd00::/8"]`.

  `conn.remote_ip` is the real client address only when the app is reached
  directly or through proxies listed in `TRUSTED_PROXIES`
  (see `ConvergerWeb.Plugs.TrustedProxies`).
  """

  import Plug.Conn
  import Phoenix.Controller

  alias ConvergerWeb.IpMatcher

  def init(opts), do: opts

  def call(conn, _opts) do
    whitelist =
      :converger
      |> Application.get_env(:admin_ip_whitelist, ["127.0.0.1", "::1"])
      |> IpMatcher.parse_list_cached()

    if IpMatcher.member?(conn.remote_ip, whitelist) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> text("Forbidden")
      |> halt()
    end
  end
end
