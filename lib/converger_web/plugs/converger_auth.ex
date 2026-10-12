defmodule ConvergerWeb.Plugs.ConvergerAuth do
  import Plug.Conn

  alias Converger.Auth.ConvergerToken
  alias Converger.Channels.Channel
  alias ConvergerWeb.APIError

  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    mode = Keyword.get(opts, :mode, :token)

    case extract_bearer(conn) || query_token(conn, opts) do
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

  # `query_token: true` also accepts `?token=` (Server-Sent Events: a browser
  # EventSource cannot set an Authorization header).
  defp query_token(conn, opts) do
    if Keyword.get(opts, :query_token, false) do
      case Plug.Conn.fetch_query_params(conn).query_params do
        %{"token" => token} when is_binary(token) and token != "" -> token
        _ -> nil
      end
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

        if expired?(reason),
          do: unauthorized(conn, "Token expired", "token_expired"),
          else: unauthorized(conn, "Invalid or expired token")
    end
  end

  # Joken reports a failed claim validation as `[message: _, claim: "exp", ...]`.
  defp expired?(reason) when is_list(reason), do: Keyword.get(reason, :claim) == "exp"
  defp expired?(_reason), do: false

  defp verify_channel_enabled(channel_id) do
    case Converger.Repo.get(Channel, channel_id) do
      %Channel{status: "active"} -> :ok
      _ -> {:error, "Channel not found or inactive"}
    end
  end

  defp find_channel_by_secret(secret) do
    case Converger.Channels.get_channel_by_secret(secret) do
      %Channel{status: "active"} = channel -> {:ok, channel}
      %Channel{} -> {:error, :channel_inactive}
      nil -> {:error, :not_found}
    end
  end

  defp unauthorized(conn, message, code \\ "unauthorized") do
    APIError.send_error(conn, code, message)
  end

  defp forbidden(conn, message) do
    APIError.send_error(conn, APIError.new(:channel_inactive, message, nil, status: 403))
  end
end
