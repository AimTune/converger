defmodule Converger.Deliveries do
  @moduledoc """
  The Deliveries context. Tracks delivery status of activities to external channels,
  including delivery receipts and read receipts from providers.

  Status lifecycle: pending → sent → delivered → read (failed at any point).
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.Deliveries.Delivery

  def list_deliveries(filters \\ %{}) do
    Delivery
    |> apply_filters(filters)
    |> Repo.all()
  end

  def get_delivery!(id), do: Repo.get!(Delivery, id)

  def get_delivery_for_activity_and_channel(activity_id, channel_id) do
    Repo.get_by(Delivery, activity_id: activity_id, channel_id: channel_id)
  end

  def get_or_create_delivery(activity_id, channel_id) do
    case get_delivery_for_activity_and_channel(activity_id, channel_id) do
      %Delivery{} = delivery ->
        delivery

      nil ->
        {:ok, delivery} =
          create_delivery(%{activity_id: activity_id, channel_id: channel_id})

        delivery
    end
  end

  def create_delivery(attrs) do
    %Delivery{}
    |> Delivery.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Mark a delivery as sent (message left our system successfully).
  Extracts provider_message_id from response metadata for future receipt correlation.
  """
  def mark_sent(delivery, response_metadata \\ %{}) do
    provider_msg_id =
      response_metadata[:whatsapp_message_id] ||
        response_metadata[:infobip_message_id] ||
        response_metadata["whatsapp_message_id"] ||
        response_metadata["infobip_message_id"]

    attrs = %{
      status: "sent",
      sent_at: DateTime.utc_now(),
      attempts: delivery.attempts + 1,
      metadata: Map.merge(delivery.metadata || %{}, response_metadata)
    }

    attrs =
      if provider_msg_id,
        do: Map.put(attrs, :provider_message_id, to_string(provider_msg_id)),
        else: attrs

    case delivery |> Delivery.changeset(attrs) |> Repo.update() do
      {:ok, updated} = result ->
        broadcast_status_update(updated)
        result

      error ->
        error
    end
  end

  @doc deprecated: "Use mark_sent/2 instead"
  def mark_delivered(delivery, response_metadata \\ %{}) do
    mark_sent(delivery, response_metadata)
  end

  def mark_attempt_failed(delivery, error_message) do
    new_attempts = delivery.attempts + 1
    status = if new_attempts >= 5, do: "failed", else: "pending"

    delivery
    |> Delivery.changeset(%{
      status: status,
      attempts: new_attempts,
      last_error: error_message
    })
    |> Repo.update()
  end

  # --- Receipt / Status Update Processing ---

  @doc """
  Apply a status update from an external provider.
  Looks up the delivery by provider_message_id or delivery_id, then
  advances the status monotonically.
  """
  def apply_status_update(channel_id, %{"provider_message_id" => pmid} = update)
      when is_binary(pmid) and pmid != "" do
    case get_delivery_by_provider_message_id(channel_id, pmid) do
      %Delivery{} = delivery -> advance_status(delivery, update)
      nil -> {:error, :delivery_not_found}
    end
  end

  def apply_status_update(_channel_id, %{"delivery_id" => delivery_id} = update)
      when is_binary(delivery_id) and delivery_id != "" do
    case Repo.get(Delivery, delivery_id) do
      %Delivery{} = delivery -> advance_status(delivery, update)
      nil -> {:error, :delivery_not_found}
    end
  end

  def apply_status_update(_channel_id, _update), do: {:error, :missing_identifier}

  @doc """
  Find a delivery by its provider message ID, scoped to a channel.
  """
  def get_delivery_by_provider_message_id(channel_id, provider_message_id) do
    Repo.get_by(Delivery,
      channel_id: channel_id,
      provider_message_id: provider_message_id
    )
  end

  @doc """
  Advance a delivery's status following monotonic progression rules.
  Ignores stale updates (e.g., "delivered" arriving after "read").
  Broadcasts the update via PubSub.
  """
  def advance_status(delivery, update) do
    new_status = update["status"]
    current_rank = Delivery.status_rank(delivery.status)
    new_rank = Delivery.status_rank(new_status)

    should_update =
      cond do
        new_status == "failed" and delivery.status not in ["read"] -> true
        new_rank > current_rank and current_rank >= 0 -> true
        true -> false
      end

    if should_update do
      timestamp = parse_provider_timestamp(update["timestamp"])

      attrs =
        %{status: new_status}
        |> maybe_put(:sent_at, new_status == "sent", timestamp)
        |> maybe_put(:delivered_at, new_status == "delivered", timestamp)
        |> maybe_put(:read_at, new_status == "read", timestamp)
        |> maybe_put(:last_error, new_status == "failed", update["error"])

      case delivery |> Delivery.changeset(attrs) |> Repo.update() do
        {:ok, updated} = result ->
          broadcast_status_update(updated)
          result

        error ->
          error
      end
    else
      {:ok, delivery}
    end
  end

  # --- Query Helpers ---

  @doc """
  List deliveries for a set of activity IDs (batch query for conversation show page).
  """
  def list_deliveries_for_activities(activity_ids) when is_list(activity_ids) do
    from(d in Delivery,
      where: d.activity_id in ^activity_ids,
      order_by: [desc: d.updated_at]
    )
    |> Repo.all()
  end

  def list_deliveries_for_activities(_), do: []

  def count_by_status do
    from(d in Delivery,
      group_by: d.status,
      select: {d.status, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # --- Private Helpers ---

  defp broadcast_status_update(delivery) do
    delivery = Repo.preload(delivery, :activity)

    if delivery.activity do
      ConvergerWeb.Endpoint.broadcast!(
        "conversation:#{delivery.activity.conversation_id}",
        "delivery_status",
        %{
          delivery_id: delivery.id,
          activity_id: delivery.activity_id,
          channel_id: delivery.channel_id,
          status: delivery.status,
          sent_at: delivery.sent_at,
          delivered_at: delivery.delivered_at,
          read_at: delivery.read_at
        }
      )
    end
  end

  defp parse_provider_timestamp(nil), do: DateTime.utc_now()

  defp parse_provider_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Integer.parse(ts) do
          {unix, _} -> DateTime.from_unix!(unix)
          :error -> DateTime.utc_now()
        end
    end
  end

  defp parse_provider_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp parse_provider_timestamp(_), do: DateTime.utc_now()

  defp maybe_put(map, _key, false, _val), do: map
  defp maybe_put(map, key, true, val), do: Map.put(map, key, val)

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, value}, q when is_binary(value) -> where(q, status: ^value)
      {:channel_id, value}, q -> where(q, channel_id: ^value)
      {:activity_id, value}, q -> where(q, activity_id: ^value)
      _, q -> q
    end)
  end
end
