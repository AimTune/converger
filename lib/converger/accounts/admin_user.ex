defmodule Converger.Accounts.AdminUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "admin_users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :name, :string
    field :role, :string, default: "admin"
    field :status, :string, default: "active"
    # Set programmatically (never cast) for bootstrap accounts with a
    # generated password; cleared by password_changeset/2.
    field :must_change_password, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @valid_roles ~w(super_admin admin viewer)

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :name, :role, :status])
    |> validate_required([:email, :password, :name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, ~w(active inactive))
    |> unique_constraint(:email)
    |> hash_password()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :role, :status])
    |> validate_required([:email, :name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, ~w(active inactive))
    |> unique_constraint(:email)
  end

  @doc "Sets a new password and clears `must_change_password`."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_confirmation(:password, message: "does not match password")
    |> hash_password()
    |> put_change(:must_change_password, false)
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
