defmodule Converger.AccountsFixtures do
  @moduledoc """
  Admin and tenant users for tests, plus TOTP helpers (ADR-0058).
  """

  alias Converger.Accounts
  alias Converger.Repo

  def valid_password, do: "correct-horse-battery"

  def unique_email(prefix \\ "user"),
    do: "#{prefix}-#{System.unique_integer([:positive])}@test.com"

  def admin_user_fixture(attrs \\ %{}) do
    {:ok, admin} =
      attrs
      |> Enum.into(%{
        email: unique_email("admin"),
        password: valid_password(),
        name: "Admin",
        role: "super_admin"
      })
      |> Accounts.create_admin_user()

    admin
  end

  def tenant_user_fixture(tenant, attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: unique_email("member"),
        password: valid_password(),
        name: "Member",
        role: "owner",
        tenant_id: tenant.id
      })
      |> Accounts.create_tenant_user()

    user
  end

  @doc "Turns TOTP 2FA on for `user` with a fresh secret."
  def enable_totp(user) do
    user
    |> Ecto.Changeset.change(
      totp_secret: NimbleTOTP.secret(),
      totp_enabled_at: DateTime.utc_now(),
      totp_last_step: nil
    )
    |> Repo.update!()
  end

  @doc "The current TOTP code of `user` (or of a step `offset` steps away)."
  def totp_code(user, offset \\ 0) do
    NimbleTOTP.verification_code(user.totp_secret, time: System.os_time(:second) + offset * 30)
  end

  @doc "A random client IP, so per-IP rate limit counters start empty."
  def unique_ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
