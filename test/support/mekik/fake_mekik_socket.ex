defmodule Converger.FakeMekikServer.Socket do
  @moduledoc "One WebSocket connection of `Converger.FakeMekikServer`."

  @behaviour WebSock

  alias Converger.FakeMekikServer

  @interrupt_id "int-1"

  @impl true
  def init(state), do: {:ok, Map.merge(state, %{conversation_id: nil})}

  @impl true
  def handle_in({text, opcode: :text}, state) do
    frame = Jason.decode!(text)
    send(state.test, {:mekik_frame, self(), frame})

    if state.conversation_id,
      do: handle_frame(frame, state),
      else: handshake(frame, state)
  end

  def handle_in(_frame, state), do: {:ok, state}

  # The first frame: the hello (query string merged, frame wins).
  defp handshake(frame, state) do
    hello = Map.merge(query_hello(state.query), Map.drop(frame, ["type"]))

    hello =
      if state.bearer && !hello["token"], do: Map.put(hello, "token", state.bearer), else: hello

    send(state.test, {:mekik_connected, self(), hello})

    settings = Agent.get(state.state, & &1.settings)

    if settings[:token] && hello["token"] != settings[:token] do
      error = %{
        "type" => "error",
        "data" => %{"code" => "unauthorized", "message" => "bad token"}
      }

      send(self(), {:close, 4401, "unauthorized"})
      {:push, {:text, Jason.encode!(error)}, state}
    else
      {conversation_id, welcome, replay, fresh?, settings} =
        FakeMekikServer.connect(state.state, self(), hello)

      state = %{state | conversation_id: conversation_id}
      frames = [welcome | replay]

      greeting =
        if fresh? && settings[:greeting],
          do: [
            emit(state, %{
              "type" => "text",
              "id" => "msg-greeting",
              "from" => "bot",
              "data" => %{"text" => settings[:greeting]}
            })
          ],
          else: []

      {:push, Enum.map(frames ++ greeting, &{:text, Jason.encode!(&1)}), state}
    end
  end

  defp query_hello(query) do
    query
    |> Map.take(["userId", "conversationId", "watermark", "token"])
    |> Map.update("watermark", nil, fn value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> nil
      end
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp handle_frame(%{"type" => "text", "data" => %{"text" => text}} = frame, state) do
    # Recorded (a reconnect replays the echo), not echoed to its sender.
    emit(state, %{
      "type" => "text",
      "id" => "msg-user-#{System.unique_integer([:positive])}",
      "from" => "user",
      "data" => %{"text" => text},
      "meta" => frame["meta"]
    })

    frames =
      if text == "ORD-42" do
        [
          run("started"),
          emit(state, %{
            "type" => "tool_call",
            "data" => %{
              "id" => "tool-1",
              "name" => "get_order",
              "status" => "running",
              "params" => %{"id" => "ORD-42"}
            }
          }),
          emit(state, %{
            "type" => "tool_call",
            "data" => %{
              "id" => "tool-1",
              "name" => "get_order",
              "status" => "completed",
              "params" => %{"id" => "ORD-42"},
              "result" => %{"id" => "ORD-42", "total" => 249.9}
            }
          }),
          emit(state, %{
            "type" => "interrupt",
            "id" => @interrupt_id,
            "data" => %{
              "payload" => %{"title" => "Refund $249.9 for ORD-42?"},
              "ui" => %{"component" => "approval-form", "props" => %{"orderId" => "ORD-42"}},
              "actions" => [
                %{"label" => "Approve", "value" => %{"approved" => true}},
                %{"label" => "Reject", "value" => %{"approved" => false}}
              ]
            }
          }),
          run("interrupted")
        ]
      else
        [
          run("started"),
          emit(state, %{
            "type" => "text",
            "id" => "msg-#{System.unique_integer([:positive])}",
            "from" => "bot",
            "data" => %{"text" => "echo: #{text}"}
          }),
          run("finished")
        ]
      end

    {:push, Enum.map(frames, &{:text, Jason.encode!(&1)}), state}
  end

  defp handle_frame(%{"type" => "resume", "answers" => %{@interrupt_id => answer}}, state) do
    reply =
      if answer == %{"approved" => true}, do: "Refund complete: ORD-42", else: "Refund declined."

    frames = [
      run("started"),
      emit(state, %{
        "type" => "interrupt_resolved",
        "id" => @interrupt_id,
        "data" => %{"answer" => answer}
      }),
      emit(state, %{
        "type" => "text",
        "id" => "msg-reply",
        "from" => "bot",
        "data" => %{"text" => reply}
      }),
      run("finished")
    ]

    {:push, Enum.map(frames, &{:text, Jason.encode!(&1)}), state}
  end

  defp handle_frame(_frame, state), do: {:ok, state}

  defp run(status), do: %{"type" => "run", "data" => %{"status" => status}}

  defp emit(state, frame) do
    {frame, _socket} =
      Agent.get_and_update(
        state.state,
        &FakeMekikServer.record(&1, state.conversation_id, drop_nil(frame))
      )

    frame
  end

  defp drop_nil(frame), do: frame |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  @impl true
  def handle_info({:push, text}, state), do: {:push, {:text, text}, state}
  def handle_info({:close, code, reason}, state), do: {:stop, :normal, {code, reason}, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    send(state.test, {:mekik_closed, self()})
    :ok
  end
end
