defmodule Converger.Workers.ChannelDeadLetterReplayWorker do
  @moduledoc """
  Replays a channel's recent dead letters after its circuit breaker closed
  (opt-in: `config :converger, :circuit_breaker, replay_dead_letters_on_close: true`,
  see `Converger.Channels.Circuit`).

  Replays every dead letter of the channel that failed at or after `since`
  through `Converger.Deliveries.retry_dead_letters/3`, as the `system` actor
  `circuit_breaker`, so each replay is audited like a manual one. Dead letters
  caused by permanent errors are replayed too and simply fail again after one
  attempt. Large backlogs are replayed `bulk_retry_limit` at a time.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:channel_id], period: 60, states: :incomplete]

  alias Converger.Deliveries

  @actor %{type: "system", id: "circuit_breaker"}

  @doc "Enqueue the replay of dead letters of `channel_id` that failed since `since`."
  def enqueue(channel_id, %DateTime{} = since) do
    %{channel_id: channel_id, since: DateTime.to_iso8601(since)}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id, "since" => since}}) do
    {:ok, since, _} = DateTime.from_iso8601(since)

    case Deliveries.retry_dead_letters(%{channel_id: channel_id, from: since}, @actor) do
      {:ok, %{has_more: true}} -> {:snooze, 1}
      {:ok, _} -> :ok
    end
  end
end
