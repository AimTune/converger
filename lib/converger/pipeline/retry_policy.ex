defmodule Converger.Pipeline.RetryPolicy do
  @moduledoc """
  Single source of truth for external delivery retries, shared by every
  pipeline backend and by `Converger.Deliveries`.

  The `attempts` counter on `Converger.Deliveries.Delivery` drives the policy:
  once it reaches `max_attempts/0` the delivery is dead-lettered
  (`status: "failed"`) and no further attempts are made.

      config :converger, :retry_policy,
        max_attempts: 5,
        base_backoff_seconds: 10

  Backoff is exponential: `base * 3^attempt` seconds (10s, 30s, 90s, 270s, ...).
  """

  @default_max_attempts 5
  @default_base_backoff_seconds 10

  @doc "Total number of delivery attempts before a delivery is dead-lettered."
  def max_attempts, do: config(:max_attempts, @default_max_attempts)

  @doc "Seconds to wait before the retry that follows `attempt` (1-based)."
  def backoff(attempt) when is_integer(attempt) and attempt >= 1 do
    trunc(:math.pow(3, attempt) * config(:base_backoff_seconds, @default_base_backoff_seconds))
  end

  @doc "Whether a delivery with `attempts` attempts made has used up its retries."
  def exhausted?(attempts) when is_integer(attempts), do: attempts >= max_attempts()

  defp config(key, default) do
    :converger
    |> Application.get_env(:retry_policy, [])
    |> Keyword.get(key, default)
  end
end
