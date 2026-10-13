defmodule Converger.Accounts.TenantUser do
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Accounts.{PasswordHasher, PasswordPolicy}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenant_users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :name, :string
    field :role, :string, default: "member"
    field :status, :string, default: "active"
    # TOTP two-factor authentication (ADR-0058). The secret is encrypted at
    # rest; 2FA is on once `totp_enabled_at` is set (a secret without it is a
    # pending enrollment). `totp_last_step` is the last accepted 30 s time
    # step, so a code cannot be used twice.
    field :totp_secret, Converger.Encrypted.Binary, redact: true
    field :totp_enabled_at, :utc_datetime_usec
    field :totp_last_step, :integer

    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @valid_roles ~w(owner admin member viewer)

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :name, :role, :status, :tenant_id])
    |> validate_required([:email, :password, :name, :tenant_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> PasswordPolicy.validate()
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
    |> PasswordPolicy.validate()
    |> validate_confirmation(:password, message: "does not match password")
    |> hash_password()
  end

  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) do
    PasswordHasher.verify_pass(password, hash)
  end

  def valid_password?(_, _), do: PasswordHasher.no_user_verify()

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, PasswordHasher.hash_pwd_salt(password))
    end
  end
end
