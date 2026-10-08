defmodule Converger.Pipeline.RetryPolicy do
  @moduledoc """
  Single source of truth for external delivery retries, shared by every
  pipeline backend, the Oban worker and `Converger.Deliveries`.

  A policy is resolved per channel (`for_channel/1`) by merging, in order:

    1. global defaults: `config :converger, :retry_policy, max_attempts: 5, base_ms: 10_000, ...`
    2. the adapter's defaults (optional `retry_policy/0` adapter callback)
    3. the channel's own `retry_policy` map (`channels.retry_policy`, string keys)

  Fields:

    * `max_attempts` - attempts before the delivery is dead-lettered (`status: "failed"`)
    * `backoff` - `exponential` (`base * 3^attempt`), `linear` (`base * attempt`) or `fixed`
    * `base_ms` / `max_ms` - backoff base and cap, in milliseconds
    * `timeout_ms` - adapter request timeout

  The `attempts` counter on `Converger.Deliveries.Delivery` drives the policy.
  A provider `Retry-After` (see `Converger.Channels.DeliveryError`) overrides
  the backoff for the next attempt.
  """

  @backoffs ~w(exponential linear fixed)a
  @keys ~w(max_attempts backoff base_ms max_ms timeout_ms)

  defstruct max_attempts: 5,
            backoff: :exponential,
            base_ms: 10_000,
            max_ms: :timer.hours(1),
            timeout_ms: 15_000

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: :exponential | :linear | :fixed,
          base_ms: pos_integer(),
          max_ms: pos_integer(),
          timeout_ms: pos_integer()
        }

  @doc "The global default policy (application config)."
  def default do
    config = Application.get_env(:converger, :retry_policy, [])

    # `base_backoff_seconds` is the pre-per-channel config key, still honoured.
    config =
      case Keyword.fetch(config, :base_backoff_seconds) do
        {:ok, seconds} -> Keyword.put_new(config, :base_ms, seconds * 1000)
        :error -> config
      end

    struct(__MODULE__, Keyword.take(config, Enum.map(@keys, &String.to_atom/1)))
  end

  @doc "Resolve the effective policy for a channel."
  def for_channel(%{type: type} = channel) do
    default()
    |> merge(Converger.Channels.Adapter.retry_policy(type))
    |> merge(Map.get(channel, :retry_policy) || %{})
  end

  def for_channel(_), do: default()

  @doc """
  Milliseconds to wait before the retry that follows `attempt` (1-based),
  capped at `max_ms`.
  """
  def backoff_ms(%__MODULE__{} = policy, attempt) when is_integer(attempt) and attempt >= 1 do
    delay =
      case policy.backoff do
        :exponential -> policy.base_ms * Integer.pow(3, attempt)
        :linear -> policy.base_ms * attempt
        :fixed -> policy.base_ms
      end

    min(delay, policy.max_ms)
  end

  @doc "Whether a delivery with `attempts` attempts made has used up its retries."
  def exhausted?(%__MODULE__{max_attempts: max}, attempts) when is_integer(attempts),
    do: attempts >= max

  @doc """
  Validate a channel `retry_policy` map (string or atom keys).
  Returns `:ok` or `{:error, message}`.
  """
  def validate(policy) when is_map(policy) do
    Enum.reduce_while(policy, :ok, fn {key, value}, :ok ->
      case validate_field(to_string(key), value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate(_), do: {:error, "retry_policy must be a map"}

  defp validate_field("backoff", value) do
    if to_string(value) in Enum.map(@backoffs, &Atom.to_string/1),
      do: :ok,
      else: {:error, "backoff must be one of: #{Enum.join(@backoffs, ", ")}"}
  end

  defp validate_field(key, value) when key in @keys do
    if is_integer(value) and value > 0,
      do: :ok,
      else: {:error, "#{key} must be a positive integer"}
  end

  defp validate_field(key, _value), do: {:error, "unknown retry_policy key: #{key}"}

  defp merge(policy, overrides) do
    Enum.reduce(overrides, policy, fn {key, value}, acc ->
      key = to_string(key)

      cond do
        key == "backoff" and to_string(value) in Enum.map(@backoffs, &Atom.to_string/1) ->
          %{acc | backoff: String.to_existing_atom(to_string(value))}

        key in @keys and key != "backoff" and is_integer(value) and value > 0 ->
          Map.put(acc, String.to_existing_atom(key), value)

        true ->
          acc
      end
    end)
  end

  # --- Global-policy shortcuts (kept for callers without a channel at hand) ---

  @doc "Total attempts of the global default policy."
  def max_attempts, do: default().max_attempts

  @doc "Seconds before the retry after `attempt` under the global default policy."
  def backoff(attempt), do: div(backoff_ms(default(), attempt), 1000)

  @doc "Whether `attempts` exhausts the global default policy."
  def exhausted?(attempts) when is_integer(attempts), do: exhausted?(default(), attempts)
end
