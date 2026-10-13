defmodule Converger.FakeDiscordGateway.Socket do
  @moduledoc "One WebSocket connection of `Converger.FakeDiscordGateway`."

  @behaviour WebSock

  @impl true
  def init(state) do
    send(state.test, {:gateway_connected, self(), state.path})
    interval = Agent.get(state.settings, &Map.get(&1, :heartbeat_interval, 45_000))
    hello = Jason.encode!(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}})
    {:push, {:text, hello}, state}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    payload = Jason.decode!(text)
    send(state.test, {:gateway_frame, self(), payload})

    if payload["op"] == 1 and Agent.get(state.settings, &Map.get(&1, :ack_heartbeats, true)),
      do: {:push, {:text, Jason.encode!(%{"op" => 11})}, state},
      else: {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:push, text}, state), do: {:push, {:text, text}, state}
  def handle_info({:close, code, reason}, state), do: {:stop, :normal, {code, reason}, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    send(state.test, {:gateway_closed, self()})
    :ok
  end
end
