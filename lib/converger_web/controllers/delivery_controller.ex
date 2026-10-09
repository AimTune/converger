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

  alias Converger.Channels.Channel
  alias Converger.Deliveries

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

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
    else
      {:error, :not_failed} -> not_failed(conn)
      other -> other
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

  defp not_failed(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "not_failed", detail: "Only failed deliveries can be retried"})
  end

  defp require_api_key(conn) do
    if get_req_header(conn, "x-api-key") == [], do: {:error, :forbidden}, else: :ok
  end

  defp build_actor(conn), do: %{type: "tenant_api", id: conn.assigns.tenant.id}
end
