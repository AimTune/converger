defmodule ConvergerWeb.Plugs.RequirePermission do
  @moduledoc """
  Requires a permission (`read`, `write`, `typing`) of the Converger token
  (`perms` claim, ADR-0057), after `ConvergerWeb.Plugs.ConvergerAuth`:

      plug ConvergerWeb.Plugs.RequirePermission, "write" when action in [:create]

  A token without the claim has every permission; a request authenticated
  with the channel secret is not restricted. Otherwise 403
  `insufficient_permission`.
  """

  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.APIError

  def init(permission) when is_binary(permission), do: permission

  def call(conn, permission) do
    case conn.assigns do
      %{converger_claims: claims} ->
        if ConvergerToken.permitted?(claims, permission),
          do: conn,
          else: forbidden(conn, permission)

      _ ->
        conn
    end
  end

  defp forbidden(conn, permission) do
    APIError.send_error(
      conn,
      APIError.new(
        :insufficient_permission,
        "The token lacks the #{permission} permission",
        %{"required" => permission}
      )
    )
  end
end
