defmodule Converger.Channels.HealthCheck do
  use Ecto.Schema
  import Ecto.Changeset

  @health_statuses ~w(healthy degraded unhealthy unknown)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channel_health_checks" do
    field :status, :string
    field :total_deliveries, :integer, default: 0
    field :failed_deliveries, :integer, default: 0
    field :failure_rate, :float, default: 0.0
    field :checked_at, :utc_datetime_usec

    belongs_to :channel, Converger.Channels.Channel

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def health_statuses, do: @health_statuses

  @doc false
  def changeset(health_check, attrs) do
    health_check
    |> cast(attrs, [:channel_id, :status, :total_deliveries, :failed_deliveries, :failure_rate, :checked_at])
    |> validate_required([:channel_id, :status, :total_deliveries, :failed_deliveries, :failure_rate, :checked_at])
    |> validate_inclusion(:status, @health_statuses)
    |> validate_number(:failure_rate, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
