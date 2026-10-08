defmodule Converger.AccountsBootstrapTest do
  use Converger.DataCase, async: true

  alias Converger.Accounts
  alias Converger.Accounts.AdminUser

  describe "bootstrap_super_admin/1" do
    test "generates a one-time password and forces a change when none is given" do
      assert {:ok, user, :generated, password} = Accounts.bootstrap_super_admin([])

      assert user.email == "admin@converger.local"
      assert user.role == "super_admin"
      assert user.must_change_password
      assert byte_size(password) >= 20
      refute password == "admin123456"
      assert AdminUser.valid_password?(user, password)
    end

    test "uses ADMIN_EMAIL / ADMIN_PASSWORD when given" do
      assert {:ok, user, :provided, "a-strong-password"} =
               Accounts.bootstrap_super_admin(
                 email: "ops@example.com",
                 password: "a-strong-password"
               )

      assert user.email == "ops@example.com"
      refute user.must_change_password
      assert AdminUser.valid_password?(user, "a-strong-password")
    end

    test "blank values fall back to the defaults" do
      assert {:ok, user, :generated, _} = Accounts.bootstrap_super_admin(email: " ", password: "")
      assert user.email == "admin@converger.local"
    end

    test "rejects a too short provided password" do
      assert {:error, changeset} = Accounts.bootstrap_super_admin(password: "short")
      assert %{password: [_]} = errors_on(changeset)
    end

    test "does nothing when an admin already exists" do
      {:ok, _, _, _} = Accounts.bootstrap_super_admin([])
      assert :exists = Accounts.bootstrap_super_admin(password: "another-password")
      assert length(Accounts.list_admin_users()) == 1
    end
  end

  describe "change_admin_password/3" do
    setup do
      {:ok, user, :generated, password} = Accounts.bootstrap_super_admin([])
      %{user: user, password: password}
    end

    test "changes the password and clears must_change_password", %{user: user, password: pw} do
      assert {:ok, updated} =
               Accounts.change_admin_password(user, pw, %{
                 "password" => "new-password-123",
                 "password_confirmation" => "new-password-123"
               })

      refute updated.must_change_password
      assert AdminUser.valid_password?(updated, "new-password-123")
      refute AdminUser.valid_password?(updated, pw)
    end

    test "requires the current password", %{user: user} do
      assert {:error, changeset} =
               Accounts.change_admin_password(user, "wrong", %{
                 "password" => "new-password-123",
                 "password_confirmation" => "new-password-123"
               })

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
      assert Accounts.get_admin_user!(user.id).must_change_password
    end

    test "requires a matching confirmation", %{user: user, password: pw} do
      assert {:error, changeset} =
               Accounts.change_admin_password(user, pw, %{
                 "password" => "new-password-123",
                 "password_confirmation" => "different-123"
               })

      assert %{password_confirmation: [_]} = errors_on(changeset)
    end
  end
end
