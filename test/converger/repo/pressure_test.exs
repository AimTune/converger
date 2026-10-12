defmodule Converger.Repo.PressureTest do
  # Not async: the pool wait window and the config are node-global.
  use ExUnit.Case, async: false

  alias Converger.Repo
  alias Converger.Repo.{Pools, Pressure}

  defp put_env(module, overrides) do
    previous = Application.get_env(:converger, module)
    Application.put_env(:converger, module, Keyword.merge(previous || [], overrides))
    on_exit(fn -> Application.put_env(:converger, module, previous) end)
  end

  describe "unavailable?/1" do
    test "is true for a connection error, also wrapped by the router" do
      error = DBConnection.ConnectionError.exception("dropped from queue")

      assert Pressure.unavailable?(error)

      assert Pressure.unavailable?(%Plug.Conn.WrapperError{
               conn: nil,
               kind: :error,
               reason: error,
               stack: []
             })
    end

    test "is false for anything else" do
      refute Pressure.unavailable?(RuntimeError.exception("boom"))
      refute Pressure.unavailable?(%Postgrex.Error{message: "syntax error"})
    end
  end

  test "retry_after_ms/0 is jittered between the base and twice the base" do
    put_env(Pressure, retry_after_ms: 1_000)

    values = for _ <- 1..200, do: Pressure.retry_after_ms()
    assert Enum.all?(values, &(&1 in 1_000..2_000))
    assert length(Enum.uniq(values)) > 1
  end

  @tag :capture_log
  test "report/2 emits [:converger, :db, :unavailable] with the source" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:converger, :db, :unavailable]])
    on_exit(fn -> :telemetry.detach(ref) end)

    Pressure.report(:http, DBConnection.ConnectionError.exception("dropped"))

    assert_receive {[:converger, :db, :unavailable], ^ref, %{count: 1}, %{source: :http}}
  end

  describe "pool wait time" do
    setup do
      # Start from an empty window.
      Pressure.flush()
      :ok
    end

    test "is degraded while the window's average wait reaches the threshold" do
      put_env(Pressure, degraded_queue_ms: 200)

      Pressure.record(300_000)
      Pressure.record(500_000)
      Pressure.flush()

      assert Pressure.queue_time_ms() >= 200
      assert Pressure.degraded?()

      # An empty window is not degraded.
      Pressure.flush()
      refute Pressure.degraded?()
    end

    test "a short wait is not degraded, and 0 disables the check" do
    put_env(Pressure, degraded_queue_ms: 200)
      Pressure.record(1_000)
      Pressure.flush()
      refute Pressure.degraded?()

      put_env(Pressure, degraded_queue_ms: 0)
      Pressure.record(10_000_000)
      Pressure.flush()
      refute Pressure.degraded?()
    end
  end

  describe "pools" do
    test "with the background pool disabled everything uses Converger.Repo" do
      put_env(Pools, background: false)

      refute Pools.enabled?()
      assert Pools.background() == Repo
      assert Pools.child_specs() == []
      assert Pools.oban_config(repo: Repo) == [repo: Repo]
    end

    test "the background pool is a second, named instance with its own timeouts" do
      put_env(Pools, background: [pool_size: 4, queue_target: 900])

      assert Pools.background() == Converger.Repo.Background

      assert [%{id: Converger.Repo.Background, start: {Repo, :start_link, [opts]}}] =
               Pools.child_specs()

      assert opts[:name] == Converger.Repo.Background
      assert opts[:pool_size] == 4
      assert opts[:queue_target] == 900
      assert opts[:queue_interval] == 5_000
      assert opts[:timeout] == 60_000
      assert opts[:telemetry_prefix] == [:converger, :background_repo]

      assert Pools.oban_config(repo: Repo)[:get_dynamic_repo] == {Pools, :background, []}
    end

    test "a job process is switched to the background pool" do
      put_env(Pools, background: [pool_size: 1])

      task =
        Task.async(fn ->
          Pools.handle_job_start([:oban, :job, :start], %{}, %{}, nil)
          Repo.get_dynamic_repo()
        end)

      assert Task.await(task) == Converger.Repo.Background
      # Other processes keep the interactive pool.
      assert Repo.get_dynamic_repo() == Repo
    end
  end
end
