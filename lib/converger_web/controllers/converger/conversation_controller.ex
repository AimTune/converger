defmodule ConvergerWeb.ConvergerAPI.ConversationController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.{Conversations, Channels, Auth.ConvergerToken}

  import ConvergerWeb.Helpers.Authorization,
    only: [authorize_channel: 2, authorize_conversation: 2]

  # Token permissions (ADR-0057).
  plug ConvergerWeb.Plugs.RequirePermission, "write" when action in [:create, :close, :reopen]
  plug ConvergerWeb.Plugs.RequirePermission, "read" when action in [:show]

  action_fallback ConvergerWeb.FallbackController

  tags(["Client: Conversations"])
  security([%{"convergerToken" => []}])

  operation(:create,
    summary: "Start a conversation",
    description: "Returns a token bound to the new conversation and its WebSocket `streamUrl`.",
    operation_id: "startConversation",
    responses:
      with_errors(%{201 => json_schema("Started", ref("ClientConversation"))}, [401, 403, 422])
  )

  operation(:show,
    summary: "Reconnect to a conversation",
    description:
      "A fresh conversation-bound token and `streamUrl` (with `watermark` when given).",
    operation_id: "reconnectConversation",
    parameters: [
      id: path_id("Conversation id"),
      watermark:
        query(%OpenApiSpex.Schema{type: :string}, "Resume the stream after this watermark")
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

  def create(conn, _params) do
    claims = conn.assigns.converger_claims
    channel = Channels.get_channel!(claims["channel_id"])

    with {:ok, conversation} <-
           Conversations.create_conversation(%{
             "tenant_id" => channel.tenant_id,
             "channel_id" => channel.id,
             "metadata" => %{"source" => "converger"}
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
