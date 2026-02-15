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

    # Ensure conversation belongs to tenant
    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation!(conversation_id, tenant.id) do
      activities = Activities.list_activities_for_conversation(conversation.id)
      render(conn, :index, activities: activities)
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  def create(conn, %{"conversation_id" => conversation_id} = activity_params) do
    tenant = conn.assigns.tenant

    # Extract idempotency key from headers
    idempotency_key = get_req_header(conn, "x-idempotency-key") |> List.first()

    # Ensure conversation belongs to tenant
    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation!(conversation_id, tenant.id),
         {:ok, %Activities.Activity{} = activity} <-
           Activities.create_activity(
             activity_params
             |> Map.put("tenant_id", tenant.id)
             |> Map.put("conversation_id", conversation.id)
             |> Map.put("idempotency_key", idempotency_key)
             |> Map.put_new("sender", "user")
           ) do
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
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end
end
