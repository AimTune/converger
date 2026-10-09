defmodule ConvergerWeb.UserSocket do
  @moduledoc """
  The legacy socket (`/socket`, topic `conversation:<id>`). **Deprecated**
  (#23): every connection logs a warning (`ConvergerWeb.Deprecation`).
  Clients move to `ConvergerWeb.ConvergerSocket` (`/socket/converger`), the
  single implementation of the client protocol.
  """

  use Phoenix.Socket
  # Rate, size and join limits, slow-consumer and drain handling.
  use ConvergerWeb.SocketGuard

  alias Converger.Auth.Token

  # channels
  channel "conversation:*", ConvergerWeb.ConversationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Token.verify_conversation_token(token) do
      {:ok, claims} ->
        ConvergerWeb.Deprecation.warn(:legacy_socket,
          tenant_id: claims["tenant_id"],
          conversation_id: claims["conversation_id"]
        )

        {:ok, assign(socket, :claims, claims)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  # Tenant-scoped: the same user id in two tenants is two different users.
  def id(%{assigns: %{claims: claims}}), do: ConvergerWeb.Sockets.user_socket_id(claims)
  def id(_socket), do: nil
end
