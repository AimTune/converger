defmodule ConvergerWeb.Protocol.AdmissionTest do
  @moduledoc """
  The admission queue of v1 handshakes and replays (issue #198, ADR-0076).
  """

  # Not async: the admission server and its config are node-global.
  use ExUnit.Case, async: false

  alias ConvergerWeb.Protocol.Admission

  setup do
    previous = Application.fetch_env!(:converger, :websocket)
    on_exit(fn -> Application.put_env(:converger, :websocket, previous) end)
    :ok
  end

  defp put_limits(limits) do
    Application.put_env(
      :converger,
      :websocket,
      Keyword.merge(Application.fetch_env!(:converger, :websocket), limits)
    )
  end

  # A process that takes a slot and holds it until told to finish.
  defp hold do
    test = self()

    pid =
      spawn(fn ->
        Admission.run(fn ->
          send(test, {:holding, self()})

          receive do
            :finish -> :ok
          end
        end)

        send(test, {:released, self()})
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "runs the work and returns its result" do
    assert {:ok, 42} = Admission.run(fn -> 42 end)
    assert %{active: 0, waiting: 0} = Admission.stats()
  end

  test "the default limit is half the interactive pool" do
    put_limits(handshake_concurrency: 0)
    pool_size = Application.fetch_env!(:converger, Converger.Repo)[:pool_size]
    assert Admission.limit() == max(div(pool_size, 2), 1)

    put_limits(handshake_concurrency: 3)
    assert Admission.limit() == 3
  end

  test "callers beyond the limit wait, in arrival order, until a slot is free" do
    put_limits(handshake_concurrency: 1, handshake_queue_ms: 5_000)
    holder = hold()
    test = self()

    waiters =
      for n <- 1..3 do
        pid = spawn(fn -> Admission.run(fn -> send(test, {:ran, n}) end) end)
        wait_until(fn -> Admission.stats().waiting == n end)
        pid
      end

    assert length(waiters) == 3
    refute_received {:ran, _}

    send(holder, :finish)

    # With one slot the work runs one at a time, so this is the grant order.
    order =
      for _ <- 1..3 do
        assert_receive {:ran, n}
        n
      end

    assert order == [1, 2, 3]
    wait_until(fn -> Admission.stats() == %{active: 0, waiting: 0, limit: 1} end)
  end

  test "a caller that waits longer than handshake_queue_ms is answered overloaded" do
    put_limits(handshake_concurrency: 1, handshake_queue_ms: 50)
    holder = hold()

    assert {:error, :overloaded} = Admission.run(fn -> :never end)
    assert %{active: 1, waiting: 0} = Admission.stats()

    send(holder, :finish)
    assert_receive {:released, ^holder}
    wait_until(fn -> Admission.stats().active == 0 end)
  end

  test "a full queue answers overloaded at once" do
    put_limits(handshake_concurrency: 1, handshake_queue_ms: 5_000, handshake_queue_max: 1)
    holder = hold()
    test = self()
    spawn(fn -> send(test, {:queued, Admission.run(fn -> :queued end)}) end)
    wait_until(fn -> Admission.stats().waiting == 1 end)

    {elapsed, result} = :timer.tc(fn -> Admission.run(fn -> :never end) end)
    assert result == {:error, :overloaded}
    assert elapsed < 1_000_000

    send(holder, :finish)
    assert_receive {:queued, {:ok, :queued}}
  end

  test "the slot is released when the work raises" do
    put_limits(handshake_concurrency: 1)
    assert_raise RuntimeError, fn -> Admission.run(fn -> raise "boom" end) end
    wait_until(fn -> Admission.stats().active == 0 end)
    assert {:ok, :again} = Admission.run(fn -> :again end)
  end

  test "a holder or waiter that exits frees its place" do
    put_limits(handshake_concurrency: 1, handshake_queue_ms: 5_000)
    holder = hold()
    waiter = spawn(fn -> Admission.run(fn -> :never end) end)
    wait_until(fn -> Admission.stats().waiting == 1 end)

    Process.exit(waiter, :kill)
    wait_until(fn -> Admission.stats().waiting == 0 end)

    Process.exit(holder, :kill)
    wait_until(fn -> Admission.stats().active == 0 end)
    assert {:ok, :free} = Admission.run(fn -> :free end)
  end
end
