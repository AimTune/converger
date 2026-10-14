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

  # Token permissions (ADR-0059).
  plug ConvergerWeb.Plugs.RequirePermission, "write" when action in [:create]
  plug ConvergerWeb.Plugs.RequirePermission, "read" when action in [:index]

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
    description: """
    Forward (default): oldest first, after `watermark` (opaque, or a Protocol v1 integer seq); an \
    invalid watermark starts from the beginning. Backward (`before`, or `direction=backward` for the \
    newest page): the page just before the seq `before`, still oldest first, with `cursor` to pass \
    as `before` for the next older page ("load older messages"). `format=frames` returns the page \
    as Protocol v1 frames (`frames`) instead of `activities`.
    """,
    operation_id: "getActivities",
    parameters: [
      conversation_id: path_id("Conversation id"),
      watermark: query(%OpenApiSpex.Schema{type: :string}, "Resume after this watermark"),
      before:
        query(
          %OpenApiSpex.Schema{type: :integer, minimum: 1},
          "Backward paging: activities with a seq below this one (the previous page's `cursor`)"
        ),
      direction:
        query(
          %OpenApiSpex.Schema{type: :string, enum: ~w(forward backward)},
          "`backward` without `before` starts at the newest activity (default `forward`)"
        ),
      format:
        query(
          %OpenApiSpex.Schema{type: :string, enum: ~w(activities frames)},
          "`frames`: Protocol v1 frames, as the WebSocket delivers them (default `activities`)"
        ),
      userId:
        query(
          %OpenApiSpex.Schema{type: :string},
          "With `format=frames` and a token without `user_id`: the end user whose turns are `from: user`"
        ),
      limit: limit_param()
    ],
    responses:
      with_errors(%{200 => json_schema("A page", ref("ActivitySet"))}, [400, 401, 403, 404])
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
        "reply_to_id" => params["replyToId"],
        "message_type" => params["messageType"],
        "payload" => params["payload"]
      }

      system_attrs = %{
        "sender" => sender(from, claims),
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
         :ok <- authorize_channel(claims, conversation),
         {:ok, direction} <- direction(params),
         {:ok, format} <- format(params) do
      # `?limit=` defaults to :activity_default_limit and is capped at
      # :activity_max_limit (config :converger, :pagination).
      limit = Pagination.clamp_limit(params["limit"], :activity)
      page = page(conversation_id, direction, params, limit)

      conn
      |> put_status(:ok)
      |> put_view(json: ConvergerWeb.ConvergerAPI.ActivityJSON)
      |> render(:activity_set,
        activities: page.activities,
        watermark: page.watermark,
        has_more: page.has_more,
        cursor: page.cursor,
        backward: direction != :forward,
        format: format,
        user_id: claims["user_id"] || params["userId"]
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # `from.id`, else the token's verified end user, so a REST send renders as
  # `from: "user"` for that user as a socket send does (ADR-0065).
  defp sender(%{"id" => id}, _claims) when is_binary(id), do: id
  defp sender(_from, %{"user_id" => user_id}) when is_binary(user_id), do: user_id
  defp sender(_from, _claims), do: "user"

  # Forward: after the watermark, oldest first. An invalid watermark starts
  # from the beginning, as before; the integer seq of Protocol v1 (e.g. from
  # `replayTruncated`) is accepted next to the opaque form.
  defp page(conversation_id, :forward, params, limit) do
    position =
      case ConvergerWeb.Protocol.parse_watermark(params["watermark"]) do
        {:ok, position} -> position
        {:error, _} -> nil
      end

    {activities, has_more} =
      Activities.page_activities_since(conversation_id, position, limit: limit)

    %{
      activities: activities,
      has_more: has_more,
      cursor: nil,
      watermark: watermark(activities, params["watermark"])
    }
  end

  # Backward ("load older messages", ADR-0065): the page before the seq
  # `before` (from the newest activity without it), oldest first. `cursor` is
  # the oldest seq of the page, passed back as `before` for the next one.
  defp page(conversation_id, {:backward, before}, _params, limit) do
    {activities, has_more} =
      Activities.page_recent_activities(conversation_id, limit: limit, before_seq: before)

    cursor =
      case {has_more, activities} do
        {true, [oldest | _]} -> Integer.to_string(oldest.seq)
        _ -> nil
      end

    %{
      activities: activities,
      has_more: has_more,
      cursor: cursor,
      watermark: watermark(activities, nil)
    }
  end

  defp watermark([], fallback), do: fallback
  defp watermark(activities, _fallback), do: Watermark.encode(List.last(activities).seq)

  defp direction(%{"before" => before}) when is_binary(before) and before != "" do
    case Integer.parse(before) do
      {seq, ""} when seq > 0 -> {:ok, {:backward, seq}}
      _ -> {:error, "before must be a positive integer seq"}
    end
  end

  defp direction(%{"direction" => "backward"}), do: {:ok, {:backward, nil}}

  defp direction(%{"direction" => direction}) when direction not in [nil, "", "forward"],
    do: {:error, "direction must be forward or backward"}

  defp direction(_params), do: {:ok, :forward}

  defp format(%{"format" => "frames"}), do: {:ok, :frames}

  defp format(%{"format" => format}) when format not in [nil, "", "activities"],
    do: {:error, "format must be activities or frames"}

  defp format(_params), do: {:ok, :activities}
end
