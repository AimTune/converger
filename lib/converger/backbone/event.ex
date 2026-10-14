defmodule Converger.Backbone.Event do
  @moduledoc """
  An event on the backbone (`Converger.Backbone`).

    * `id` - a UUID, unique per event. It is the **idempotency key**:
      subscriptions with `dedup: true` handle an id at most once
      (`Converger.Backbone.Dispatch`), whichever backbone or path delivered
      it (a broker redelivery, a parked retry, a dual-publish mirror).
    * `topic` - `:activities`, `:deliveries` or `:events`
      (`Converger.Backbone.topics/0`).
    * `type` - the platform event type (`activity.created`,
      `delivery.failed`, see `Converger.Webhooks.Catalog`).
    * `tenant_id` - the tenant the event belongs to.
    * `key` - the partition key: events with the same key are delivered in
      publish order. The conversation id when there is one.
    * `data` - the payload, JSON-normalised (string keys) when the event is
      built, so every backbone hands subscribers the same map.
    * `occurred_at` - when the event was built (UTC, microseconds).

  On a broker the event is the JSON object of `to_map/1`
  (`"spec": "converger.backbone/1"`).
  """

  @spec_version "converger.backbone/1"

  @enforce_keys [:id, :topic, :type]
  defstruct [:id, :topic, :type, :tenant_id, :key, :occurred_at, data: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          topic: Converger.Backbone.topic(),
          type: String.t(),
          tenant_id: String.t() | nil,
          key: String.t() | nil,
          data: map(),
          occurred_at: DateTime.t()
        }

  @doc "The wire format version, `converger.backbone/1`."
  def spec_version, do: @spec_version

  @doc """
  Build an event of `topic` from `attrs` (`:type` required; `:id`,
  `:tenant_id`, `:key`, `:data`, `:occurred_at` optional). Without a `:key`
  the key is the data's `conversation_id`, else its `channel_id`, else the
  tenant id.
  """
  @spec new(Converger.Backbone.topic(), map() | keyword()) :: t()
  def new(topic, attrs) do
    attrs = Map.new(attrs)
    data = normalize(Map.get(attrs, :data, %{}))
    tenant_id = Map.get(attrs, :tenant_id)

    %__MODULE__{
      id: Map.get_lazy(attrs, :id, &Ecto.UUID.generate/0),
      topic: topic,
      type: Map.fetch!(attrs, :type),
      tenant_id: tenant_id,
      key: Map.get_lazy(attrs, :key, fn -> default_key(data, tenant_id) end),
      data: data,
      occurred_at: Map.get_lazy(attrs, :occurred_at, &DateTime.utc_now/0)
    }
  end

  defp default_key(data, tenant_id),
    do: data["conversation_id"] || data["channel_id"] || tenant_id

  defp normalize(data) when is_map(data), do: data |> Jason.encode!() |> Jason.decode!()

  @doc "The event as a JSON-safe map with string keys (the wire format)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "spec" => @spec_version,
      "id" => event.id,
      "topic" => Atom.to_string(event.topic),
      "type" => event.type,
      "tenant_id" => event.tenant_id,
      "key" => event.key,
      "data" => event.data,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at)
    }
  end

  @doc "Parse `to_map/1` output. Unknown topics are rejected."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"id" => id, "topic" => topic, "type" => type} = map)
      when is_binary(id) and is_binary(type) do
    with {:ok, topic} <- Converger.Backbone.parse_topic(topic),
         {:ok, occurred_at} <- occurred_at(map["occurred_at"]) do
      {:ok,
       %__MODULE__{
         id: id,
         topic: topic,
         type: type,
         tenant_id: map["tenant_id"],
         key: map["key"],
         data: if(is_map(map["data"]), do: map["data"], else: %{}),
         occurred_at: occurred_at
       }}
    end
  end

  def from_map(_map), do: {:error, :invalid_event}

  defp occurred_at(nil), do: {:ok, DateTime.utc_now()}

  defp occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, :invalid_occurred_at}
    end
  end

  defp occurred_at(_value), do: {:error, :invalid_occurred_at}

  @doc "Encode as JSON."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = event), do: event |> to_map() |> Jason.encode!()

  @doc "Decode JSON produced by `encode/1`."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> from_map(map)
      {:ok, _} -> {:error, :invalid_event}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc "Message headers carried next to the encoded event on brokers."
  @spec headers(t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{} = event) do
    [
      {"content-type", "application/json"},
      {"x-converger-event-id", event.id},
      {"x-converger-event", event.type}
    ] ++ if(event.tenant_id, do: [{"x-converger-tenant-id", event.tenant_id}], else: [])
  end
end
