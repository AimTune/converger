defmodule ConvergerWeb.Plugs.AdminApiAuth do
  @moduledoc """
  Authenticates the platform admin API (`/api/v1/admin`, ADR-0061) with the
  `ADMIN_API_TOKEN` bearer token (`config :converger, :admin_api_token`).

  Runs after `ConvergerWeb.Plugs.AdminAuth`, so the admin IP allowlist
  applies too. Without a configured token the admin API is off: every
  request is `401`. Assigns `:admin_actor` (`%{type: "admin_api", id:
  "admin_api_token"}`), the audit actor.
  """

  import Plug.Conn

  alias ConvergerWeb.APIError

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with expected when is_binary(expected) and expected != "" <- configured_token(),
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(hash(token), hash(expected)) do
      assign(conn, :admin_actor, %{type: "admin_api", id: "admin_api_token"})
    else
      _ ->
        Logger.warning("Admin API authentication failure")
        APIError.send_error(conn, :unauthorized, "Invalid or missing admin API token")
    end
  end

  defp configured_token, do: Application.get_env(:converger, :admin_api_token)

  # Equal-length digests: the comparison leaks neither content nor length.
  defp hash(value), do: :crypto.hash(:sha256, value)
end
