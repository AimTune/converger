defmodule ConvergerWeb.Admin.CrudTest do
  use ConvergerWeb.ConnCase

  import Phoenix.LiveViewTest
  alias Converger.Tenants
  alias Converger.Channels
  alias Converger.Accounts

  @admin_user_ip {127, 0, 0, 1}

  setup do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "test-admin-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Test Admin",
        role: "super_admin"
      })

    %{admin: admin}
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, @admin_user_ip)
    |> init_test_session(%{admin_user_id: admin.id})
  end

  describe "Tenant CRUD" do
    test "lists, creates, updates, and deletes tenants", %{conn: conn, admin: admin} do
      conn = admin_conn(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin/tenants")

      # Create
      html =
        view
        |> form("form", tenant: %{name: "New Tenant"})
        |> render_submit()

      assert html =~ "Tenant created"

      # The full key is revealed exactly once, right after creation.
      [_, api_key] = Regex.run(~r/(cvg_live_[A-Za-z0-9_-]{20,})/, html)
      tenant = Tenants.get_tenant_by_api_key(api_key)
      assert tenant.name == "New Tenant"
      assert tenant.status == "active"

      html = view |> element("button[phx-click='dismiss_key']") |> render_click()
      refute html =~ api_key
      assert html =~ Converger.Tenants.Tenant.masked_api_key(tenant)

      # Rotation reveals a new key; the old key keeps working during the grace period.
      html =
        view
        |> element("button[phx-click='rotate_api_key'][phx-value-id='#{tenant.id}']")
        |> render_click()

      assert html =~ "API key rotated"
      [_, new_key] = Regex.run(~r/(cvg_live_[A-Za-z0-9_-]{20,})/, html)
      assert new_key != api_key
      assert Tenants.get_tenant_by_api_key(new_key).id == tenant.id
      assert Tenants.get_tenant_by_api_key(api_key).id == tenant.id

      # Toggle Status (Update)
      assert view
             |> element("button[phx-click='toggle_status'][phx-value-id='#{tenant.id}']")
             |> render_click() =~ "Status updated"

      assert Tenants.get_tenant!(tenant.id).status == "inactive"

      # Delete
      assert view
             |> element("button[phx-click='delete'][phx-value-id='#{tenant.id}']")
             |> render_click() =~ "Tenant deleted"

      assert_raise Ecto.NoResultsError, fn -> Tenants.get_tenant!(tenant.id) end
    end
  end

  describe "Channel CRUD" do
    setup do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Channel Tenant"})
      %{tenant: tenant}
    end

    test "lists, creates, updates, and deletes channels", %{
      conn: conn,
      tenant: tenant,
      admin: admin
    } do
      conn = admin_conn(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin/channels")

      # Create
      assert view
             |> form("form",
               channel: %{
                 name: "New Channel",
                 tenant_id: tenant.id,
                 type: "echo",
                 mode: "outbound"
               }
             )
             |> render_submit() =~ "Channel created"

      channel = hd(Channels.list_channels())
      assert channel.name == "New Channel"
      assert channel.tenant_id == tenant.id

      # The channel secret is shown once after creation, then hidden.
      assert render(view) =~ channel.secret

      refute view |> element("button[phx-click='dismiss_secret']") |> render_click() =~
               channel.secret

      # Toggle Status
      assert view
             |> element("button[phx-click='toggle_status'][phx-value-id='#{channel.id}']")
             |> render_click() =~ "Status updated"

      assert Channels.get_channel!(channel.id).status == "inactive"

      # Delete
      assert view
             |> element("button[phx-click='delete'][phx-value-id='#{channel.id}']")
             |> render_click() =~ "Channel deleted"

      assert_raise Ecto.NoResultsError, fn -> Channels.get_channel!(channel.id) end
    end
  end
end
