defmodule Converger.Deliveries.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending sent delivered read failed)
  @status_rank %{"pending" => 0, "sent" => 1, "delivered" => 2, "read" => 3, "failed" => -1}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "deliveries" do
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :sent_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec
    field :provider_message_id, :string
    field :metadata, :map, default: %{}

    belongs_to :activity, Converger.Activities.Activity
    belongs_to :channel, Converger.Channels.Channel

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def status_rank(status), do: Map.get(@status_rank, status, -1)

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :status,
      :attempts,
      :last_error,
      :sent_at,
      :delivered_at,
      :read_at,
      :provider_message_id,
      :metadata,
      :activity_id,
      :channel_id
    ])
    |> validate_required([:activity_id, :channel_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:activity_id, :channel_id])
  end
end
