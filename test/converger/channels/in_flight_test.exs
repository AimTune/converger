defmodule Converger.Channels.InFlightTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.InFlight

  setup do
    name = :"in_flight_#{System.unique_integer([:positive])}"
    start_supervised!({InFlight, name: name})
    %{opts: [server: name, demote_ms: 60_000]}
  end

  # A process that takes a slot and holds it until it exits.
  defp holder(channel_id, cap, opts) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:acquired, self(), InFlight.acquire(channel_id, cap, opts)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:acquired, ^pid, result}
    {pid, result}
  end

  test "gives at most `cap` slots per channel", %{opts: opts} do
    for _ <- 1..2, do: assert({_, {:ok, _}} = holder("a", 2, opts))
    assert {:full, _} = InFlight.acquire("a", 2, opts)

    # Another channel has its own slots.
    assert {:ok, _} = InFlight.acquire("b", 2, opts)
    assert InFlight.count("a", opts) == 2
  end

  test "asks for one backlog demotion per window", %{opts: opts} do
    {_, {:ok, _}} = holder("a", 1, opts)

    assert {:full, true} = InFlight.acquire("a", 1, opts)
    assert {:full, false} = InFlight.acquire("a", 1, opts)
    assert {:full, true} = InFlight.acquire("a", 1, Keyword.put(opts, :demote_ms, 0))
  end

  test "release/1 frees the slot", %{opts: opts} do
    {:ok, ref} = InFlight.acquire("a", 1, opts)
    assert {:full, _} = InFlight.acquire("a", 1, opts)

    InFlight.release(ref, opts)
    assert InFlight.count("a", opts) == 0
    assert {:ok, _} = InFlight.acquire("a", 1, opts)
  end

  test "a slot is freed when its process exits without releasing", %{opts: opts} do
    {pid, {:ok, _}} = holder("a", 1, opts)
    assert {:full, _} = InFlight.acquire("a", 1, opts)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert InFlight.count("a", opts) == 0
    assert {:ok, _} = InFlight.acquire("a", 1, opts)
  end

  test "a nil cap never limits", %{opts: opts} do
    for _ <- 1..5, do: assert({:ok, nil} = InFlight.acquire("a", nil, opts))
    assert InFlight.count("a", opts) == 0
  end
end
