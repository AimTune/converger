defmodule ConvergerWeb.WebhookEventController do
  @moduledoc """
  The platform webhook event log of the tenant (ADR-0053), kept for
  `WEBHOOK_EVENT_RETENTION_DAYS` (default 7).

    * `GET /api/v1/webhook_events` - newest first, keyset-paginated on
      `(inserted_at, id)`. Query params: `subscription_id`, `status`
      (`pending`, `delivered`, `failed`), `type`, `limit`, `cursor`.
    * `GET /api/v1/webhook_events/:id` - one event, with its payload
    * `POST /api/v1/webhook_events/:id/redeliver` - send a dead-lettered
      (`failed`) event again; `409` for any other status

  Server-to-server only: requires the tenant API key (`x-api-key`).
  """
  use ConvergerWeb, :controller

  alias Converger.Webhooks
  alias Converger.Webhooks.Event

  plug ConvergerWeb.Plugs.TenantAuth
  plug :require_api_key

  action_fallback ConvergerWeb.FallbackController

  def index(conn, params) do
    with {:ok, filters} <- filters(conn, params),
         {:ok, page} <-
           Webhooks.paginate_events(filters, limit: params["limit"], cursor: params["cursor"]) do
      render(conn, :index,
        events: page.entries,
        meta: %{next_cursor: page.next_cursor, has_more: page.has_more, limit: page.limit}
      )
    else
      {:error, :invalid_cursor} -> {:error, "Invalid cursor"}
      {:error, _} = error -> error
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, event} <- fetch(conn, id) do
      render(conn, :show, event: event)
    end
  end

  def redeliver(conn, %{"webhook_event_id" => id}) do
    with {:ok, event} <- fetch(conn, id) do
      case Webhooks.redeliver(event, build_actor(conn)) do
        {:ok, event} ->
          conn
          |> put_status(:accepted)
          |> render(:show, event: event)

        {:error, :not_failed} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "not_failed", detail: "Only failed events can be redelivered"})
      end
    end
  end

  defp filters(conn, params) do
    with {:ok, subscription_id} <- optional_uuid(params["subscription_id"]),
         {:ok, status} <- optional_status(params["status"]) do
      {:ok,
       %{
         tenant_id: conn.assigns.tenant.id,
         subscription_id: subscription_id,
         status: status,
         type: params["type"]
       }}
    end
  end

  defp optional_uuid(value) when value in [nil, ""], do: {:ok, nil}

  defp optional_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "Invalid subscription_id"}
    end
  end

  defp optional_status(value) when value in [nil, ""], do: {:ok, nil}

  defp optional_status(value) do
    if value in Event.statuses(),
      do: {:ok, value},
      else: {:error, "status must be one of: #{Enum.join(Event.statuses(), ", ")}"}
  end

  defp fetch(conn, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Event{} = event <-
           Converger.Repo.get_by(Event, id: id, tenant_id: conn.assigns.tenant.id) do
      {:ok, event}
    else
      _ -> {:error, :not_found}
    end
  end

  defp require_api_key(conn, _opts) do
    if get_req_header(conn, "x-api-key") == [] do
      conn
      |> ConvergerWeb.FallbackController.call({:error, :forbidden})
      |> halt()
    else
      conn
    end
  end

  defp build_actor(conn), do: %{type: "tenant_api", id: conn.assigns.tenant.id}
end
