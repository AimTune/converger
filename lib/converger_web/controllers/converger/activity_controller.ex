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

      client_params = %{
        "type" => params["type"] || "message",
        "text" => params["text"],
        "attachments" => params["attachments"] || [],
        "metadata" => params["channelData"] || params["metadata"] || %{}
      }

      system_attrs = %{
        "sender" => from["id"] || "user",
        "tenant_id" => claims["tenant_id"],
        "conversation_id" => conversation_id,
        "idempotency_key" => idempotency_key
      }

      case Activities.create_client_activity(client_params, system_attrs) do
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
          last -> Watermark.encode(last.seq)
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

  defp list_from_watermark(conversation_id, watermark) do
    case Watermark.decode(watermark) do
      {:ok, position} -> Activities.list_activities_since(conversation_id, position)
      {:error, _} -> Activities.list_activities_for_conversation(conversation_id)
    end
  end
end
