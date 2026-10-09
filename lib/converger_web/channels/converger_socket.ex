defmodule ConvergerWeb.ConvergerSocket do
  @moduledoc """
  The client WebSocket (`/socket/converger`), the single implementation of
  the client protocol: receive `activitySet`, send with `postActivity`
  (`ConvergerWeb.ConvergerChannel`). Authenticates with a Converger token
  (`Converger.Auth.ConvergerToken`).
  """

  use Phoenix.Socket

  alias Converger.Auth.ConvergerToken

  channel "converger:*", ConvergerWeb.ConvergerChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # A deactivated channel's sockets are disconnected (ConvergerWeb.Sockets)
    # and must not be able to reconnect with a still-valid token.
    with {:ok, claims} <- ConvergerToken.verify_token(token),
         {:ok, _channel} <-
           Converger.Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]) do
      {:ok, assign(socket, :converger_claims, claims)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Per end user (or conversation), never per channel: a forced disconnect
  # must not drop every client of the channel. See ConvergerWeb.Sockets.
  @impl true
  def id(%{assigns: %{converger_claims: claims}}),
    do: ConvergerWeb.Sockets.converger_socket_id(claims)

  def id(_socket), do: nil
end
