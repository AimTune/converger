defmodule ConvergerWeb.ProtocolSocketController do
  @moduledoc """
  Upgrades `GET /socket/converger/v1` to the native Converger Protocol v1
  WebSocket (`ConvergerWeb.ProtocolSocket`).

  The subprotocol picks the encoding (`ConvergerWeb.Protocol.Codec`); a
  request that offers only unsupported subprotocols is refused with HTTP 400.
  The credential may come from the `Authorization: Bearer` header or the
  `token` query parameter (browsers cannot set headers on a WebSocket), or
  later from `hello.token`. It is checked on `hello`, so a bad credential is
  answered with an `error` frame and close code 4401 as the spec requires.
  """

  use ConvergerWeb, :controller

  alias ConvergerWeb.{Drain, SocketGuard}
  alias ConvergerWeb.Protocol.Codec

  # While the node drains (shutdown), new connections are refused with 503 and
  # Retry-After, as on the Phoenix sockets.
  def upgrade(conn, params) do
    if Drain.draining?() do
      SocketGuard.emit(:draining, ConvergerWeb.ProtocolSocket)
      SocketGuard.handle_error(conn, :draining)
    else
      do_upgrade(conn, params)
    end
  end

  defp do_upgrade(conn, params) do
    case Codec.negotiate(get_req_header(conn, "sec-websocket-protocol")) do
      {:ok, subprotocol, encoding} ->
        conn
        |> maybe_put_subprotocol(subprotocol)
        |> WebSockAdapter.upgrade(
          ConvergerWeb.ProtocolSocket,
          [encoding: encoding, token: credential(conn, params)],
          # The handler enforces the protocol's own idle timeout (close 4408).
          timeout: :infinity,
          # Frames above maxFrameBytes get `payload_too_large`; above this hard
          # cap (shared with the Phoenix sockets) the server closes with 1009.
          max_frame_size: Application.fetch_env!(:converger, :websocket_max_frame_size),
          compress: true
        )
        |> halt()

      {:error, :unsupported_subprotocol} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "unsupported WebSocket subprotocol",
          supported: Codec.subprotocols()
        })
    end
  rescue
    WebSockAdapter.UpgradeError ->
      conn
      |> put_status(:upgrade_required)
      |> put_resp_header("upgrade", "websocket")
      |> json(%{error: "this endpoint only accepts WebSocket upgrades"})
  end

  defp maybe_put_subprotocol(conn, nil), do: conn

  defp maybe_put_subprotocol(conn, subprotocol),
    do: put_resp_header(conn, "sec-websocket-protocol", subprotocol)

  defp credential(conn, params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> if is_binary(params["token"]) and params["token"] != "", do: params["token"]
    end
  end
end
