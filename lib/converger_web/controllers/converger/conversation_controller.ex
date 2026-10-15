defmodule ConvergerWeb.ConvergerAPI.ConversationController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.{Activities, Conversations, Channels, Auth.ConvergerToken}
  alias Converger.Conversations.Conversation
  alias ConvergerWeb.APIError

  import ConvergerWeb.Helpers.Authorization,
    only: [authorize_channel: 2, authorize_conversation: 2]

  # Token permissions (ADR-0059).
  plug ConvergerWeb.Plugs.RequirePermission, "write" when action in [:create, :close, :reopen]
  plug ConvergerWeb.Plugs.RequirePermission, "read" when action in [:show, :index]

  @max_title_length 200

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Conversations"])
  security([%{"convergerToken" => []}])

  operation(:create,
    summary: "Start a conversation",
    description:
      "Returns a token bound to the new conversation and its WebSocket `streamUrl`. An optional `title` is stored as `metadata.title`.",
    operation_id: "startConversation",
    request_body: json_schema("Optional", ref("ClientConversationRequest")),
    responses:
      with_errors(
        %{201 => json_schema("Started", ref("ClientConversation"))},
        [400, 401, 403, 422]
      )
  )

  operation(:index,
    summary: "List the channel's conversations",
    description: """
    The conversations of the token's channel, most recently active first (`updatedAt`, bumped by     every activity), keyset-paginated: pass `cursor` back for the next page. For agent consoles,     such as chativa's agent-panel mode (ADR-0065). Needs a `scope: channel` token     (`POST /tokens/generate` with `{"scope": "channel"}`); other tokens get 403.
    """,
    operation_id: "clientListConversations",
    parameters: [
      limit: limit_param(),
      cursor: query(%OpenApiSpex.Schema{type: :string}, "`cursor` of the previous page"),
      status:
        query(%OpenApiSpex.Schema{type: :string, enum: ~w(active closed)}, "Filter by status"),
      updated_since:
        query(
          %OpenApiSpex.Schema{type: :string},
          "Only conversations active at or after this time (ISO 8601, or milliseconds since the epoch)"
        )
    ],
    responses:
      with_errors(
        %{200 => json_schema("A page", ref("ClientConversationList"))},
        [400, 401, 403]
      )
  )

  operation(:show,
    summary: "Reconnect to a conversation",
    description:
      "A fresh conversation-bound token and `streamUrl` (with `watermark` when given).",
    operation_id: "reconnectConversation",
    parameters: [
      id: path_id("Conversation id"),
      watermark: query(watermark_param_schema(), "Resume the stream after this watermark")
    ],
    responses:
      with_errors(%{200 => json_schema("Reconnected", ref("ClientConversation"))}, [401, 403, 404])
  )

  operation(:close,
    summary: "Close a conversation",
    operation_id: "clientCloseConversation",
    parameters: [id: path_id("Conversation id")],
    responses:
      with_errors(
        %{200 => json_schema("Closed", ref("ClientConversationStatus"))},
        [401, 403, 404]
      )
  )

  operation(:reopen,
    summary: "Reopen a conversation",
    operation_id: "clientReopenConversation",
    parameters: [id: path_id("Conversation id")],
    responses:
      with_errors(
        %{200 => json_schema("Reopened", ref("ClientConversationStatus"))},
        [401, 403, 404]
      )
  )

  def create(conn, params) do
    claims = conn.assigns.converger_claims
    channel = Channels.get_channel!(claims["channel_id"])

    with {:ok, metadata} <- creation_metadata(params),
         {:ok, conversation} <-
           Conversations.create_conversation(%{
             "tenant_id" => channel.tenant_id,
             "channel_id" => channel.id,
             "metadata" => metadata
           }),
         {:ok, token, token_claims} <-
           ConvergerToken.generate_conversation_token(
             channel,
             conversation.id,
             ConvergerToken.derived_opts(claims)
           ) do
      stream_url = build_stream_url(conn, conversation.id, token)

      conn
      |> put_status(:created)
      |> json(%{
        conversationId: conversation.id,
        token: token,
        expires_in: max(token_claims["exp"] - Joken.current_time(), 0),
        streamUrl: stream_url
      })
    end
  end

  # chativa's createConversation(title) (ADR-0065): the title is metadata.
  defp creation_metadata(params) do
    case params["title"] do
      nil ->
        {:ok, %{"source" => "converger"}}

      title when is_binary(title) and byte_size(title) <= @max_title_length ->
        {:ok, %{"source" => "converger", "title" => title}}

      _ ->
        {:error, "title must be a string of at most #{@max_title_length} bytes"}
    end
  end

  @doc """
  `GET /api/v1/converger/conversations`: the channel's conversations for a
  channel-scoped token (agent consoles, ADR-0065), most recently active
  first, keyset-paginated on `(updated_at, id)`, each with a preview of its
  latest message.
  """
  def index(conn, params) do
    claims = conn.assigns.converger_claims

    with :ok <- require_channel_scope(claims),
         {:ok, filters} <- list_filters(claims, params),
         {:ok, page} <-
           Conversations.paginate_conversations(filters,
             limit: params["limit"],
             cursor: params["cursor"],
             field: :updated_at,
             preload: [:participant]
           ) do
      previews = Activities.last_messages(Enum.map(page.entries, & &1.id))

      json(conn, %{
        conversations: Enum.map(page.entries, &list_item(&1, previews[&1.id])),
        cursor: page.next_cursor,
        has_more: page.has_more
      })
    else
      {:error, :invalid_cursor} -> {:error, "Invalid cursor"}
      {:error, _} = error -> error
    end
  end

  defp require_channel_scope(%{"scope" => "channel"}), do: :ok

  defp require_channel_scope(_claims) do
    {:error,
     APIError.new(
       :forbidden,
       "Listing conversations needs a channel-scoped token (tokens/generate with scope: channel)"
     )}
  end

  defp list_filters(claims, params) do
    filters = %{"tenant_id" => claims["tenant_id"], "channel_id" => claims["channel_id"]}

    with {:ok, filters} <- put_status_filter(filters, params["status"]) do
      put_since_filter(filters, params["updated_since"])
    end
  end

  defp put_status_filter(filters, status) when status in [nil, ""], do: {:ok, filters}

  defp put_status_filter(filters, status) when status in ["active", "closed"],
    do: {:ok, Map.put(filters, "status", status)}

  defp put_status_filter(_filters, _status), do: {:error, "status must be active or closed"}

  defp put_since_filter(filters, since) when since in [nil, ""], do: {:ok, filters}

  defp put_since_filter(filters, since) when is_binary(since) do
    case parse_time(since) do
      {:ok, datetime} -> {:ok, Map.put(filters, "updated_since", datetime)}
      :error -> {:error, "updated_since must be an ISO 8601 time or milliseconds since the epoch"}
    end
  end

  defp put_since_filter(_filters, _since),
    do: {:error, "updated_since must be an ISO 8601 time or milliseconds since the epoch"}

  defp parse_time(value) do
    with :error <- parse_ms(Integer.parse(value)),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      {:ok, %DateTime{} = datetime} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_ms({ms, ""}), do: DateTime.from_unix(ms, :millisecond)
  defp parse_ms(_), do: :error

  # Field names follow chativa's Conversation entity where one exists
  # (`title`, `contact`, `lastMessage`, `lastMessageAt` in milliseconds).
  defp list_item(%Conversation{} = conversation, preview) do
    metadata = conversation.metadata || %{}
    contact = contact(conversation.participant)

    %{
      id: conversation.id,
      title: metadata["title"] || contact,
      contact: contact,
      status: conversation.status,
      lastMessage: preview_text(preview),
      lastMessageAt: preview && ConvergerWeb.Protocol.to_ms(preview.inserted_at),
      lastSeq: conversation.last_seq,
      metadata: metadata,
      createdAt: conversation.inserted_at,
      updatedAt: conversation.updated_at
    }
  end

  defp contact(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp contact(%{external_id: id}) when is_binary(id), do: id
  defp contact(_participant), do: nil

  defp preview_text(%{deleted_at: nil, text: text}) when is_binary(text), do: text
  defp preview_text(_preview), do: nil

  def show(conn, %{"id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]),
         :ok <- authorize_channel(claims, conversation) do
      channel = Channels.get_channel!(claims["channel_id"])

      # Derived from the presented token: same family and permissions, and
      # never outliving it (only a refresh, which rotates, extends a session).
      {:ok, token, token_claims} =
        ConvergerToken.generate_conversation_token(
          channel,
          conversation_id,
          ConvergerToken.derived_opts(claims)
        )

      watermark = params["watermark"]
      stream_url = build_stream_url(conn, conversation_id, token, watermark)

      conn
      |> put_status(:ok)
      |> json(%{
        conversationId: conversation_id,
        token: token,
        expires_in: max(token_claims["exp"] - Joken.current_time(), 0),
        streamUrl: stream_url
      })
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "POST /conversations/:id/close"
  def close(conn, %{"id" => conversation_id}) do
    change_status(conn, conversation_id, &Conversations.close_conversation/1)
  end

  @doc "POST /conversations/:id/reopen"
  def reopen(conn, %{"id" => conversation_id}) do
    change_status(conn, conversation_id, &Conversations.reopen_conversation/1)
  end

  defp change_status(conn, conversation_id, fun) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]),
         :ok <- authorize_channel(claims, conversation),
         {:ok, conversation} <- fun.(conversation) do
      conn
      |> put_status(:ok)
      |> json(%{conversationId: conversation.id, status: conversation.status})
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp build_stream_url(conn, conversation_id, token, watermark \\ nil) do
    scheme = if conn.scheme == :https, do: "wss", else: "ws"
    host = conn.host
    port = conn.port

    base =
      "#{scheme}://#{host}:#{port}/socket/converger/websocket" <>
        "?token=#{token}&conversation_id=#{conversation_id}"

    if watermark, do: base <> "&watermark=#{watermark}", else: base
  end
end
