defmodule Converger.Webhooks.Event do
  @moduledoc """
  One event sent (or to be sent) to one subscription (`webhook_events`).

  `event_id` identifies the occurrence and is the same for every
  subscription that receives it; `id` is this subscription's delivery of it
  (the `x-converger-delivery-id` header), stable across retries and
  redeliveries.

  Statuses: `pending` (queued or retrying), `delivered`, `failed`
  (dead-lettered: the retry policy is exhausted or the error is permanent;
  can be redelivered). Rows are pruned after the `:webhook_event_days`
  retention window (default 7, `Converger.Retention.prune/1`).
  """
  use Ecto.Schema

  @statuses ~w(pending delivered failed)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_events" do
    field :event_id, :binary_id
    field :type, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :response_status, :integer
    field :delivered_at, :utc_datetime_usec
    field :redelivered_at, :utc_datetime_usec

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :subscription, Converger.Webhooks.Subscription

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Valid event statuses."
  def statuses, do: @statuses
end
