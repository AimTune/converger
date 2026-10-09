defmodule ConvergerWeb.ConvergerAPI.ActivityController do
  use ConvergerWeb, :controller

  alias Converger.{Activities, Conversations}
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination

  import ConvergerWeb.Helpers.Authorization,
    only: [authorize_channel: 2, authorize_conversation: 2]

  plug ConvergerWeb.Plugs.RateLimit,
       [bucket: :activity_create, scope: :tenant]
       when action in [:create]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]),
         :ok <- authorize_channel(claims, conversation) do
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
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]),
         :ok <- authorize_channel(claims, conversation) do
      # `?limit=` defaults to :activity_default_limit and is capped at
      # :activity_max_limit (config :converger, :pagination). An invalid
      # watermark starts from the beginning, as before.
      limit = Pagination.clamp_limit(params["limit"], :activity)

      position =
        case Watermark.decode(params["watermark"]) do
          {:ok, position} -> position
          {:error, _} -> nil
        end

      {activities, has_more} =
        Activities.page_activities_since(conversation_id, position, limit: limit)

      new_watermark =
        case List.last(activities) do
          nil -> params["watermark"]
          last -> Watermark.encode(last.seq)
        end

      conn
      |> put_status(:ok)
      |> put_view(json: ConvergerWeb.ConvergerAPI.ActivityJSON)
      |> render(:activity_set,
        activities: activities,
        watermark: new_watermark,
        has_more: has_more
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end
end
