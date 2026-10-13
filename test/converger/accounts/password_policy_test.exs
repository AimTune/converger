defmodule Converger.Accounts.PasswordPolicyTest do
  # Changes the global :password_min_length in some tests.
  use Converger.DataCase, async: false

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures

  alias Converger.Accounts
  alias Converger.Accounts.{AdminUser, PasswordPolicy, TenantUser}

  defp admin_errors(password, email \\ "ops@example.com") do
    %AdminUser{}
    |> AdminUser.registration_changeset(%{email: email, password: password, name: "Ops"})
    |> errors_on()
    |> Map.get(:password, [])
  end

  test "requires 12 characters by default" do
    assert PasswordPolicy.min_length() == 12
    assert "must be at least 12 characters" in admin_errors("elevenchars")
    assert admin_errors("twelve-chars") == []
  end

  test "the minimum length is configurable" do
    previous = Application.get_env(:converger, :password_min_length)
    Application.put_env(:converger, :password_min_length, 16)
    on_exit(fn -> Application.put_env(:converger, :password_min_length, previous) end)

    assert "must be at least 16 characters" in admin_errors("fifteen-chars-x")
    assert admin_errors("sixteen-chars-xx") == []
  end

  test "rejects more than 72 bytes (bcrypt truncation)" do
    assert admin_errors(String.duplicate("a", 72)) == []
    assert "must be at most 72 bytes" in admin_errors(String.duplicate("a", 73))
    # multi-byte characters count as bytes
    assert "must be at most 72 bytes" in admin_errors(String.duplicate("é", 37))
  end

  test "rejects passwords that equal or contain the email address" do
    assert "must not contain the email address" in admin_errors("ops@example.com")
    assert "must not contain the email address" in admin_errors("my-OPS@example.com-pw")
    assert admin_errors("ops-example-password") == []
  end

  test "applies to tenant users and to password changes" do
    tenant = tenant_fixture()

    changeset =
      TenantUser.registration_changeset(%TenantUser{}, %{
        email: "member@example.com",
        password: "short",
        name: "Member",
        tenant_id: tenant.id
      })

    assert "must be at least 12 characters" in errors_on(changeset).password

    admin = admin_user_fixture()

    assert {:error, changeset} =
             Accounts.change_admin_password(admin, valid_password(), %{
               "password" => admin.email <> "-1",
               "password_confirmation" => admin.email <> "-1"
             })

    assert "must not contain the email address" in errors_on(changeset).password

    user = tenant_user_fixture(tenant)

    assert {:error, changeset} =
             Accounts.change_tenant_password(user, valid_password(), %{
               "password" => "too-short",
               "password_confirmation" => "too-short"
             })

    assert "must be at least 12 characters" in errors_on(changeset).password
  end

  test "existing passwords keep working when the policy is stricter" do
    admin = admin_user_fixture()
    previous = Application.get_env(:converger, :password_min_length)
    Application.put_env(:converger, :password_min_length, 40)
    on_exit(fn -> Application.put_env(:converger, :password_min_length, previous) end)

    assert {:ok, _} = Accounts.authenticate_admin(admin.email, valid_password())
  end
end
