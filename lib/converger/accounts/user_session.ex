defmodule Converger.Accounts.UserSession do
  @moduledoc """
  A server-side browser session of an admin (`user_type` `"admin"`) or tenant
  portal user (`"tenant"`), see `Converger.Accounts.Sessions`. Only the
  SHA-256 of the session token is stored; the token itself lives in the
  signed session cookie.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_sessions" do
    field :user_type, :string
    field :user_id, :binary_id
    field :token_hash, :binary, redact: true
    field :ip, :string
    field :user_agent, :string
    field :last_seen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
