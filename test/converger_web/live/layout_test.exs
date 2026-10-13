defmodule ConvergerWeb.LayoutTest do
  # Every admin and portal page renders inside the shared frame
  # (ConvergerWeb.Layouts.app/1, ADR-0060): sidebar navigation with the current
  # page marked, the signed-in user, logout and the flash group.
  use ConvergerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Accounts

  setup do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "layout-admin-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Layout Admin",
        role: "super_admin"
      })

    tenant = tenant_fixture(%{name: "Layout Tenant"})
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    activity_fixture(tenant, conversation)

    {:ok, tenant_user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Layout Owner",
        email: "layout-owner-#{System.unique_integer([:positive])}@test.com",
        password: "password123",
        role: "owner"
      })

    %{admin: admin, tenant_user: tenant_user, conversation: conversation}
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> init_test_session(%{admin_user_id: admin.id})
  end

  @admin_pages ~w(/admin /admin/tenants /admin/channels /admin/conversations /admin/routing_rules
                  /admin/routing_rules/dry_run /admin/deliveries /admin/webhooks /admin/audit_logs
                  /admin/users /admin/tenant_users)

  @portal_pages ~w(/portal /portal/channels /portal/conversations /portal/deliveries
                   /portal/routing_rules /portal/webhooks /portal/users)

  test "every admin page renders in the admin frame", %{conn: conn, admin: admin} do
    conn = admin_conn(conn, admin)

    for path <- @admin_pages do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#current-user", "Layout Admin"), path
      assert has_element?(view, "a[href='/admin/logout'][data-method='delete']"), path
      assert has_element?(view, "#flash-group"), path
      assert has_element?(view, ~s(a[aria-current="page"])), path
      refute html =~ ~r/\sstyle="/, "#{path} has an inline style attribute"
    end
  end

  test "the sidebar marks the current page", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/channels")

    assert has_element?(view, ~s(a[aria-current="page"][href="/admin/channels"]))
    refute has_element?(view, ~s(a[aria-current="page"][href="/admin"]))
  end

  test "the admin conversation transcript renders in the frame", %{
    conn: conn,
    admin: admin,
    conversation: conversation
  } do
    {:ok, view, _html} =
      live(admin_conn(conn, admin), ~p"/admin/conversations/#{conversation.id}")

    assert has_element?(
             view,
             ~s(a[aria-current="page"][href="/admin/conversations"])
           )
  end

  test "every portal page renders in the portal frame", %{
    conn: conn,
    tenant_user: tenant_user,
    conversation: conversation
  } do
    conn = init_test_session(conn, %{tenant_user_id: tenant_user.id})

    for path <- @portal_pages ++ ["/portal/conversations/#{conversation.id}"] do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#current-tenant", "Layout Tenant"), path
      assert has_element?(view, "#current-user", "Layout Owner"), path
      assert has_element?(view, "a[href='/portal/logout'][data-method='delete']"), path
      refute html =~ ~r/\sstyle="/, "#{path} has an inline style attribute"
    end
  end

  test "flash messages are shown in the frame", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenants")

    view |> element("button[phx-click='toggle_status']") |> render_click()
    assert has_element?(view, "#flash-info", "Status updated")
  end

  test "login pages use the auth frame and the built assets", %{conn: conn} do
    for path <- ["/admin/login", "/portal/login"] do
      html = conn |> Map.put(:remote_ip, {127, 0, 0, 1}) |> get(path) |> html_response(200)

      assert html =~ ~s(href="/assets/css/app.css")
      assert html =~ ~s(src="/assets/js/app.js")
      refute html =~ "cdn.jsdelivr.net"
      refute html =~ ~r/\sstyle="/
    end
  end
end
