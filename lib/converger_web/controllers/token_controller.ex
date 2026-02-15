defmodule ConvergerWeb.TokenController do
  use ConvergerWeb, :controller

  alias Converger.Conversations
  alias Converger.Auth.Token

  plug ConvergerWeb.Plugs.RateLimit,
       [scope: :ip, key_prefix: "token_create", limit: 10, scale_ms: 60_000]
       when action in [:create]

  plug ConvergerWeb.Plugs.TenantAuth when action not in [:create]

  def create(conn, %{"conversation_id" => conversation_id, "user_id" => user_id}) do
    # Authenticate via Channel Token
    case Conversations.get_conversation(conversation_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      conversation ->
        conversation = Converger.Repo.preload(conversation, :tenant)

        case get_req_header(conn, "x-channel-token") do
          [token] ->
            # Verify Channel Token
            case Token.verify_token(token) do
              {:ok, %{"channel_id" => channel_id}} ->
                if channel_id == conversation.channel_id do
                  {:ok, token, _claims} =
                    Token.generate_token(conversation, conversation.tenant, user_id)

                  conn
                  |> put_status(:created)
                  |> json(%{token: token, expires_in: 3600})
                else
                  conn
                  |> put_status(:forbidden)
                  |> json(%{error: "Channel Token does not match conversation's channel"})
                end

              {:error, _} ->
                conn
                |> put_status(:unauthorized)
                |> json(%{error: "Invalid Channel Token"})
            end

          _ ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Missing x-channel-token header"})
        end
    end
  end
end
