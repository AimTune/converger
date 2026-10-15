defmodule Converger.Channels.DeliveryError do
  @moduledoc """
  Structured delivery failure returned by adapters as `{:error, %DeliveryError{}}`.

    * `retryable?` - `false` for permanent failures (e.g. 400 invalid recipient,
      401/403, 404): the delivery is dead-lettered immediately.
    * `retry_after_ms` - provider-requested delay (e.g. 429 `Retry-After`);
      overrides the channel's backoff for the next attempt.

  Adapters may still return plain `{:error, term}`; that is treated as retryable.
  """

  @enforce_keys [:reason]
  defstruct [:reason, :status, :retry_after_ms, retryable?: true]

  @type t :: %__MODULE__{
          reason: term(),
          status: pos_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          retryable?: boolean()
        }

  # Request timeout, too early, rate limited, and server-side errors are transient.
  @retryable_statuses [408, 425, 429]

  @doc "Classify a non-2xx HTTP response."
  def from_http(status, headers, body, label \\ "provider") do
    %__MODULE__{
      reason: "#{label} returned #{status}: #{inspect(body)}",
      status: status,
      retryable?: status in @retryable_statuses or status >= 500,
      retry_after_ms: retry_after_ms(headers)
    }
  end

  @doc "Classify a transport failure (timeout, connection refused, DNS...): always retryable."
  def from_transport(reason, label \\ "provider") do
    %__MODULE__{reason: "#{label} request failed: #{inspect(reason)}", retryable?: true}
  end

  @doc "A permanent failure that must not be retried."
  def permanent(reason), do: %__MODULE__{reason: reason, retryable?: false}

  @doc """
  Classify any delivery failure reason (the default
  `c:Converger.Channels.Adapter.normalize_error/1`):

    * a `DeliveryError` is returned as is;
    * a plain map with `:reason` (and optionally `:retryable?`,
      `:retry_after_ms`, `:status`) becomes a `DeliveryError`;
    * any other term is a retryable failure with that reason.
  """
  def normalize(%__MODULE__{} = error), do: error

  def normalize(%{reason: reason} = map) when not is_struct(map) do
    %__MODULE__{
      reason: reason,
      status: Map.get(map, :status),
      retry_after_ms: Map.get(map, :retry_after_ms),
      retryable?: Map.get(map, :retryable?, true) != false
    }
  end

  def normalize(reason), do: %__MODULE__{reason: reason}

  @doc "Human-readable message for `last_error`."
  def message(%__MODULE__{reason: reason}) when is_binary(reason), do: reason
  def message(%__MODULE__{reason: reason}), do: inspect(reason)

  @doc """
  Parse a `Retry-After` header (delta-seconds or HTTP-date) into milliseconds.
  Accepts Req's header map (`%{"retry-after" => [value]}`) or a list of tuples.
  """
  def retry_after_ms(headers) do
    case header(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after(String.trim(value))
    end
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp header(_, _), do: nil

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds * 1000

      _ ->
        case parse_http_date(value) do
          {:ok, datetime} -> max(DateTime.diff(datetime, DateTime.utc_now(), :millisecond), 0)
          _ -> nil
        end
    end
  end

  # IMF-fixdate, e.g. "Wed, 21 Oct 2015 07:28:00 GMT"
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp parse_http_date(value) do
    with [_dow, day, mon, year, time, "GMT"] <- String.split(value, ~r/[\s,]+/, trim: true),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == mon)),
         {:ok, date} <-
           Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
