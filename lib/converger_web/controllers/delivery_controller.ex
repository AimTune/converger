defmodule ConvergerWeb.DeliveryController do
  @moduledoc """
  Dead-letter inspection and replay for the tenant API.

    * `GET /api/v1/deliveries` - the tenant's deliveries, most recently
      changed first, keyset-paginated on `(updated_at, id)`. Query params:
      `status`, `channel_id`, `activity_id`, `from`, `to`, `limit`, `cursor`.
    * `POST /api/v1/deliveries/:id/retry` - replay one dead letter.
    * `POST /api/v1/channels/:channel_id/deliveries/retry` - replay the
      channel's dead letters, optionally narrowed by `from`, `to`,
      `activity_id`.

  Server-to-server only: requires the tenant API key (`x-api-key`), since
  deliveries expose every conversation's payloads.
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Channels.Channel
  alias Converger.Deliveries

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  tags(["Deliveries"])
  security([%{"apiKey" => []}])

  @date_time %OpenApiSpex.Schema{type: :string, format: :"date-time"}

  operation(:index,
    summary: "List deliveries",
    description:
      "Most recently changed first, keyset-paginated. `from` / `to` accept ISO 8601 times or dates. Requires the tenant API key.",
    operation_id: "listDeliveries",
    parameters: [
      status: query(ref("DeliveryStatus"), "Filter by status"),
      channel_id: query(%OpenApiSpex.Schema{type: :string, format: :uuid}, "Filter by channel"),
      activity_id: query(%OpenApiSpex.Schema{type: :string, format: :uuid}, "Filter by activity"),
      from: query(@date_time, "Changed at or after"),
      to: query(@date_time, "Changed at or before"),
      limit: limit_param(),
      cursor: query(%OpenApiSpex.Schema{type: :string}, "`meta.next_cursor` of the previous page")
    ],
    responses: with_errors(%{200 => json_schema("A page", ref("DeliveryList"))}, [400, 401, 403])
  )

  operation(:retry,
    summary: "Retry a delivery",
    description: "Replays one dead letter (status `failed`).",
    operation_id: "retryDelivery",
    parameters: [id: path_id("Delivery id")],
    responses:
      with_errors(
        %{202 => json_schema("Re-enqueued", ref("DeliveryResponse"))},
        [400, 401, 403, 404, 409]
      )
  )

  operation(:bulk_retry,
    summary: "Retry a channel's dead letters",
    description:
      "Replays up to `limit` failed deliveries of the channel; call again while `has_more`.",
    operation_id: "retryChannelDeadLetters",
    parameters: [
      channel_id: path_id("Channel id"),
      from: query(@date_time, "Changed at or after"),
      to: query(@date_time, "Changed at or before"),
      activity_id: query(%OpenApiSpex.Schema{type: :string, format: :uuid}, "Only this activity"),
      limit: limit_param()
    ],
    responses:
      with_errors(
        %{202 => json_schema("Re-enqueued", ref("BulkRetryResponse"))},
        [400, 401, 403, 404]
      )
  )

  def index(conn, params) do
    tenant = conn.assigns.tenant

    with :ok <- require_api_key(conn),
         {:ok, filters} <- Deliveries.cast_filters(params),
         {:ok, page} <-
           Deliveries.search_deliveries(Map.put(filters, :tenant_id, tenant.id),
             limit: params["limit"],
             cursor: params["cursor"],
             preload: [:activity]
           ) do
      render(conn, :index,
        deliveries: page.entries,
        meta: %{next_cursor: page.next_cursor, has_more: page.has_more, limit: page.limit}
      )
    else
      {:error, :invalid_cursor} -> {:error, "Invalid cursor"}
      {:error, _} = error -> error
    end
  end

  def retry(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    with :ok <- require_api_key(conn),
         %{} = delivery <- Deliveries.get_tenant_delivery(id, tenant.id),
         {:ok, delivery} <- Deliveries.retry_delivery(delivery, build_actor(conn)) do
      conn
      |> put_status(:accepted)
      |> render(:show, delivery: Converger.Repo.preload(delivery, :activity))
    end
  end

  def bulk_retry(conn, %{"channel_id" => channel_id} = params) do
    tenant = conn.assigns.tenant

    with :ok <- require_api_key(conn),
         {:ok, channel} <- fetch_channel(channel_id, tenant.id),
         {:ok, filters} <- Deliveries.cast_filters(Map.take(params, ~w(from to activity_id))),
         :ok <- require_active(channel),
         {:ok, result} <-
           Deliveries.retry_dead_letters(
             Map.put(filters, :channel_id, channel.id),
             build_actor(conn),
             limit: bulk_limit(params["limit"])
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{data: result})
    end
  end

  defp fetch_channel(id, tenant_id) do
    case Converger.Repo.get_by(Channel, id: id, tenant_id: tenant_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :not_found}
    end
  end

  defp require_active(%{status: "active"}), do: :ok
  defp require_active(_channel), do: {:error, :channel_inactive}

  defp bulk_limit(requested) do
    max = Deliveries.bulk_retry_limit()

    case requested && Integer.parse(to_string(requested)) do
      {n, ""} when n > 0 -> min(n, max)
      _ -> max
    end
  end

  defp require_api_key(conn) do
    if get_req_header(conn, "x-api-key") == [],
      do:
        {:error,
         ConvergerWeb.APIError.new(
           :forbidden,
           "This endpoint requires the tenant API key (x-api-key)"
         )},
      else: :ok
  end

  defp build_actor(conn), do: ConvergerWeb.Plugs.TenantAuth.actor(conn)
end
