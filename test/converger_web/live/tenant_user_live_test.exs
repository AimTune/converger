defmodule ConvergerWeb.Admin.TenantUserLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.AccountsFixtures
  import Converger.TenantsFixtures

  alias Converger.Accounts
  alias Converger.Accounts.TenantUser
  alias Converger.Repo

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)
    %{admin: admin_user_fixture(), tenant: tenant_fixture(%{name: "Acme"})}
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin)
  end

  defp row(user), do: "#tenant_users-#{user.id}"

  test "creates, toggles and deletes a tenant user", %{conn: conn, admin: admin, tenant: tenant} do
    {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenant_users")

    html =
      view
      |> form("#tenant-user-form",
        tenant_user: %{
          tenant_id: tenant.id,
          name: "Dana",
          email: "dana@example.com",
          password: valid_password(),
          role: "admin"
        }
      )
      |> render_submit()

    assert html =~ "Tenant user created"
    user = Accounts.get_tenant_user_by_email_and_tenant("dana@example.com", tenant.id)
    assert has_element?(view, row(user), "Acme")

    view
    |> element(~s{#{row(user)} button[phx-click="toggle_status"]})
    |> render_click()

    assert Repo.get!(TenantUser, user.id).status == "inactive"
    assert has_element?(view, row(user), "Enable")

    assert view
           |> element(~s{#{row(user)} button[phx-click="delete"]})
           |> render_click() =~ "Tenant user deleted"

    refute Repo.get(TenantUser, user.id)
    refute has_element?(view, row(user))
  end

  test "filters by tenant, role, status and searches name/email", %{
    conn: conn,
    admin: admin,
    tenant: tenant
  } do
    other = tenant_fixture()
    erin = tenant_user_fixture(tenant, %{name: "Erin", role: "member"})
    frank = tenant_user_fixture(tenant, %{name: "Frank", email: "frank-x@example.com"})
    {:ok, frank} = Accounts.update_tenant_user(frank, %{status: "inactive"})
    stranger = tenant_user_fixture(other, %{name: "Erin Elsewhere"})

    {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenant_users")
    assert has_element?(view, row(stranger))

    view |> form("#tenant-user-filter", filters: %{tenant_id: tenant.id}) |> render_change()
    assert_patch(view, ~p"/admin/tenant_users?tenant_id=#{tenant.id}")
    assert has_element?(view, row(erin))
    refute has_element?(view, row(stranger))

    view |> form("#tenant-user-filter", filters: %{q: "erin"}) |> render_change()
    assert has_element?(view, row(erin))
    refute has_element?(view, row(frank))
    refute has_element?(view, row(stranger))

    {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/tenant_users?q=frank-x")
    assert has_element?(view, row(frank))
    refute has_element?(view, row(erin))

    {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/tenant_users?role=member")
    assert has_element?(view, row(erin))
    refute has_element?(view, row(frank))

    {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/tenant_users?status=inactive")
    assert has_element?(view, row(frank))
    refute has_element?(view, row(erin))

    {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/tenant_users?tenant_id=not-a-uuid")
    assert has_element?(view, "p", "No tenant users found.")
  end

  test "sorts oldest first and loads more", %{conn: conn, admin: admin, tenant: tenant} do
    Application.put_env(:converger, :pagination, default_limit: 2)
    first = tenant_user_fixture(tenant)
    for _ <- 1..2, do: tenant_user_fixture(tenant)

    {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/tenant_users?sort=asc")
    assert html =~ "tenant_users-#{first.id}"

    html = view |> element("#load-more-tenant-users") |> render_click()
    assert html =~ "Showing 3 users"
    refute has_element?(view, "#load-more-tenant-users")
  end

  test "a viewer cannot manage tenant users", %{conn: conn, tenant: tenant} do
    viewer = admin_user_fixture(%{role: "viewer"})
    user = tenant_user_fixture(tenant)

    {:ok, view, _html} = live(admin_conn(conn, viewer), ~p"/admin/tenant_users")
    assert has_element?(view, row(user))
    refute has_element?(view, "#tenant-user-form")
    refute has_element?(view, ~s{#{row(user)} button[phx-click="delete"]})

    assert render_click(view, "toggle_status", %{"id" => user.id}) =~
             "Viewers cannot manage users."

    assert render_click(view, "delete", %{"id" => user.id}) =~ "Viewers cannot delete users."
    assert Repo.get!(TenantUser, user.id).status == "active"
  end
end
