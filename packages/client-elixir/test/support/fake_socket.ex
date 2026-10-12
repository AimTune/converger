defmodule ConvergerClient.FakeSocket do
  @moduledoc false
  # WebSock handler of ConvergerClient.FakeServer.

  @behaviour WebSock

  alias ConvergerClient.FakeServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_in({text, opcode: :text}, %{hello: nil} = state) do
    hello = Jason.decode!(text)
    agent = state.agent
    me = self()
    Agent.update(agent, &%{&1 | hellos: &1.hellos ++ [hello]})
    state = %{state | hello: hello}

    if state.auth != "Bearer good" do
      error = Jason.encode!(%{"type" => "error", "data" => %{"code" => "unauthorized"}})
      {:stop, :normal, {4401, "unauthorized"}, [{:text, error}], state}
    else
      wm = hello["watermark"] || 0

      {frames, close} =
        Agent.get_and_update(agent, fn s ->
          case s.close_after_replay do
            [code | rest] -> {{s.frames, code}, %{s | close_after_replay: rest}}
            [] -> {{s.frames, nil}, %{s | conns: [me | s.conns]}}
          end
        end)

      welcome = %{
        "type" => "welcome",
        "data" => %{
          "protocol" => "converger/1",
          "conversationId" => "c-1",
          "watermark" => length(frames),
          "limits" => %{"idleTimeoutMs" => 60_000}
        }
      }

      messages =
        [welcome | Enum.filter(frames, &(&1["seq"] > wm))]
        |> Enum.map(&{:text, Jason.encode!(&1)})

      if close,
        do:
          {:stop, :normal, {close, ~s({"reason":"unavailable","retryAfterMs":10})}, messages,
           state},
        else: {:push, messages, state}
    end
  end

  def handle_in({text, opcode: :text}, state) do
    frame = Jason.decode!(text)

    drop? =
      Agent.get_and_update(state.agent, fn s ->
        drop = frame["type"] == "text" and s.drop_first_text

        {drop,
         %{s | received: s.received ++ [frame], drop_first_text: s.drop_first_text and not drop}}
      end)

    cond do
      drop? ->
        {:stop, :normal, {1011, "boom"}, state}

      frame["type"] == "text" ->
        cid = frame["clientId"]

        ack =
          Agent.get_and_update(state.agent, fn s ->
            case s.acked do
              %{^cid => ack} ->
                {Map.put(ack, "duplicate", true), s}

              _ ->
                seq = length(s.frames) + 1
                stored = FakeServer.text_frame(seq, "user", frame["data"]["text"], cid)

                ack = %{
                  "type" => "ack",
                  "clientId" => cid,
                  "id" => "a-#{seq}",
                  "seq" => seq,
                  "timestamp" => 1
                }

                {ack, %{s | frames: s.frames ++ [stored], acked: Map.put(s.acked, cid, ack)}}
            end
          end)

        {:push, {:text, Jason.encode!(ack)}, state}

      frame["type"] == "sync" ->
        frames = FakeServer.get(state.agent, :frames)
        replay = for f <- frames, f["seq"] > frame["watermark"], do: {:text, Jason.encode!(f)}
        {:push, replay, state}

      true ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:push, frame}, state), do: {:push, {:text, Jason.encode!(frame)}, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    me = self()
    Agent.update(state.agent, &%{&1 | conns: List.delete(&1.conns, me)})
    :ok
  catch
    :exit, _ -> :ok
  end
end
