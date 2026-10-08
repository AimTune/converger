defmodule Converger.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "conversations" do
    field :status, :string, default: "active"
    # Highest activity `seq` handed out in this conversation (server-managed).
    field :last_seq, :integer, default: 0
    field :metadata, :map, default: %{}

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :channel, Converger.Channels.Channel

    has_many :activities, Converger.Activities.Activity

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:status, :metadata, :tenant_id, :channel_id])
    |> validate_required([:status, :tenant_id, :channel_id])
    |> validate_inclusion(:status, ~w(active closed))
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:channel_id)
  end
end
