defmodule ConvergerWeb.TokenController do
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas, only: [json_schema: 2, ref: 1, with_errors: 2]

  alias Converger.Conversations
  alias Converger.Auth.Token

  tags(["Tokens (legacy)"])

  plug ConvergerWeb.Plugs.RateLimit,
       [bucket: :token_create, scope: :ip]
       when action in [:create]

  plug ConvergerWeb.Plugs.TenantAuth when action not in [:create]

  action_fallback ConvergerWeb.FallbackController

  operation(:create,
    summary: "Issue a legacy conversation token",
    description:
      "Deprecated (#23): issue Converger tokens with `POST /api/v1/converger/tokens/generate`. Responses carry `Deprecation` and `Link` headers.",
    deprecated: true,
    operation_id: "createLegacyToken",
    security: [%{"channelToken" => []}],
    request_body: json_schema("Conversation and user", ref("LegacyTokenRequest")),
    responses:
      with_errors(%{201 => json_schema("Token issued", ref("LegacyTokenResponse"))}, [
        400,
        401,
        403,
        404,
        429
      ])
  )

  def create(conn, %{"conversation_id" => conversation_id, "user_id" => user_id}) do
    conn = ConvergerWeb.Deprecation.mark(conn, :token_endpoint)

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id),
         conversation = Converger.Repo.preload(conversation, :tenant),
         true <- conversation.tenant.status == "active",
         [token] <- get_req_header(conn, "x-channel-token"),
         {:ok, %{"channel_id" => channel_id}} <- Token.verify_channel_token(token),
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
