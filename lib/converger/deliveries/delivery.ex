defmodule Converger.Deliveries.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "deliveries" do
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :delivered_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :activity, Converger.Activities.Activity
    belongs_to :channel, Converger.Channels.Channel

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :status,
      :attempts,
      :last_error,
      :delivered_at,
      :metadata,
      :activity_id,
      :channel_id
    ])
    |> validate_required([:activity_id, :channel_id])
    |> validate_inclusion(:status, ~w(pending delivered failed))
    |> unique_constraint([:activity_id, :channel_id])
  end
end
