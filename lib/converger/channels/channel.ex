defmodule Converger.Channels.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channels" do
    field :name, :string
    field :type, :string, default: "webhook"
    field :secret, :string
    field :status, :string, default: "active"
    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :status, :tenant_id, :type, :secret])
    |> validate_required([:name, :status, :tenant_id])
    |> validate_inclusion(:type, ["echo", "webhook"])
    |> unique_constraint([:tenant_id, :name])
    |> ensure_secret()
  end

  defp ensure_secret(changeset) do
    if get_field(changeset, :secret) do
      changeset
    else
      put_change(changeset, :secret, generate_secret())
    end
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
