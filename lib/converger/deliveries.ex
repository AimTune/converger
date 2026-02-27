defmodule Converger.Deliveries do
  @moduledoc """
  The Deliveries context. Tracks delivery status of activities to external channels.
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

  def mark_delivered(delivery, response_metadata \\ %{}) do
    delivery
    |> Delivery.changeset(%{
      status: "delivered",
      delivered_at: DateTime.utc_now(),
      attempts: delivery.attempts + 1,
      metadata: Map.merge(delivery.metadata || %{}, response_metadata)
    })
    |> Repo.update()
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

  def count_by_status do
    from(d in Delivery,
      group_by: d.status,
      select: {d.status, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, value}, q when is_binary(value) -> where(q, status: ^value)
      {:channel_id, value}, q -> where(q, channel_id: ^value)
      {:activity_id, value}, q -> where(q, activity_id: ^value)
      _, q -> q
    end)
  end
end
