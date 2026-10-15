defmodule ConvergerWeb.WebhookEventController do
  @moduledoc """
  The platform webhook event log of the tenant (ADR-0053), kept for
  `WEBHOOK_EVENT_RETENTION_DAYS` (default 7).

    * `GET /api/v1/webhook_events` - newest first, keyset-paginated on
      `(inserted_at, id)`. Query params: `subscription_id`, `status`
      (`pending`, `delivered`, `failed`), `type`, `limit`, `cursor`.
    * `GET /api/v1/webhook_events/:id` - one event, with its payload
    * `POST /api/v1/webhook_events/:id/redeliver` - send a dead-lettered
      (`failed`) event again; `409 not_failed` for any other status

  Server-to-server only: requires the tenant API key (`x-api-key`). Errors
  use the API error envelope (`ConvergerWeb.APIError`, ADR-0050).
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Webhooks
  alias Converger.Webhooks.Event
  alias ConvergerWeb.APIError

  plug ConvergerWeb.Plugs.TenantAuth
  plug :require_api_key

  action_fallback ConvergerWeb.FallbackController

  tags(["Webhooks"])
  security([%{"apiKey" => []}])

  operation(:index,
    summary: "List webhook events",
    description:
      "The platform webhook event log, newest first, keyset-paginated. Events are kept for `WEBHOOK_EVENT_RETENTION_DAYS` (default 7).",
    operation_id: "listWebhookEvents",
    parameters: [
      subscription_id:
        query(%OpenApiSpex.Schema{type: :string, format: :uuid}, "Filter by subscription"),
      status: query(ref("WebhookEventStatus"), "Filter by status"),
      type: query(%OpenApiSpex.Schema{type: :string}, "Filter by event type"),
      limit: limit_param(),
      cursor: query(%OpenApiSpex.Schema{type: :string}, "`meta.next_cursor` of the previous page")
    ],
    responses:
      with_errors(%{200 => json_schema("A page", ref("WebhookEventList"))}, [400, 401, 403])
  )

  def index(conn, params) do
    with {:ok, filters} <- filters(conn, params),
         {:ok, page} <-
           Webhooks.paginate_events(filters, limit: params["limit"], cursor: params["cursor"]) do
      render(conn, :index,
        events: page.entries,
        meta: %{next_cursor: page.next_cursor, has_more: page.has_more, limit: page.limit}
      )
    end
  end

  operation(:show,
    summary: "Get a webhook event",
    operation_id: "getWebhookEvent",
    parameters: [id: path_id("Webhook event id")],
    responses:
      with_errors(%{200 => json_schema("The event", ref("WebhookEventResponse"))}, [
        401,
        403,
        404
      ])
  )

  def show(conn, %{"id" => id}) do
    with {:ok, event} <- fetch(conn, id) do
      render(conn, :show, event: event)
    end
  end

  operation(:redeliver,
    summary: "Redeliver a webhook event",
    description:
      "Sends a dead-lettered (`failed`) event again, with the same `event_id`. `409 not_failed` for any other status.",
    operation_id: "redeliverWebhookEvent",
    parameters: [webhook_event_id: path_id("Webhook event id")],
    responses:
      with_errors(
        %{202 => json_schema("Sent again", ref("WebhookEventResponse"))},
        [401, 403, 404, 409]
      )
  )

  def redeliver(conn, %{"webhook_event_id" => id}) do
    with {:ok, event} <- fetch(conn, id) do
      case Webhooks.redeliver(event, build_actor(conn)) do
        {:ok, event} ->
          conn
          |> put_status(:accepted)
          |> render(:show, event: event)

        {:error, :not_failed} ->
          {:error, APIError.new(:not_failed, "Only failed events can be redelivered")}
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
    if get_req_header(conn, "x-api-key") == [],
      do:
        APIError.send_error(
          conn,
          :forbidden,
          "This endpoint requires the tenant API key (x-api-key)"
        ),
      else: conn
  end

  defp build_actor(conn), do: ConvergerWeb.Plugs.TenantAuth.actor(conn)
end
