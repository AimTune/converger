defmodule ConvergerWeb.Admin.CrudTest do
  use ConvergerWeb.ConnCase

  import Phoenix.LiveViewTest
  alias Converger.Tenants
  alias Converger.Channels

  @admin_user_ip {127, 0, 0, 1}

  describe "Tenant CRUD" do
    test "lists, creates, updates, and deletes tenants", %{conn: conn} do
      conn = %{conn | remote_ip: @admin_user_ip}
      {:ok, view, _html} = live(conn, ~p"/admin/tenants")

      # Create
      assert view
             |> form("form", tenant: %{name: "New Tenant"})
             |> render_submit() =~ "Tenant created"

      tenant = Tenants.get_tenant_by_api_key(hd(Tenants.list_tenants()).api_key)
      assert tenant.name == "New Tenant"
      assert tenant.status == "active"

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

    test "lists, creates, updates, and deletes channels", %{conn: conn, tenant: tenant} do
      conn = %{conn | remote_ip: @admin_user_ip}
      {:ok, view, _html} = live(conn, ~p"/admin/channels")

      # Create
      assert view
             |> form("form",
               channel: %{name: "New Channel", tenant_id: tenant.id, type: "echo", mode: "outbound"}
             )
             |> render_submit() =~ "Channel created"

      channel = hd(Channels.list_channels())
      assert channel.name == "New Channel"
      assert channel.tenant_id == tenant.id

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
