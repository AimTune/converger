defmodule ConvergerWeb.Sockets do
  @moduledoc """
  Socket identity and forced disconnects for client WebSockets.

  Every client socket has a per-subject id, `"<prefix>:<tenant_id>:<subject>"`,
  where the subject is the end user from the token (falling back to the
  conversation). Phoenix disconnects every socket with a given id when
  `"disconnect"` is broadcast to it, so the id must never be shared by
  unrelated users.

  Sockets that joined a conversation are also tracked per channel with
  `ConvergerWeb.SocketPresence` (works across nodes), which allows
  `disconnect_channel/1` and `count/1`.
  """

  alias ConvergerWeb.SocketPresence

  # Presence key of a socket without an id (a channel-level token without a
  # user): counted, but it cannot be disconnected by id.
  @anonymous_prefix "anonymous:"

  @doc "Socket id for the Converger API socket (`ConvergerWeb.ConvergerSocket`)."
  def converger_socket_id(%{"tenant_id" => tenant_id} = claims) when is_binary(tenant_id) do
    case subject(claims) do
      nil -> nil
      subject -> "converger_socket:#{tenant_id}:#{subject}"
    end
  end

  def converger_socket_id(_claims), do: nil

  @doc "Socket id for the legacy socket (`ConvergerWeb.UserSocket`)."
  def user_socket_id(%{"tenant_id" => tenant_id, "sub" => sub})
      when is_binary(tenant_id) and is_binary(sub),
      do: "user_socket:#{tenant_id}:#{sub}"

  def user_socket_id(_claims), do: nil

  # End-user id when the token names one, otherwise the channel for a
  # channel-scoped token (agent console), otherwise the conversation.
  # Channel-level tokens without any of them get no id.
  defp subject(%{"user_id" => user_id}) when is_binary(user_id) and user_id != "",
    do: "user:#{user_id}"

  defp subject(%{"scope" => "channel", "channel_id" => channel_id}) when is_binary(channel_id),
    do: "channel:#{channel_id}"

  defp subject(%{"conversation_id" => conversation_id}) when is_binary(conversation_id),
    do: "conversation:#{conversation_id}"

  defp subject(_claims), do: nil

  @doc """
  Disconnect every socket of one end user (or conversation) in a tenant on
  both socket endpoints. Other users of the same channel are unaffected.
  """
  def disconnect_user(tenant_id, user_id) do
    disconnect_id("converger_socket:#{tenant_id}:user:#{user_id}")
    disconnect_id("user_socket:#{tenant_id}:#{user_id}")
    :ok
  end

  @doc "Disconnect every socket of a conversation's token-holders."
  def disconnect_conversation(tenant_id, conversation_id) do
    disconnect_id("converger_socket:#{tenant_id}:conversation:#{conversation_id}")
    :ok
  end

  @doc "Disconnect every tracked socket that joined a conversation of `channel_id`."
  def disconnect_channel(channel_id) do
    channel_id
    |> tracked_ids()
    |> Enum.reject(&String.starts_with?(&1, @anonymous_prefix))
    |> Enum.each(&disconnect_id/1)

    :ok
  end

  @doc "Number of distinct sockets currently joined to conversations of `channel_id`."
  def count(channel_id), do: channel_id |> tracked_ids() |> length()

  @doc """
  Number of joined channel processes of `channel_id` that receive live
  activities of `conversation_id`: sockets joined to that conversation and
  sockets following the whole channel (`scope: "channel"`). Used by the
  `websocket` adapter to tell whether a delivery reached a client.
  """
  def count_connections(channel_id, conversation_id) do
    channel_id
    |> topic()
    |> SocketPresence.list()
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
    |> Enum.count(&(&1[:scope] == "channel" or &1[:conversation_id] == conversation_id))
  end

  @doc """
  Track the calling channel process (a joined channel) under its socket id.
  The entry disappears automatically when the process exits.
  """
  def track(%Phoenix.Socket{id: socket_id}, channel_id, meta) do
    key = socket_id || @anonymous_prefix <> inspect(self())

    case SocketPresence.track(self(), topic(channel_id), key, meta) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _, _, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracked_ids(channel_id) do
    channel_id |> topic() |> SocketPresence.list() |> Map.keys()
  end

  defp topic(channel_id), do: "sockets:channel:#{channel_id}"

  defp disconnect_id(socket_id), do: ConvergerWeb.Endpoint.broadcast(socket_id, "disconnect", %{})
end
