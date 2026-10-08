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

  @doc """
  `GET /api/v1/conversations` - the tenant's conversations, newest first,
  keyset-paginated on `(inserted_at, id)`, with the participant preloaded.

  Query params: `limit`, `cursor` (from a previous `meta.next_cursor`),
  `status`, `channel_id`, `external_id`. Response: `%{data: [...],
  meta: %{next_cursor, has_more, limit}}`.

  Server-to-server only: requires the tenant API key (`x-api-key`), not a
  channel token, since it exposes other end users' conversations.
  """
  def index(conn, params) do
    tenant = conn.assigns.tenant

    filters =
      params
      |> Map.take(["status", "channel_id", "external_id"])
      |> Map.put("tenant_id", tenant.id)

    with :ok <- require_api_key(conn),
         {:ok, filters} <- validate_uuid_filter(filters, "channel_id"),
         {:ok, page} <-
           Conversations.paginate_conversations(filters,
             limit: params["limit"],
             cursor: params["cursor"],
             preload: [:participant]
           ) do
      render(conn, :index,
        conversations: page.entries,
        meta: %{next_cursor: page.next_cursor, has_more: page.has_more, limit: page.limit}
      )
    else
      {:error, :invalid_cursor} -> {:error, "Invalid cursor"}
      {:error, _} = error -> error
    end
  end

  defp require_api_key(conn) do
    if get_req_header(conn, "x-api-key") == [], do: {:error, :forbidden}, else: :ok
  end

  defp validate_uuid_filter(filters, key) do
    case Map.get(filters, key) do
      value when value in [nil, ""] ->
        {:ok, filters}

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, _} -> {:ok, filters}
          :error -> {:error, "Invalid #{key}"}
        end
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(id, tenant.id) do
      render(conn, :show, conversation: Converger.Repo.preload(conversation, :participant))
    end
  end

  def close(conn, %{"conversation_id" => id}) do
    change_status(conn, id, &Conversations.close_conversation/1)
  end

  def reopen(conn, %{"conversation_id" => id}) do
    change_status(conn, id, &Conversations.reopen_conversation/1)
  end

  defp change_status(conn, id, fun) do
    tenant = conn.assigns.tenant

    with %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(id, tenant.id),
         {:ok, conversation} <- fun.(conversation) do
      render(conn, :show, conversation: conversation)
    end
  end
end
