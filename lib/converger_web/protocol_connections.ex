defmodule ConvergerWeb.ProtocolConnections do
  @moduledoc """
  Node-local registry of the native Protocol v1 connections
  (`ConvergerWeb.ProtocolSocket` WebSockets and Server-Sent Events streams),
  so they can be drained on shutdown.

  Phoenix's socket drainer only knows the sockets mounted with the endpoint
  `socket` macro. `ConvergerWeb.Drain` calls `drain/0` once the node stopped
  receiving traffic: every registered process gets `:socket_drain` in batches
  of `:drain_batch_size` every `:drain_batch_interval_ms`, at most for
  `:drain_shutdown_ms` (`config :converger, :websocket`), the same pacing as
  the Phoenix sockets. A WebSocket then closes with 1012 and a jittered
  `retryAfterMs`; an SSE stream ends with an `error` `unavailable` event.
  """

  @registry __MODULE__
  @key :connection

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Register the calling process (it unregisters automatically when it exits)."
  def register do
    {:ok, _owner} = Registry.register(@registry, @key, nil)
    :ok
  end

  @doc "Unregister the calling process (for processes that outlive a stream)."
  def unregister, do: Registry.unregister(@registry, @key)

  @doc "Number of registered connections on this node."
  def count, do: @registry |> Registry.lookup(@key) |> length()

  @doc "Send `:socket_drain` to every registered connection, in paced batches."
  def drain do
    config = Application.fetch_env!(:converger, :websocket)
    deadline = System.monotonic_time(:millisecond) + config[:drain_shutdown_ms]

    @registry
    |> Registry.lookup(@key)
    |> Enum.map(fn {pid, _value} -> pid end)
    |> Enum.chunk_every(config[:drain_batch_size])
    |> Enum.with_index()
    |> Enum.each(fn {batch, index} ->
      if index > 0 and System.monotonic_time(:millisecond) < deadline,
        do: Process.sleep(config[:drain_batch_interval_ms])

      Enum.each(batch, &send(&1, :socket_drain))
    end)
  end
end
