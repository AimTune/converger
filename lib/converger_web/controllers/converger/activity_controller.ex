defmodule ConvergerWeb.ConvergerAPI.ActivityController do
  use ConvergerWeb, :controller

  alias Converger.{Activities, Conversations}
  alias Converger.ConvergerAPI.Watermark
  import ConvergerWeb.Helpers.Authorization, only: [authorize_conversation: 2]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = _conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]) do
      idempotency_key = get_req_header(conn, "x-idempotency-key") |> List.first()

      from = params["from"] || %{}

      activity_params = %{
        "type" => params["type"] || "message",
        "sender" => from["id"] || "user",
        "text" => params["text"],
        "attachments" => params["attachments"] || [],
        "metadata" => params["channelData"] || params["metadata"] || %{},
        "tenant_id" => claims["tenant_id"],
        "conversation_id" => conversation_id,
        "idempotency_key" => idempotency_key
      }

      case Activities.create_activity(activity_params) do
        {:ok, activity} ->
          conn
          |> put_status(:ok)
          |> put_view(json: ConvergerWeb.ConvergerAPI.ActivityJSON)
          |> render(:resource_response, id: activity.id)

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = _conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]) do
      activities = list_from_watermark(conversation_id, params["watermark"])

      new_watermark =
        case List.last(activities) do
          nil -> params["watermark"]
          last -> Watermark.encode(last.id)
        end

      conn
      |> put_status(:ok)
      |> put_view(json: ConvergerWeb.ConvergerAPI.ActivityJSON)
      |> render(:activity_set, activities: activities, watermark: new_watermark)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp list_from_watermark(conversation_id, nil) do
    Activities.list_activities_for_conversation(conversation_id)
  end

  defp list_from_watermark(conversation_id, watermark) do
    case Watermark.decode(watermark) do
      {:ok, nil} ->
        Activities.list_activities_for_conversation(conversation_id)

      {:ok, activity_id} ->
        Activities.list_activities_after_watermark(conversation_id, activity_id)

      {:error, _} ->
        Activities.list_activities_for_conversation(conversation_id)
    end
  end

end
