defmodule ConvergerWeb.DashboardLiveTest do
  use ConvergerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures

  alias Converger.Accounts

  test "admin tiles link to the filtered list pages", %{conn: conn} do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "dash-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: "viewer"
      })

    conn = conn |> Map.put(:remote_ip, {127, 0, 0, 1}) |> log_in_admin(admin)
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#tile-tenants[href='/admin/tenants']")
    assert has_element?(view, "#tile-channels[href='/admin/channels']")
    assert has_element?(view, "#tile-conversations[href='/admin/conversations']")
    assert has_element?(view, "#tile-deliveries-pending[href='/admin/deliveries?status=pending']")

    assert {:error, {:live_redirect, %{to: "/admin/deliveries?status=failed"}}} =
             view |> element("#tile-deliveries-failed") |> render_click()
  end

  test "portal tiles link to the list pages", %{conn: conn} do
    tenant = tenant_fixture()

    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Portal",
        email: "dash-#{System.unique_integer([:positive])}@example.com",
        password: "password-123456",
        role: "viewer"
      })

    {:ok, view, _html} = live(log_in_tenant_user(conn, user), ~p"/portal")

    assert has_element?(view, "#tile-channels[href='/portal/channels']")
    assert has_element?(view, "#tile-conversations[href='/portal/conversations']")

    assert has_element?(
             view,
             "#dashboard-failed-deliveries[href='/portal/deliveries?status=failed']"
           )
  end
end
