defmodule Converger.Channels.Outbox do
  @moduledoc """
  The outbox of an `http_pull` channel (`Converger.Channels.Adapters.HttpPull`):
  what `GET /api/v1/channels/:id/outbox` serves and acknowledges.

  ## Watermarks

  A watermark is an opaque string naming a position in the outbox (the
  `(inserted_at, id)` of a delivery, base64url-encoded). Each page returns
  the watermark of its last item. Sending it back acknowledges every served
  item up to it (`Converger.Deliveries.acknowledge_outbox/2`) and the
  response is the next page. Unacknowledged items stay in the outbox and are
  served again, oldest first, so a consumer that loses a page loses nothing.
  """

  alias Converger.Activities.{Activity, Serializer}
  alias Converger.Channels.Adapters.HttpPull
  alias Converger.{Deliveries, Repo}

  import Ecto.Query, only: [from: 2]

  @default_limit 50
  @max_limit 200

  @doc "Default and maximum page sizes."
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc """
  Acknowledges up to `watermark` (when given) and returns the next page:
  `{:ok, %{items: [...], watermark: string | nil, has_more: boolean,
  acknowledged: count}}`, or `{:error, :invalid_watermark}`.
  """
  def poll(channel, watermark, limit) do
    with {:ok, position} <- decode_watermark(watermark) do
      acknowledged = if position, do: Deliveries.acknowledge_outbox(channel.id, position), else: 0
      {deliveries, more?} = Deliveries.outbox_page(channel.id, limit)

      {:ok,
       %{
         items: items(deliveries),
         watermark:
           case List.last(deliveries) do
             nil -> watermark
             last -> encode_watermark(last)
           end,
         has_more: more?,
         acknowledged: acknowledged
       }}
    end
  end

  @doc "Acknowledges up to `watermark`: `{:ok, count}` or `{:error, :invalid_watermark}`."
  def acknowledge(channel, watermark) do
    case decode_watermark(watermark) do
      {:ok, nil} -> {:error, :invalid_watermark}
      {:ok, position} -> {:ok, Deliveries.acknowledge_outbox(channel.id, position)}
      error -> error
    end
  end

  defp items(deliveries) do
    # Deliveries handed off before the adapter stored payloads (none today)
    # fall back to the stored activity.
    missing = for d <- deliveries, is_nil(d.metadata[HttpPull.payload_key()]), do: d.activity_id

    fallback =
      if missing == [],
        do: %{},
        else:
          from(a in Activity, where: a.id in ^missing)
          |> Repo.all()
          |> Map.new(&{&1.id, Serializer.canonical(&1)})

    Enum.map(deliveries, fn d ->
      %{
        delivery_id: d.id,
        activity: d.metadata[HttpPull.payload_key()] || fallback[d.activity_id],
        queued_at: d.inserted_at,
        served_before: not is_nil(d.metadata["outbox_served_at"])
      }
    end)
  end

  @doc "The watermark of a delivery's position."
  def encode_watermark(%{inserted_at: %DateTime{} = at, id: id}) do
    Base.url_encode64("v1:#{DateTime.to_unix(at, :microsecond)}:#{id}", padding: false)
  end

  @doc """
  Decodes a watermark: `{:ok, nil}` for none, `{:ok, {inserted_at, id}}`,
  or `{:error, :invalid_watermark}`.
  """
  def decode_watermark(nil), do: {:ok, nil}
  def decode_watermark(""), do: {:ok, nil}

  def decode_watermark(watermark) when is_binary(watermark) do
    with {:ok, decoded} <- Base.url_decode64(watermark, padding: false),
         ["v1", micros, id] <- String.split(decoded, ":", parts: 3),
         {micros, ""} <- Integer.parse(micros),
         {:ok, at} <- DateTime.from_unix(micros, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> {:error, :invalid_watermark}
    end
  end

  def decode_watermark(_watermark), do: {:error, :invalid_watermark}
end
