defmodule ConvergerWeb.ClientConnections do
  @moduledoc """
  Node-local registry of the open client connections, the source of the
  `converger.ws.connections` gauge (`ConvergerWeb.Telemetry`).

  Every client connection registers once it is established, labelled with
  its `socket` and `transport`:

  | socket | transport | Connection |
  | --- | --- | --- |
  | `user` | `websocket` | `ConvergerWeb.UserSocket` (`/socket`, legacy) |
  | `converger` | `websocket`, `longpoll` | `ConvergerWeb.ConvergerSocket` (`/socket/converger`) |
  | `protocol` | `websocket`, `sse` | `ConvergerWeb.ProtocolSocket` and the Protocol v1 event stream |

  The registry drops a process when it exits, however it exits, so the gauge
  cannot drift. `[:converger, :ws, :connected]` and `[:converger, :ws,
  :disconnected]` (`%{count: 1}`, `%{socket: ..., transport: ...}`) are
  emitted alongside; a disconnect is only reported when the connection
  terminates through its callbacks (not when it is killed).
  """

  @registry __MODULE__

  @labels [
    {"user", "websocket"},
    {"converger", "websocket"},
    {"converger", "longpoll"},
    {"protocol", "websocket"},
    {"protocol", "sse"}
  ]

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Registers the calling process as an open connection."
  def connected(socket, transport) do
    {:ok, _owner} = Registry.register(@registry, {socket, transport}, nil)
    emit(:connected, socket, transport)
  end

  @doc "Unregisters the calling process (for processes that outlive a connection)."
  def disconnected(socket, transport) do
    Registry.unregister(@registry, {socket, transport})
    emit(:disconnected, socket, transport)
  end

  @doc "Open connections on this node, per `{socket, transport}`."
  def counts do
    Map.new(@labels, fn key -> {key, Registry.count_match(@registry, key, :_)} end)
  end

  @doc "Polled: emits `[:converger, :ws, :connections]` with the open connections per label."
  def measure do
    for {{socket, transport}, count} <- counts() do
      :telemetry.execute([:converger, :ws, :connections], %{count: count}, %{
        socket: socket,
        transport: transport
      })
    end

    :ok
  end

  defp emit(event, socket, transport) do
    :telemetry.execute([:converger, :ws, event], %{count: 1}, %{
      socket: socket,
      transport: transport
    })
  end
end
