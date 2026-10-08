defmodule ConvergerWeb.ActivityController do
  use ConvergerWeb, :controller

  alias Converger.Activities
  alias Converger.Conversations
  alias Converger.ConvergerAPI.Watermark

  plug ConvergerWeb.Plugs.TenantAuth

  # plug ConvergerWeb.Plugs.RateLimit,
  #     [scope: :tenant, key_prefix: "activity_create", limit: 60, scale_ms: 60_000]
  #      when action in [:create]

  action_fallback ConvergerWeb.FallbackController

  @doc """
  One page of a conversation's activities, oldest first.

  Query params: `limit` (default/max from `config :converger, :pagination`)
  and `watermark` (opaque, from a previous response's `meta.watermark`).
  The response is `%{data: [...], meta: %{watermark, has_more, limit}}`.
  """
  def index(conn, %{"conversation_id" => conversation_id} = params) do
    tenant = conn.assigns.tenant

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, tenant.id),
         {:ok, position} <- decode_watermark(params["watermark"]) do
      limit = Converger.Pagination.clamp_limit(params["limit"], :activity)

      {activities, has_more} =
        Activities.page_activities_since(conversation.id, position, limit: limit)

      watermark =
        case List.last(activities) do
          nil -> params["watermark"]
          last -> Watermark.encode(last.seq)
        end

      render(conn, :index,
        activities: activities,
        meta: %{watermark: watermark, has_more: has_more, limit: limit}
      )
    end
  end

  defp decode_watermark(watermark) do
    case Watermark.decode(watermark) do
      {:ok, position} -> {:ok, position}
      {:error, :invalid_watermark} -> {:error, "Invalid watermark"}
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = activity_params) do
    tenant = conn.assigns.tenant

    # Extract idempotency key from headers
    idempotency_key = get_req_header(conn, "x-idempotency-key") |> List.first()

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, tenant.id),
         {:ok, %Activities.Activity{} = activity} <-
           Activities.create_client_activity(activity_params, %{
             tenant_id: tenant.id,
             conversation_id: conversation.id,
             idempotency_key: idempotency_key,
             # Server-to-server API (tenant API key): the caller names the sender.
             sender: sender(activity_params)
           }) do
      require Logger

      Logger.info("Activity created",
        tenant_id: tenant.id,
        conversation_id: conversation_id,
        activity_id: activity.id
      )

      conn
      |> put_status(:created)
      |> render(:show, activity: activity)
    end
  end

  defp sender(%{"sender" => sender}) when is_binary(sender) and sender != "", do: sender
  defp sender(_params), do: "user"
end
