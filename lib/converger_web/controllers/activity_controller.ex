defmodule ConvergerWeb.ActivityController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Activities
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Conversations

  plug ConvergerWeb.Plugs.TenantAuth

  plug ConvergerWeb.Plugs.RateLimit,
       [bucket: :activity_create, scope: :tenant]
       when action in [:create]

  action_fallback ConvergerWeb.FallbackController

  tags(["Activities"])
  security([%{"apiKey" => []}, %{"channelToken" => []}])

  operation(:index,
    summary: "List activities",
    description: "Oldest first, paged by watermark.",
    operation_id: "listActivities",
    parameters: [
      conversation_id: path_id("Conversation id"),
      limit: limit_param(),
      watermark:
        query(%OpenApiSpex.Schema{type: :string}, "`meta.watermark` of the previous page")
    ],
    responses: with_errors(%{200 => json_schema("A page", ref("ActivityList"))}, [400, 401, 404])
  )

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

  # `{:error, :invalid_watermark}` is answered 400 `invalid_watermark`.
  defp decode_watermark(watermark), do: Watermark.decode(watermark)

  operation(:create,
    summary: "Post an activity",
    description:
      "The caller names the `sender` (default `user`). Idempotent with `x-idempotency-key`.",
    operation_id: "createActivity",
    parameters: [
      conversation_id: path_id("Conversation id"),
      "x-idempotency-key": idempotency_key()
    ],
    request_body: json_schema("The activity", ref("CreateActivityRequest")),
    responses:
      with_errors(
        %{
          201 =>
            json_schema(
              "Created (or the original, for a repeated idempotency key)",
              ref("ActivityResponse")
            )
        },
        [400, 401, 404, 409, 422, 429, 503]
      )
  )

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
