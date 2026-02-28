defmodule ConvergerWeb.Plugs.ConvergerAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.Channel

  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    mode = Keyword.get(opts, :mode, :token)

    case extract_bearer(conn) do
      nil -> unauthorized(conn, "Missing or malformed Authorization header")
      bearer -> authenticate(conn, bearer, mode)
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp authenticate(conn, bearer, :secret) do
    case find_channel_by_secret(bearer) do
      {:ok, channel} ->
        conn
        |> assign(:channel, channel)
        |> assign(:auth_mode, :secret)

      {:error, _} ->
        authenticate(conn, bearer, :token)
    end
  end

  defp authenticate(conn, bearer, :token) do
    case ConvergerToken.verify_token(bearer) do
      {:ok, claims} ->
        case verify_channel_enabled(claims["channel_id"]) do
          :ok ->
            conn
            |> assign(:converger_claims, claims)
            |> assign(:auth_mode, :token)

          {:error, message} ->
            forbidden(conn, message)
        end

      {:error, reason} ->
        Logger.warning("Converger token verification failed: #{inspect(reason)}")
        unauthorized(conn, "Invalid or expired token")
    end
  end

  defp verify_channel_enabled(channel_id) do
    case Converger.Repo.get(Channel, channel_id) do
      %Channel{status: "active"} -> :ok
      _ -> {:error, "Channel not found or inactive"}
    end
  end

  defp find_channel_by_secret(secret) do
    case Converger.Repo.get_by(Channel, secret: secret) do
      %Channel{status: "active"} = channel -> {:ok, channel}
      %Channel{} -> {:error, :channel_inactive}
      nil -> {:error, :not_found}
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "Unauthorized", message: message}})
    |> halt()
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "Forbidden", message: message}})
    |> halt()
  end
end
