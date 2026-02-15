defmodule Converger.Activities.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "activities" do
    field :type, :string, default: "message"
    field :sender, :string
    field :text, :string
    field :attachments, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    field :idempotency_key, :string

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :conversation, Converger.Conversations.Conversation

    # We use timestamps but need to ensure inserted_at is handled correctly if we want custom ordering.
    # However, standard Ecto timestamps are fine for "created_at".
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :type,
      :sender,
      :text,
      :attachments,
      :metadata,
      :idempotency_key,
      :tenant_id,
      :conversation_id,
      :inserted_at
    ])
    |> validate_required([:sender, :tenant_id, :conversation_id])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :idempotency_key])
  end
end
