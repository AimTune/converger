defmodule ConvergerWeb.ConvergerAPI.ActivityController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.{Activities, Conversations}
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination

  import ConvergerWeb.Helpers.Authorization,
    only: [authorize_channel: 2, authorize_conversation: 2]

  plug ConvergerWeb.Plugs.RateLimit,
       [bucket: :activity_create, scope: :tenant]
       when action in [:create]

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Activities"])
  security([%{"convergerToken" => []}])

  operation(:create,
    summary: "Post an activity",
    description: "Idempotent with `x-idempotency-key`.",
    operation_id: "postActivity",
    parameters: [
      conversation_id: path_id("Conversation id"),
      "x-idempotency-key": idempotency_key()
    ],
    request_body: json_schema("The activity", ref("ClientActivityRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Accepted", ref("ResourceResponse"))},
        [401, 403, 404, 409, 422, 429, 503]
      )
  )

  operation(:index,
    summary: "List activities",
    description:
      "Oldest first, after `watermark` (opaque, or a Protocol v1 integer seq). An invalid watermark starts from the beginning.",
    operation_id: "getActivities",
    parameters: [
      conversation_id: path_id("Conversation id"),
      watermark: query(%OpenApiSpex.Schema{type: :string}, "Resume after this watermark"),
      limit: limit_param()
    ],
    responses: with_errors(%{200 => json_schema("A page", ref("ActivitySet"))}, [401, 403, 404])
  )

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
        "metadata" => params["channelData"] || params["metadata"] || %{},
        "reply_to_id" => params["replyToId"]
      }

      system_attrs = %{
        "sender" => from["id"] || "user",
        "tenant_id" => claims["tenant_id"],
        "conversation_id" => conversation_id,
        "idempotency_key" => idempotency_key,
        "source_channel_id" => claims["channel_id"]
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
      # watermark starts from the beginning, as before. The integer seq of
      # Protocol v1 (e.g. from `replayTruncated`) is accepted next to the
      # opaque form.
      limit = Pagination.clamp_limit(params["limit"], :activity)

      position =
        case ConvergerWeb.Protocol.parse_watermark(params["watermark"]) do
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
