defmodule Converger.Accounts.TOTPTest do
  # One test changes the global :require_2fa_roles.
  use Converger.DataCase, async: false

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures

  alias Converger.Accounts.{AdminUser, TenantUser, TOTP}
  alias Converger.AuditLogs

  defp code_at(user, time), do: NimbleTOTP.verification_code(user.totp_secret, time: time)

  # A time in the middle of a 30 s step, so `time - 30` is the previous step.
  defp step_time, do: div(System.os_time(:second), 30) * 30 + 15

  test "enrollment stores an encrypted secret and is confirmed with a code" do
    admin = admin_user_fixture()
    refute TOTP.enabled?(admin)

    {:ok, admin} = TOTP.begin_enrollment(admin)
    assert TOTP.pending?(admin)
    refute TOTP.enabled?(admin)
    assert byte_size(admin.totp_secret) == 20
    assert TOTP.base32_secret(admin) =~ ~r/^[A-Z2-7]+$/
    assert TOTP.otpauth_uri(admin) =~ "otpauth://totp/Converger:"
    assert TOTP.otpauth_uri(admin) =~ "secret=#{TOTP.base32_secret(admin)}"

    # stored encrypted
    [[raw]] =
      Repo.query!("SELECT totp_secret FROM admin_users WHERE id = $1", [
        Ecto.UUID.dump!(admin.id)
      ]).rows

    refute raw == admin.totp_secret

    assert {:error, :invalid_code} = TOTP.confirm_enrollment(admin, "000000x")
    now = step_time()
    assert {:ok, admin} = TOTP.confirm_enrollment(admin, code_at(admin, now), now: now)
    assert TOTP.enabled?(admin)
    assert admin.totp_last_step == div(now, 30)

    assert [%{action: "enable_2fa", resource_type: "admin_user"}] =
             AuditLogs.list_audit_logs(%{"action" => "enable_2fa"})

    assert {:error, :already_enabled} = TOTP.begin_enrollment(admin)
  end

  test "a code is accepted once; the previous step is accepted for clock skew" do
    admin = admin_user_fixture() |> enable_totp()
    now = step_time()

    assert :ok = TOTP.verify(admin, code_at(admin, now - 30), now: now)
    admin = Repo.get!(AdminUser, admin.id)

    # the same code again is rejected, and so is an older one
    assert :error = TOTP.verify(admin, code_at(admin, now - 30), now: now)

    # the current step's code still works once
    assert :ok = TOTP.verify(admin, code_at(admin, now), now: now)
    admin = Repo.get!(AdminUser, admin.id)
    assert :error = TOTP.verify(admin, code_at(admin, now), now: now)
    assert :error = TOTP.verify(admin, code_at(admin, now - 30), now: now)
  end

  test "reuse is rejected even with a stale struct (concurrent requests)" do
    admin = admin_user_fixture() |> enable_totp()
    now = step_time()
    code = code_at(admin, now)

    assert :ok = TOTP.verify(admin, code, now: now)
    # `admin` still has totp_last_step nil, as a concurrent request would
    assert :error = TOTP.verify(admin, code, now: now)
  end

  test "wrong, malformed and out-of-window codes are rejected" do
    admin = admin_user_fixture() |> enable_totp()
    now = step_time()

    assert :error = TOTP.verify(admin, "123", now: now)
    assert :error = TOTP.verify(admin, nil, now: now)
    assert :error = TOTP.verify(admin, code_at(admin, now - 60), now: now)
    assert :error = TOTP.verify(admin, code_at(admin, now + 30), now: now)
    # spaces are ignored
    <<a::binary-3, b::binary-3>> = code_at(admin, now)
    assert :ok = TOTP.verify(admin, a <> " " <> b, now: now)
  end

  test "users without 2FA never verify" do
    admin = admin_user_fixture()
    assert :error = TOTP.verify(admin, "123456")
  end

  test "disable needs a current code or the password" do
    admin = admin_user_fixture() |> enable_totp()

    assert {:error, :invalid} = TOTP.disable(admin, "wrong")
    assert {:ok, disabled} = TOTP.disable(admin, valid_password())
    refute TOTP.enabled?(disabled)
    assert disabled.totp_secret == nil

    tenant = tenant_fixture()
    user = tenant_user_fixture(tenant) |> enable_totp()
    now = step_time()
    assert {:ok, user} = TOTP.disable(user, code_at(user, now), now: now)
    refute TOTP.enabled?(Repo.get!(TenantUser, user.id))

    assert [%{action: "disable_2fa", tenant_id: tenant_id}] =
             AuditLogs.list_audit_logs(%{"action" => "disable_2fa", "tenant_id" => tenant.id})

    assert tenant_id == tenant.id
  end

  test "reset turns 2FA off and is audit-logged with the actor" do
    admin = admin_user_fixture() |> enable_totp()
    {:ok, reset} = TOTP.reset(admin, %{type: "admin", id: "boss@test.com"})
    refute TOTP.enabled?(reset)

    assert [%{actor_id: "boss@test.com", resource_id: resource_id}] =
             AuditLogs.list_audit_logs(%{"action" => "reset_2fa"})

    assert resource_id == admin.id
  end

  test "reencrypt_all rewrites every stored secret, keeping its value" do
    admin = admin_user_fixture() |> enable_totp()
    user = tenant_user_fixture(tenant_fixture()) |> enable_totp()

    assert TOTP.reencrypt_all() >= 2
    assert Repo.get!(AdminUser, admin.id).totp_secret == admin.totp_secret
    assert Repo.get!(TenantUser, user.id).totp_secret == user.totp_secret
  end

  test "enrollment is required for the configured admin roles only" do
    super_admin = admin_user_fixture(%{role: "super_admin"})
    admin = admin_user_fixture(%{role: "admin"})
    tenant_user = tenant_user_fixture(tenant_fixture())

    # config/test.exs requires no role
    refute TOTP.enrollment_required?(super_admin)

    previous = Application.get_env(:converger, :require_2fa_roles)
    Application.put_env(:converger, :require_2fa_roles, ["super_admin"])
    on_exit(fn -> Application.put_env(:converger, :require_2fa_roles, previous) end)

    assert TOTP.enrollment_required?(super_admin)
    refute TOTP.enrollment_required?(admin)
    refute TOTP.enrollment_required?(tenant_user)
    refute TOTP.enrollment_required?(enable_totp(super_admin))
  end
end
