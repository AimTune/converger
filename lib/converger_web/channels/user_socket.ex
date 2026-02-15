defmodule ConvergerWeb.UserSocket do
  use Phoenix.Socket

  alias Converger.Auth.Token

  # channels
  channel "conversation:*", ConvergerWeb.ConversationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Token.verify_token(token) do
      {:ok, claims} ->
        {:ok, assign(socket, :claims, claims)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{claims: %{"sub" => user_id}}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
