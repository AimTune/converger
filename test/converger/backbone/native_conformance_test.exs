defmodule Converger.Backbone.NativeConformanceTest do
  @moduledoc """
  The backbone conformance suite (`Converger.BackboneConformance`) against
  the Native backbone (Phoenix.PubSub + Oban on Postgres). Always runs.

  Oban runs in `:manual` testing mode here, so the suite can drain the
  `backbone` queue itself and see retries.
  """

  use Converger.DataCase, async: false

  use Converger.BackboneConformance, backbone: Converger.Backbone.Native, timeout: 5_000

  import Ecto.Query

  setup do
    %{run: run_id()}
  end

  # Publish in manual mode: the jobs wait in the queue until `deliver/1`.
  def publish_event(event) do
    Oban.Testing.with_testing_mode(:manual, fn ->
      Converger.Backbone.do_publish(Converger.Backbone.Native, event)
    end)
  end

  # Oban's testing mode is per process; drain in the test process.
  def deliver(_context) do
    Oban.Testing.with_testing_mode(:manual, fn ->
      Oban.drain_queue(queue: :backbone, with_scheduled: true, with_recursion: true)
    end)

    :ok
  end

  # A node that crashed after a job ran its handler but before Oban recorded
  # the job as completed: Lifeline rescues the job and it runs again. Re-run
  # every completed job of the subscription.
  def crash_consumers(_context, subscription) do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Converger.Workers.BackboneEventWorker",
          where: fragment("?->>'subscription' = ?", j.args, ^subscription.name)
        )
      )

    assert jobs != []

    Oban.Testing.with_testing_mode(:manual, fn ->
      for job <- jobs,
          do: {:ok, _} = Oban.insert(Converger.Workers.BackboneEventWorker.new(job.args))
    end)

    :ok
  end
end
