defmodule ConvergerWeb.ConvergerAPI.ConversationController do
  use ConvergerWeb, :controller

  alias Converger.{Conversations, Channels, Auth.ConvergerToken}
  import ConvergerWeb.Helpers.Authorization, only: [authorize_conversation: 2]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, _params) do
    claims = conn.assigns.converger_claims
    channel = Channels.get_channel!(claims["channel_id"])

    with {:ok, conversation} <-
           Conversations.create_conversation(%{
             "tenant_id" => channel.tenant_id,
             "channel_id" => channel.id,
             "metadata" => %{"source" => "converger"}
           }),
         {:ok, token, _claims} <-
           ConvergerToken.generate_conversation_token(channel, conversation.id) do
      stream_url = build_stream_url(conn, conversation.id, token)

      conn
      |> put_status(:created)
      |> json(%{
        conversationId: conversation.id,
        token: token,
        expires_in: ConvergerToken.default_expiry(),
        streamUrl: stream_url
      })
    end
  end

  def show(conn, %{"id" => conversation_id} = params) do
    claims = conn.assigns.converger_claims

    with :ok <- authorize_conversation(claims, conversation_id),
         %Conversations.Conversation{} = _conversation <-
           Conversations.get_conversation(conversation_id, claims["tenant_id"]) do
      channel = Channels.get_channel!(claims["channel_id"])

      {:ok, token, _claims} =
        ConvergerToken.generate_conversation_token(channel, conversation_id)

      watermark = params["watermark"]
      stream_url = build_stream_url(conn, conversation_id, token, watermark)

      conn
      |> put_status(:ok)
      |> json(%{
        conversationId: conversation_id,
        token: token,
        expires_in: ConvergerToken.default_expiry(),
        streamUrl: stream_url
      })
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
