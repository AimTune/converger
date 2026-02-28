defmodule Converger.Accounts.TenantUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenant_users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :name, :string
    field :role, :string, default: "member"
    field :status, :string, default: "active"

    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @valid_roles ~w(owner admin member viewer)

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :name, :role, :status, :tenant_id])
    |> validate_required([:email, :password, :name, :tenant_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, ~w(active inactive))
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :email])
    |> hash_password()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :role, :status])
    |> validate_required([:email, :name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, ~w(active inactive))
    |> unique_constraint([:tenant_id, :email])
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _), do: Bcrypt.no_user_verify()

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end
end
