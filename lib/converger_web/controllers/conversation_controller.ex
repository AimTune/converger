defmodule ConvergerWeb.ConversationController do
  use ConvergerWeb, :controller

  alias Converger.{Conversations, Channels}

  plug ConvergerWeb.Plugs.TenantAuth when action not in [:create]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, conversation_params) do
    with [token] <- get_req_header(conn, "x-channel-token"),
         {:ok, %{"channel_id" => channel_id, "tenant_id" => tenant_id}} <-
           Converger.Auth.Token.verify_token(token),
         {:ok, _channel} <- Channels.get_active_channel(channel_id, tenant_id),
         {:ok, %Conversations.Conversation{} = conversation} <-
           Conversations.create_conversation(
             Map.merge(conversation_params, %{
               "tenant_id" => tenant_id,
               "channel_id" => channel_id
             })
           ) do
      conn
      |> put_status(:created)
      |> render(:show, conversation: conversation)
    else
      [] -> {:error, "Missing x-channel-token header"}
      {:error, :channel_inactive} -> {:error, "Channel is inactive"}
      {:error, _} -> {:error, :unauthorized}
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(id, tenant.id) do
      render(conn, :show, conversation: conversation)
    end
  end
end
