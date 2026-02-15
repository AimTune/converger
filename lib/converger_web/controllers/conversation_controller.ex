defmodule ConvergerWeb.ConversationController do
  use ConvergerWeb, :controller

  alias Converger.Conversations

  plug ConvergerWeb.Plugs.TenantAuth when action not in [:create]

  action_fallback ConvergerWeb.FallbackController

  def create(conn, conversation_params) do
    # Authenticate via Channel Token
    case get_req_header(conn, "x-channel-token") do
      [token] ->
        case Converger.Auth.Token.verify_token(token) do
          {:ok, %{"channel_id" => channel_id, "tenant_id" => tenant_id}} ->
            {:ok, %Conversations.Conversation{} = conversation} =
              Conversations.create_conversation(
                Map.merge(conversation_params, %{
                  "tenant_id" => tenant_id,
                  "channel_id" => channel_id
                })
              )

            conn
            |> put_status(:created)
            |> render(:show, conversation: conversation)

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
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Invalid channel_id"})
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant
    conversation = Conversations.get_conversation!(id, tenant.id)
    render(conn, :show, conversation: conversation)
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end
end
