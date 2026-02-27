defmodule Converger.RoutingRules.RoutingRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routing_rules" do
    field :name, :string
    field :target_channel_ids, {:array, :binary_id}, default: []
    field :enabled, :boolean, default: true

    belongs_to :tenant, Converger.Tenants.Tenant
    belongs_to :source_channel, Converger.Channels.Channel

    timestamps(type: :utc_datetime)
  end

  def changeset(routing_rule, attrs) do
    routing_rule
    |> cast(attrs, [:name, :source_channel_id, :target_channel_ids, :enabled, :tenant_id])
    |> validate_required([:name, :source_channel_id, :target_channel_ids, :tenant_id])
    |> validate_length(:target_channel_ids, min: 1, max: 20)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:source_channel_id)
    |> unique_constraint([:tenant_id, :name])
    |> validate_no_self_reference()
  end

  defp validate_no_self_reference(changeset) do
    source = get_field(changeset, :source_channel_id)
    targets = get_field(changeset, :target_channel_ids) || []

    if source && source in targets do
      add_error(changeset, :target_channel_ids, "cannot include the source channel")
    else
      changeset
    end
  end
end
