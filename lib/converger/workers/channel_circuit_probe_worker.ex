defmodule Converger.Workers.ChannelCircuitProbeWorker do
  @moduledoc """
  Half-open probe scheduler for an open channel circuit breaker (see
  `Converger.Channels.Circuit`).

  Scheduled `cooldown_ms` after the breaker opens. While the breaker stays
  open it wakes one parked delivery job per cooldown; that job claims the
  half-open state and is the probe. It stops once the breaker is closed or
  paused, or when nothing is parked (the next delivery then probes itself).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    # One probe loop per channel.
    unique: [keys: [:channel_id], period: :infinity, states: :incomplete]

  alias Converger.Channels.{Channel, Circuit}
  alias Converger.Repo

  @doc "Schedule the probe loop of a channel `delay_ms` from now."
  def schedule(channel_id, delay_ms) do
    %{channel_id: channel_id}
    |> new(schedule_in: max(div(delay_ms, 1000), 1))
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_id" => channel_id}}) do
    cooldown_ms = Circuit.config()[:cooldown_ms]

    case Repo.get(Channel, channel_id) do
      %Channel{circuit_state: state} = channel when state in ~w(open half_open) ->
        remaining_ms = remaining_cooldown_ms(channel, cooldown_ms)

        cond do
          remaining_ms > 0 -> {:snooze, max(div(remaining_ms, 1000), 1)}
          Circuit.wake_probe(channel.id) == 1 -> {:snooze, max(div(cooldown_ms, 1000), 1)}
          true -> :ok
        end

      _ ->
        :ok
    end
  end

  defp remaining_cooldown_ms(%Channel{circuit_changed_at: nil}, _cooldown_ms), do: 0

  defp remaining_cooldown_ms(%Channel{circuit_changed_at: changed_at}, cooldown_ms) do
    cooldown_ms - DateTime.diff(DateTime.utc_now(), changed_at, :millisecond)
  end
end
