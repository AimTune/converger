defmodule ConvergerWeb.ConversationController do
  use ConvergerWeb, :controller

  alias Converger.{Conversations, Channels}

  plug ConvergerWeb.Plugs.TenantAuth when action not in [:create]

  action_fallback ConvergerWeb.FallbackController

  @index_limit 100

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

  @doc """
  `GET /api/v1/conversations?external_id=&channel_id=&status=` - the tenant's
  conversations, newest first (at most #{@index_limit}). Server-to-server
  only: requires the tenant API key (`x-api-key`), not a channel token, since
  it exposes other end users' conversations.
  """
  def index(conn, params) do
    with :ok <- require_api_key(conn),
         {:ok, filters} <- index_filters(params) do
      conversations =
        Conversations.search_conversations(conn.assigns.tenant.id, filters, @index_limit)

      render(conn, :index, conversations: conversations)
    end
  end

  defp require_api_key(conn) do
    if get_req_header(conn, "x-api-key") == [], do: {:error, :forbidden}, else: :ok
  end

  defp index_filters(params) do
    filters = Map.take(params, ["external_id", "status", "channel_id"])

    case filters do
      %{"channel_id" => channel_id} ->
        case Ecto.UUID.cast(channel_id) do
          {:ok, _} -> {:ok, filters}
          :error -> {:error, "channel_id must be a UUID"}
        end

      _ ->
        {:ok, filters}
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(id, tenant.id) do
      render(conn, :show, conversation: Converger.Repo.preload(conversation, :participant))
    end
  end
end
