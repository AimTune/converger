defmodule ConvergerWeb.ChannelOutboxController do
  @moduledoc """
  The outbox of an `http_pull` channel, polled by the integrator with the
  tenant API key (`x-api-key`), like the other channel APIs:

    * `GET /api/v1/channels/:channel_id/outbox?watermark=&limit=` -
      acknowledges up to `watermark` and returns the next page;
    * `POST /api/v1/channels/:channel_id/outbox/ack` with `{"watermark"}` -
      acknowledges without fetching.

  See `Converger.Channels.Outbox` and `docs/channels/http-pull.md`.
  """
  use ConvergerWeb, :controller

  alias Converger.Channels
  alias Converger.Channels.Outbox

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  def index(conn, %{"channel_id" => id} = params) do
    with {:ok, channel} <- pull_channel(conn, id),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, page} <- Outbox.poll(channel, params["watermark"], limit) do
      json(conn, %{
        data: page.items,
        watermark: page.watermark,
        has_more: page.has_more,
        acknowledged: page.acknowledged
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def ack(conn, %{"channel_id" => id} = params) do
    with {:ok, channel} <- pull_channel(conn, id),
         {:ok, count} <- Outbox.acknowledge(channel, params["watermark"]) do
      json(conn, %{acknowledged: count})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp pull_channel(conn, id) do
    channel = Channels.get_channel!(id, conn.assigns.tenant.id)

    if channel.type == "http_pull",
      do: {:ok, channel},
      else: {:error, {:not_pull, channel.type}}
  end

  defp limit(nil), do: {:ok, Outbox.default_limit()}

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 1 -> {:ok, min(n, Outbox.max_limit())}
      _ -> {:error, :invalid_limit}
    end
  end

  defp error(conn, {:not_pull, type}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Channel type #{type} has no outbox (only http_pull channels do)"})
  end

  defp error(conn, :invalid_watermark) do
    conn |> put_status(:bad_request) |> json(%{error: "Invalid watermark"})
  end

  defp error(conn, :invalid_limit) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "limit must be an integer from 1 to #{Outbox.max_limit()}"})
  end
end
