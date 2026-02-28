defmodule Converger.AuditLogs.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :actor_type, :string
    field :actor_id, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :changes, :map

    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_actor_types ~w(admin tenant_api tenant_user system)
  @valid_actions ~w(create update delete toggle_status toggle_enabled)
  @valid_resource_types ~w(tenant channel routing_rule admin_user tenant_user)

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :tenant_id,
      :actor_type,
      :actor_id,
      :action,
      :resource_type,
      :resource_id,
      :changes
    ])
    |> validate_required([:actor_type, :actor_id, :action, :resource_type, :resource_id])
    |> validate_inclusion(:actor_type, @valid_actor_types)
    |> validate_inclusion(:action, @valid_actions)
    |> validate_inclusion(:resource_type, @valid_resource_types)
  end
end
