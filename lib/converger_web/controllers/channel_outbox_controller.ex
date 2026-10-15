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
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Channels
  alias Converger.Channels.Outbox
  alias ConvergerWeb.APIError

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  tags(["Channels"])
  security([%{"apiKey" => []}, %{"channelToken" => []}])

  operation(:index,
    summary: "Poll an http_pull channel's outbox",
    description: "Acknowledges up to `watermark`, then returns the next page.",
    operation_id: "pollChannelOutbox",
    parameters: [
      channel_id: path_id("Channel id"),
      watermark: query(%OpenApiSpex.Schema{type: :string}, "Acknowledge up to this watermark"),
      limit: limit_param()
    ],
    responses:
      with_errors(%{200 => json_schema("The next page", ref("OutboxPage"))}, [400, 401, 404, 422])
  )

  operation(:ack,
    summary: "Acknowledge an http_pull channel's outbox",
    operation_id: "ackChannelOutbox",
    parameters: [channel_id: path_id("Channel id")],
    request_body: json_schema("The watermark", ref("OutboxAckRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Acknowledged", ref("OutboxAckResponse"))},
        [400, 401, 404, 422]
      )
  )

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
      {:error, reason} -> {:error, api_error(reason)}
    end
  end

  def ack(conn, %{"channel_id" => id} = params) do
    with {:ok, channel} <- pull_channel(conn, id),
         {:ok, count} <- Outbox.acknowledge(channel, params["watermark"]) do
      json(conn, %{acknowledged: count})
    else
      {:error, reason} -> {:error, api_error(reason)}
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

  defp api_error({:not_pull, type}),
    do:
      APIError.new(
        :unsupported_channel_type,
        "Channel type #{type} has no outbox (only http_pull channels do)"
      )

  defp api_error(:invalid_watermark), do: APIError.new(:invalid_watermark)

  defp api_error(:invalid_limit),
    do: APIError.new(:bad_request, "limit must be an integer from 1 to #{Outbox.max_limit()}")
end
