defmodule ConvergerWeb.Portal.UserLiveTest do
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

    tenant = tenant_fixture()
    owner = tenant_user_fixture(tenant, %{name: "Owner", role: "owner"})
    %{tenant: tenant, owner: owner}
  end

  defp row(user), do: "#portal-user-#{user.id}"

  test "an owner adds, disables and deletes users", %{conn: conn, tenant: tenant, owner: owner} do
    {:ok, view, _html} = live(log_in_tenant_user(conn, owner), ~p"/portal/users")

    html =
      view
      |> form("#portal-user-form",
        tenant_user: %{
          name: "Gina",
          email: "gina@example.com",
          password: valid_password(),
          role: "member"
        }
      )
      |> render_submit()

    assert html =~ "User created"
    user = Accounts.get_tenant_user_by_email_and_tenant("gina@example.com", tenant.id)
    assert has_element?(view, row(user), "Gina")

    view |> element(~s{#{row(user)} button[phx-click="toggle_status"]}) |> render_click()
    assert Repo.get!(TenantUser, user.id).status == "inactive"
    assert has_element?(view, row(user), "Enable")

    assert view |> element(~s{#{row(user)} button[phx-click="delete"]}) |> render_click() =~
             "User deleted"

    refute Repo.get(TenantUser, user.id)
    refute has_element?(view, row(user))
  end

  test "lists only the current tenant, with search, sort and Load more", %{
    conn: conn,
    tenant: tenant,
    owner: owner
  } do
    Application.put_env(:converger, :pagination, default_limit: 2)
    hana = tenant_user_fixture(tenant, %{name: "Hana", email: "hana@example.com"})
    ivan = tenant_user_fixture(tenant, %{name: "Ivan"})
    stranger = tenant_user_fixture(tenant_fixture(), %{name: "Hana Elsewhere"})

    {:ok, view, html} = live(log_in_tenant_user(conn, owner), ~p"/portal/users")
    assert html =~ "Showing 2 users"
    refute has_element?(view, row(owner))

    html = view |> element("#load-more-portal-users") |> render_click()
    assert html =~ "Showing 3 users"
    assert has_element?(view, row(owner))
    refute has_element?(view, row(stranger))
    refute has_element?(view, "#load-more-portal-users")

    view |> form("#portal-user-filter", filters: %{q: "hana"}) |> render_change()
    assert_patch(view, ~p"/portal/users?q=hana")
    assert has_element?(view, row(hana))
    refute has_element?(view, row(ivan))
    refute has_element?(view, row(stranger))

    {:ok, _view, html} = live(log_in_tenant_user(conn, owner), ~p"/portal/users?sort=asc")
    assert html =~ "portal-user-#{owner.id}"
    refute html =~ "portal-user-#{ivan.id}"

    # A tenant_id in the URL cannot widen the scope.
    {:ok, view, _} =
      live(log_in_tenant_user(conn, owner), "/portal/users?tenant_id=#{stranger.tenant_id}")

    refute has_element?(view, row(stranger))
  end

  test "cannot act on another tenant's users", %{conn: conn, owner: owner} do
    stranger = tenant_user_fixture(tenant_fixture())
    {:ok, view, _html} = live(log_in_tenant_user(conn, owner), ~p"/portal/users")

    assert render_click(view, "toggle_status", %{"id" => stranger.id}) =~ "Unauthorized"
    assert render_click(view, "delete", %{"id" => stranger.id}) =~ "Unauthorized"
    assert Repo.get!(TenantUser, stranger.id).status == "active"
  end

  for role <- ~w(member viewer) do
    test "a #{role} cannot manage users", %{conn: conn, tenant: tenant, owner: owner} do
      user = tenant_user_fixture(tenant, %{role: unquote(role)})
      {:ok, view, _html} = live(log_in_tenant_user(conn, user), ~p"/portal/users")

      assert has_element?(view, row(owner))
      refute has_element?(view, "#portal-user-form")
      refute has_element?(view, ~s{button[phx-click="delete"]})

      assert render_submit(view, "save", %{
               "tenant_user" => %{
                 "name" => "X",
                 "email" => "x-denied@example.com",
                 "password" => valid_password()
               }
             }) =~ "permission to create users"

      refute Accounts.get_tenant_user_by_email_and_tenant("x-denied@example.com", tenant.id)

      assert render_click(view, "toggle_status", %{"id" => owner.id}) =~ "permission"
      assert render_click(view, "delete", %{"id" => owner.id}) =~ "permission to delete"
      assert Repo.get!(TenantUser, owner.id).status == "active"
    end
  end
end
