defmodule ConvergerWeb.ObanDashboardTest do
  use ConvergerWeb.ConnCase, async: true

  alias Converger.Accounts
  alias ConvergerWeb.ObanResolver

  defp admin_fixture(role) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "oban-#{role}-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Oban #{role}",
        role: role
      })

    admin
  end

  defp admin_conn(admin, ip \\ {127, 0, 0, 1}) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> init_test_session(%{admin_user_id: admin.id})
  end

  test "admins get through to the dashboard" do
    # In test Oban runs in `testing: :inline` mode, which does not start the
    # Oban.Met metrics the dashboard waits for. Reaching that point means the
    # request passed the whitelist, session, on_mount and resolver checks.
    assert_raise RuntimeError, ~r/no config registered for \[Oban, Oban.Met\]/, fn ->
      get(admin_conn(admin_fixture("admin")), "/admin/oban")
    end
  end

  test "requires an admin session" do
    conn = build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> get("/admin/oban")
    assert redirected_to(conn) == "/admin/login"
  end

  test "is blocked outside the admin IP whitelist" do
    conn = get(admin_conn(admin_fixture("admin"), {203, 0, 113, 10}), "/admin/oban")
    assert conn.status == 403
  end

  test "maps admin roles to dashboard access" do
    assert ObanResolver.resolve_access(admin_fixture("super_admin")) == :all
    assert ObanResolver.resolve_access(admin_fixture("admin")) == :all
    assert ObanResolver.resolve_access(admin_fixture("viewer")) == :read_only
    assert ObanResolver.resolve_access(nil) == {:forbidden, "/admin/login"}
  end
end
