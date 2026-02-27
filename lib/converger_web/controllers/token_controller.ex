defmodule ConvergerWeb.TokenController do
  use ConvergerWeb, :controller

  alias Converger.Conversations
  alias Converger.Auth.Token

  plug ConvergerWeb.Plugs.RateLimit,
       [scope: :ip, key_prefix: "token_create", limit: 10, scale_ms: 60_000]
       when action in [:create]

  plug ConvergerWeb.Plugs.TenantAuth when action not in [:create]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"conversation_id" => conversation_id, "user_id" => user_id}) do
    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id),
         conversation = Converger.Repo.preload(conversation, :tenant),
         true <- conversation.tenant.status == "active",
         [token] <- get_req_header(conn, "x-channel-token"),
         {:ok, %{"channel_id" => channel_id}} <- Token.verify_token(token),
         true <- channel_id == conversation.channel_id,
         {:ok, token, _claims} <- Token.generate_token(conversation, conversation.tenant, user_id) do
      conn
      |> put_status(:created)
      |> json(%{token: token, expires_in: 3600})
    else
      nil -> {:error, :not_found}
      [] -> {:error, "Missing x-channel-token header"}
      {:error, _} -> {:error, :unauthorized}
      false -> {:error, :forbidden}
    end
  end
end
