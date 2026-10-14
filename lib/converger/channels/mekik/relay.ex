defmodule Converger.Channels.Mekik.Relay do
  @moduledoc """
  The end-user side of the `mekik` channel adapter's bot relay (ADR-0066),
  one per node.

  `ConvergerWeb.Protocol.BotRelay` broadcasts on the channel topic
  (`"channel:<channel id>"`) of a conversation's bot channels:

    * `bot_frame` - an end user's bot-only frame (`resume`, `genui_event`,
      `abort`, ...): forwarded upstream on the conversation's connection
      (`Converger.Channels.Mekik.Connections.forward/3`). The node that runs
      the connection forwards it; when none runs anywhere, the node chosen by
      rendezvous hashing of the conversation over the connected nodes starts
      one;
    * `turn_meta` - a user turn's mekik/1 `meta`, ahead of the turn: kept in
      an ETS table (on every node, for `meta_ttl_ms`), and taken by the
      delivery of that turn (`take_meta/2`).

  The relay subscribes to the topics of the active `mekik` channels: those
  found by a scan (shortly after boot, then every `relay_scan_interval_ms`)
  and every channel a delivery touches (`watch/1`, which tells the relays
  of all nodes).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Converger.Channels
  alias Converger.Channels.Adapters.Mekik
  alias Converger.Channels.Channel
  alias Converger.Channels.Mekik.Connections
  alias Converger.Repo
  alias ConvergerWeb.Protocol.BotRelay

  @table __MODULE__
  @topic "mekik:relay"
  @meta_ttl_ms 60_000
  @prune_interval_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Make sure the relays of every node follow the bot frames of `channel_id`.
  Returns once this node's relay does.
  """
  @spec watch(String.t()) :: :ok
  def watch(channel_id) do
    if watching?(channel_id) do
      :ok
    else
      Phoenix.PubSub.broadcast_from(Converger.PubSub, self(), @topic, {:watch, channel_id})
      GenServer.call(__MODULE__, {:watch, channel_id})
    end
  end

  @doc "Whether this node's relay follows the bot frames of `channel_id`."
  def watching?(channel_id), do: :ets.member(@table, {:watch, channel_id})

  @doc """
  Take the mekik/1 `meta` relayed ahead of the user turn with idempotency
  key `key` in `conversation_id`, or `nil`.
  """
  @spec take_meta(String.t(), String.t() | nil) :: map() | nil
  def take_meta(_conversation_id, nil), do: nil

  def take_meta(conversation_id, key) do
    case pop_meta(conversation_id, key) do
      nil ->
        # The broadcast may still be in the relay's mailbox.
        :ok = GenServer.call(__MODULE__, :sync)
        pop_meta(conversation_id, key)

      meta ->
        meta
    end
  end

  defp pop_meta(conversation_id, key) do
    now = System.monotonic_time(:millisecond)

    case :ets.take(@table, {:meta, conversation_id, key}) do
      [{_key, meta, expires}] when expires >= now -> meta
      _ -> nil
    end
  end

  ## Server

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Converger.PubSub, @topic)
    Process.send_after(self(), :prune, @prune_interval_ms)

    case Keyword.get_lazy(opts, :scan_interval_ms, fn ->
           Mekik.setting(:relay_scan_interval_ms)
         end) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :scan, Keyword.get(opts, :initial_scan_ms, 2_000))
        {:ok, %{scan_interval: interval}}

      _ ->
        {:ok, %{scan_interval: nil}}
    end
  end

  @impl true
  def handle_call({:watch, channel_id}, _from, state) do
    subscribe(channel_id)
    {:reply, :ok, state}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:watch, channel_id}, state) do
    subscribe(channel_id)
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "turn_meta", payload: payload},
        state
      ) do
    %{conversation_id: conversation_id, key: key, meta: meta} = payload
    expires = System.monotonic_time(:millisecond) + @meta_ttl_ms
    :ets.insert(@table, {{:meta, conversation_id, key}, meta, expires})
    {:noreply, state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "channel:" <> channel_id,
          event: "bot_frame",
          payload: payload
        },
        state
      ) do
    %{conversation_id: conversation_id, frame: frame} = payload
    route(channel_id, conversation_id, frame)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{{:meta, :_, :_}, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:noreply, state}
  end

  def handle_info(:scan, state) do
    scan()
    Process.send_after(self(), :scan, state.scan_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe(channel_id) do
    if :ets.insert_new(@table, {{:watch, channel_id}}) do
      Phoenix.PubSub.subscribe(Converger.PubSub, BotRelay.channel_topic(channel_id))
    end

    :ok
  end

  defp scan do
    from(c in Channel, where: c.type == ^Mekik.type() and c.status == "active", select: c.id)
    |> Repo.all()
    |> Enum.each(&subscribe/1)
  rescue
    error ->
      Logger.warning("mekik relay could not list the mekik channels: #{Exception.message(error)}")
  end

  defp route(channel_id, conversation_id, frame) do
    case Connections.whereis(channel_id, conversation_id) do
      pid when is_pid(pid) and node(pid) == node() ->
        Converger.Channels.Mekik.Connection.forward(pid, frame)

      # The relay of the connection's node forwards it.
      pid when is_pid(pid) ->
        :ok

      nil ->
        if owner?(conversation_id), do: start_and_forward(channel_id, conversation_id, frame)
    end
  end

  defp start_and_forward(channel_id, conversation_id, frame) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id),
         true <- channel.type == Mekik.type() do
      case Connections.forward(channel, conversation_id, frame) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("mekik relay could not open a connection: #{inspect(reason)}",
            channel_id: channel_id,
            conversation_id: conversation_id
          )
      end
    end
  end

  # Rendezvous hashing: the node with the highest hash starts the connection.
  defp owner?(conversation_id) do
    Enum.max_by([node() | Node.list()], &:erlang.phash2({&1, conversation_id})) == node()
  end
end
