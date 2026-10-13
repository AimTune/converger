defmodule Converger.Accounts.AccountToken do
  @moduledoc """
  A single-use token mailed to an admin (`user_type` `"admin"`) or tenant
  user (`"tenant"`), e.g. a password reset link (`context`
  `"reset_password"`). Only the SHA-256 of the token is stored. `sent_to` is
  the address the token was mailed to: the token is void once the account's
  email differs. See `Converger.Accounts.PasswordReset`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "account_tokens" do
    field :user_type, :string
    field :user_id, :binary_id
    field :context, :string
    field :token_hash, :binary, redact: true
    field :sent_to, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
