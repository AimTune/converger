defmodule Converger.Accounts.PasswordResetTest do
  use Converger.DataCase, async: true

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures
  import Swoosh.TestAssertions

  alias Converger.Accounts
  alias Converger.Accounts.{AccountToken, AdminUser, PasswordReset, Sessions}
  alias Converger.AuditLogs

  @new_password %{
    "password" => "brand-new-password",
    "password_confirmation" => "brand-new-password"
  }

  # Requests a reset for the admin and returns the token from the mailed link.
  defp request_admin_reset(email) do
    :ok = PasswordReset.deliver_admin_instructions(email, &"https://converger.test/reset/#{&1}")

    assert_email_sent(fn sent ->
      assert [{_, ^email}] = sent.to
      [_, token] = Regex.run(~r{/reset/([A-Za-z0-9_-]+)}, sent.text_body)
      send(self(), {:token, token})
    end)

    assert_received {:token, token}
    token
  end

  test "mails a single-use link and stores only the token hash" do
    admin = admin_user_fixture()
    token = request_admin_reset(admin.email)

    assert [%AccountToken{token_hash: hash, sent_to: sent_to, context: "reset_password"}] =
             Repo.all(AccountToken)

    assert hash == :crypto.hash(:sha256, token)
    assert sent_to == admin.email
    assert PasswordReset.get_user_by_token("admin", token).id == admin.id
    assert PasswordReset.get_user_by_token("tenant", token) == nil

    assert {:ok, _} = PasswordReset.reset_password("admin", token, @new_password)
    assert {:ok, _} = Accounts.authenticate_admin(admin.email, "brand-new-password")

    # single use
    assert {:error, :invalid_token} = PasswordReset.reset_password("admin", token, @new_password)
    assert Repo.all(AccountToken) == []
  end

  test "unknown and inactive accounts get no mail, and the same answer" do
    assert :ok = PasswordReset.deliver_admin_instructions("nobody@test.com", & &1)

    inactive = admin_user_fixture(%{status: "inactive"})
    assert :ok = PasswordReset.deliver_admin_instructions(inactive.email, & &1)

    tenant = tenant_fixture()
    user = tenant_user_fixture(tenant)
    assert :ok = PasswordReset.deliver_tenant_instructions("no-such-tenant", user.email, & &1)
    assert :ok = PasswordReset.deliver_tenant_instructions(tenant.name, "nobody@test.com", & &1)

    assert_no_email_sent()
    assert Repo.all(AccountToken) == []
  end

  test "tenant users are matched by tenant name and email" do
    tenant = tenant_fixture()
    user = tenant_user_fixture(tenant)

    :ok = PasswordReset.deliver_tenant_instructions(tenant.name, user.email, &"/r/#{&1}")
    assert_email_sent(to: user.email)
    assert [%AccountToken{user_type: "tenant"}] = Repo.all(AccountToken)
  end

  test "links expire after one hour" do
    admin = admin_user_fixture()
    token = request_admin_reset(admin.email)

    Repo.update_all(AccountToken,
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -3_601, :second)]
    )

    assert PasswordReset.get_user_by_token("admin", token) == nil
    assert {:error, :invalid_token} = PasswordReset.reset_password("admin", token, @new_password)
    assert PasswordReset.prune() == 1
  end

  test "a link is void once the email changed or the password changed otherwise" do
    admin = admin_user_fixture()
    token = request_admin_reset(admin.email)
    {:ok, _} = Accounts.update_admin_user(admin, %{email: "moved-#{admin.email}"})
    assert PasswordReset.get_user_by_token("admin", token) == nil

    other = admin_user_fixture()
    token = request_admin_reset(other.email)
    {:ok, _} = Accounts.change_admin_password(other, valid_password(), @new_password)
    assert PasswordReset.get_user_by_token("admin", token) == nil
  end

  test "a reset clears must_change_password, ends every session and is audit-logged" do
    {:ok, admin, :generated, _} = Accounts.bootstrap_super_admin([])
    assert admin.must_change_password
    {:ok, _, _} = Sessions.create("admin", admin)
    {:ok, _, _} = Sessions.create("admin", admin)

    token = request_admin_reset(admin.email)
    assert {:ok, updated} = PasswordReset.reset_password("admin", token, @new_password)

    refute updated.must_change_password
    refute Repo.get!(AdminUser, admin.id).must_change_password
    assert Sessions.list("admin", admin.id) == []

    assert [%{actor_id: actor_id, changes: %{"password" => "[changed]"}}] =
             AuditLogs.list_audit_logs(%{"action" => "reset_password"})

    assert actor_id == admin.id
  end

  test "the new password must satisfy the policy and confirmation" do
    admin = admin_user_fixture()
    token = request_admin_reset(admin.email)

    assert {:error, changeset} =
             PasswordReset.reset_password("admin", token, %{
               "password" => "short",
               "password_confirmation" => "short"
             })

    assert %{password: [_ | _]} = errors_on(changeset)

    assert {:error, changeset} =
             PasswordReset.reset_password("admin", token, %{
               "password" => "brand-new-password",
               "password_confirmation" => "different-password"
             })

    assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    # failed attempts do not use the token up
    assert PasswordReset.get_user_by_token("admin", token)
  end
end
