defmodule Converger.Channels.Mekik.Connections do
  @moduledoc """
  The `DynamicSupervisor` of the upstream mekik/1 connections of `mekik`
  channels (`Converger.Channels.Mekik.Connection`, one per mekik channel and
  Converger conversation, ADR-0066), and the functions to find, start and
  talk to them.

  A connection is registered globally as `{Converger.Channels.Mekik.Connection,
  channel_id, conversation_id}` (`:global`), so a conversation has at most one
  upstream connection per mekik channel in the cluster, and locally in
  `Converger.Channels.Mekik.Registry` under `{channel_id, conversation_id}`.

  Connections start lazily: on the first delivery of a user turn to the
  channel (`deliver/4`), or when an end user's bot-only frame (`resume`,
  `genui_event`, ...) is routed to it by `Converger.Channels.Mekik.Relay`.
  They stop by themselves after the channel's `idle_timeout_seconds` without
  traffic, and are restarted (with a resume from the recorded watermark)
  when they crash.
  """

  use DynamicSupervisor

  alias Converger.Channels.Mekik.Connection

  @registry Converger.Channels.Mekik.Registry

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "The children of the application supervisor: the registry and this supervisor."
  def child_specs, do: [{Registry, keys: :unique, name: @registry}, __MODULE__]

  @doc "The local registry of the connections."
  def registry, do: @registry

  @doc "The connection of `channel_id` in `conversation_id`, anywhere in the cluster, or nil."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(channel_id, conversation_id) do
    case :global.whereis_name(Connection.global_key(channel_id, conversation_id)) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  @doc """
  The running connection of `channel` in `conversation_id`, started on this
  node when there is none in the cluster. Options are passed to
  `Converger.Channels.Mekik.Connection.start_link/1` (`:idle_timeout_ms`).
  """
  @spec ensure(map(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure(channel, conversation_id, opts \\ []) do
    case whereis(channel.id, conversation_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        spec =
          {Connection, Keyword.merge(opts, channel: channel, conversation_id: conversation_id)}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Send `frame` upstream on the connection of `channel` in `conversation_id`
  (started if needed) and wait until it is written to the socket. Returns
  `{:ok, info}` or `{:error, reason}`.
  """
  @spec deliver(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver(channel, conversation_id, frame, opts \\ []) do
    with {:ok, pid} <- ensure(channel, conversation_id, opts) do
      Connection.send_frame(pid, channel, frame)
    end
  end

  @doc """
  Forward an end user's bot-only frame upstream without waiting (the
  connection queues it until it is connected).
  """
  @spec forward(map(), String.t(), map()) :: :ok | {:error, term()}
  def forward(channel, conversation_id, frame) do
    with {:ok, pid} <- ensure(channel, conversation_id) do
      Connection.forward(pid, frame)
    end
  end

  @doc "The `{channel_id, conversation_id, pid}` of the connections on this node."
  @spec local() :: [{String.t(), String.t(), pid()}]
  def local do
    Registry.select(@registry, [{{{:"$1", :"$2"}, :"$3", :_}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc "Stop every connection of `channel_id` on this node."
  @spec stop_channel(String.t()) :: :ok
  def stop_channel(channel_id) do
    for {^channel_id, _conversation_id, pid} <- local() do
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    :ok
  end
end
