defmodule ConvergerWeb.ConvergerSocket do
  use Phoenix.Socket

  alias Converger.Auth.ConvergerToken

  channel "converger:*", ConvergerWeb.ConvergerChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case ConvergerToken.verify_token(token) do
      {:ok, claims} ->
        {:ok, assign(socket, :converger_claims, claims)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{converger_claims: %{"channel_id" => channel_id}}}),
    do: "converger_socket:#{channel_id}"

  def id(_socket), do: nil
end
