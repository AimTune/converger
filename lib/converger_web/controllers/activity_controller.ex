defmodule ConvergerWeb.ActivityController do
  use ConvergerWeb, :controller

  alias Converger.Activities
  alias Converger.Conversations

  plug ConvergerWeb.Plugs.TenantAuth

  # plug ConvergerWeb.Plugs.RateLimit,
  #     [scope: :tenant, key_prefix: "activity_create", limit: 60, scale_ms: 60_000]
  #      when action in [:create]

  action_fallback ConvergerWeb.FallbackController

  def index(conn, %{"conversation_id" => conversation_id}) do
    tenant = conn.assigns.tenant

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, tenant.id) do
      activities = Activities.list_activities_for_conversation(conversation.id)
      render(conn, :index, activities: activities)
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
