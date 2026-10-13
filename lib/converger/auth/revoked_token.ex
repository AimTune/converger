defmodule Converger.Auth.RevokedToken do
  @moduledoc """
  A Converger token revocation (`Converger.Auth.Revocations`).

    * `key`: `"fam:<family>"` (a token family: every token issued, derived or
      refreshed from one generated token), `"jti:<jti>"` (one token, rotated
      by a refresh) or `"user:<channel_id>:<user_id>"` (every token of an end
      user issued up to `revoked_at`).
    * `kind`: `"revoked"`, or `"rotated"` for a refreshed token, which stays
      usable for the rotation grace period.
    * `expires_at`: when every token the row can match has expired; the row
      is pruned after that.
  """
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "revoked_tokens" do
    field :kind, :string
    field :tenant_id, :binary_id
    field :revoked_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end
end
