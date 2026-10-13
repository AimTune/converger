defmodule Converger.ApiKeys.ApiKey do
  @moduledoc """
  A scoped tenant API key (ADR-0061). The plaintext key is only set right
  after creation (virtual `key`), to be shown once; `key_hash` is its
  SHA-256 and `prefix` the start of it, kept for display.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Tenants.Tenant

  @scopes ~w(read write manage)
  # Characters of the random part kept in `prefix`, after "cvg_live_".
  @display_chars 4

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :name, :string
    field :key, :string, virtual: true, redact: true
    field :key_hash, :binary, redact: true
    field :prefix, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    # Who issued the key: "admin_api", "admin:<id>", "api_key:<id>", ...
    field :created_by, :string

    belongs_to :tenant, Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every scope: `read`, `write`, `manage`."
  def scopes, do: @scopes

  @doc false
  def create_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :scopes, :expires_at])
    |> validate_required([:name, :scopes])
    |> validate_length(:name, max: 255)
    |> update_change(:scopes, &(&1 |> Enum.uniq() |> Enum.sort()))
    |> validate_length(:scopes, min: 1)
    |> validate_subset(:scopes, @scopes)
    |> validate_change(:expires_at, fn :expires_at, expires_at ->
      if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
        do: [],
        else: [expires_at: "must be in the future"]
    end)
    |> put_key()
    |> unique_constraint(:key_hash)
  end

  @doc "Whether the key is usable now: not revoked and not expired."
  def active?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true

  def active?(%__MODULE__{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  def active?(%__MODULE__{}), do: false

  defp put_key(%Ecto.Changeset{valid?: true} = changeset) do
    key = Tenant.generate_api_key()
    prefix_length = String.length(Tenant.api_key_prefix()) + @display_chars

    changeset
    |> put_change(:key, key)
    |> put_change(:key_hash, Converger.Secrets.hash(key))
    |> put_change(:prefix, String.slice(key, 0, prefix_length))
  end

  defp put_key(changeset), do: changeset
end
