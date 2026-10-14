defmodule ConvergerAgent.FakeSocket do
  @moduledoc false
  # WebSock handler of ConvergerAgent.FakeServer: forwards every frame the
  # agent sends to the test process and writes or closes on its command.

  @behaviour WebSock

  @impl true
  def init(state) do
    send(state.test, {:fake_conn, self(), state.auth})
    {:ok, state}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    send(state.test, {:fake_frame, self(), text})
    {:ok, state}
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:write, text}, state), do: {:push, {:text, text}, state}
  def handle_info({:close, code}, state), do: {:stop, :normal, code, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
