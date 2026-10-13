defmodule ConvergerWeb.Admin.TenantLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.AccountsFixtures
  import Converger.TenantsFixtures

  alias Converger.Tenants

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)
    %{admin: admin_user_fixture()}
  end

  defp put_limits(overrides) do
    Application.put_env(
      :converger,
      :pagination,
      Keyword.merge(Application.get_env(:converger, :pagination) || [], overrides)
    )
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin)
  end

  defp row_count(html), do: ~r/id="tenant-[0-9a-f-]{36}"/ |> Regex.scan(html) |> length()

  describe "list" do
    test "searches by name and by exact id", %{conn: conn, admin: admin} do
      alpha = tenant_fixture(%{name: "Alpha Corp"})
      beta = tenant_fixture(%{name: "Beta Inc"})

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenants")
      assert has_element?(view, "#tenant-#{alpha.id}")
      assert has_element?(view, "#tenant-#{beta.id}")

      view |> form("#tenant-filter", filters: %{q: "alp"}) |> render_change()
      assert_patch(view, ~p"/admin/tenants?q=alp")
      assert has_element?(view, "#tenant-#{alpha.id}")
      refute has_element?(view, "#tenant-#{beta.id}")

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenants?q=#{beta.id}")
      assert has_element?(view, "#tenant-#{beta.id}")
      refute has_element?(view, "#tenant-#{alpha.id}")

      {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/tenants?q=nomatch")
      assert row_count(html) == 0
      assert has_element?(view, "p", "No tenants found.")
    end

    test "filters by status and sorts oldest first", %{conn: conn, admin: admin} do
      first = tenant_fixture(%{name: "First"})
      second = tenant_fixture(%{name: "Second", status: "inactive"})

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenants?status=inactive")
      assert has_element?(view, "#tenant-#{second.id}")
      refute has_element?(view, "#tenant-#{first.id}")

      {:ok, _view, html} = live(admin_conn(conn, admin), ~p"/admin/tenants?sort=asc")
      {first_pos, _} = :binary.match(html, "tenant-#{first.id}")
      {second_pos, _} = :binary.match(html, "tenant-#{second.id}")
      assert first_pos < second_pos

      {:ok, _view, html} = live(admin_conn(conn, admin), ~p"/admin/tenants")
      {first_pos, _} = :binary.match(html, "tenant-#{first.id}")
      {second_pos, _} = :binary.match(html, "tenant-#{second.id}")
      assert second_pos < first_pos
    end

    test "loads more pages", %{conn: conn, admin: admin} do
      put_limits(default_limit: 2)
      for _ <- 1..3, do: tenant_fixture()

      {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/tenants")
      assert row_count(html) == 2
      assert html =~ "Showing 2 tenants"

      html = view |> element("#load-more-tenants") |> render_click()
      assert row_count(html) == 3
      assert html =~ "Showing 3 tenants"
      refute has_element?(view, "#load-more-tenants")
    end
  end

  describe "edit" do
    test "updates retention, tier, alert webhook and limits", %{conn: conn, admin: admin} do
      tenant = tenant_fixture()
      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenants")

      view |> element("#edit-tenant-#{tenant.id}") |> render_click()
      assert has_element?(view, "#tenant-edit-modal")

      html =
        view
        |> form("#tenant-edit-form",
          tenant_edit: %{retention_days: "90", tier: "high", alert_webhook_url: ""},
          limits: %{
            "activity_create" => %{"limit" => "50", "scale_ms" => "1000"},
            "upload" => %{"limit" => "", "scale_ms" => ""}
          }
        )
        |> render_submit()

      assert html =~ "Tenant updated"
      refute has_element?(view, "#tenant-edit-modal")

      updated = Tenants.get_tenant!(tenant.id)
      assert updated.retention_days == 90
      assert updated.tier == "high"
      assert updated.limits == %{"activity_create" => %{"limit" => 50, "scale_ms" => 1000}}
      assert has_element?(view, "#tenant-#{tenant.id}", "90 days")

      # Clearing every bucket removes the overrides again.
      view |> element("#edit-tenant-#{tenant.id}") |> render_click()

      assert view
             |> element("#limits_activity_create_limit")
             |> render() =~ ~s(value="50")

      view
      |> form("#tenant-edit-form",
        limits: %{"activity_create" => %{"limit" => "", "scale_ms" => ""}}
      )
      |> render_submit()

      assert Tenants.get_tenant!(tenant.id).limits == %{}
    end

    test "shows validation errors and keeps the tenant unchanged", %{conn: conn, admin: admin} do
      tenant = tenant_fixture()
      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/tenants")

      view |> element("#edit-tenant-#{tenant.id}") |> render_click()

      html =
        view
        |> form("#tenant-edit-form",
          tenant_edit: %{retention_days: "1"},
          limits: %{"activity_create" => %{"limit" => "abc", "scale_ms" => "1000"}}
        )
        |> render_submit()

      min = Converger.Retention.min_retention_days()
      assert html =~ "must be greater than or equal to #{min}"
      assert html =~ "activity_create must have a positive integer limit and scale_ms"
      assert has_element?(view, "#tenant-edit-modal")

      unchanged = Tenants.get_tenant!(tenant.id)
      assert unchanged.retention_days == tenant.retention_days
      assert unchanged.limits == %{}

      view |> element("#tenant-edit-modal button.modal-backdrop") |> render_click()
      refute has_element?(view, "#tenant-edit-modal")
    end

    test "a viewer cannot edit or change tenants", %{conn: conn} do
      viewer = admin_user_fixture(%{role: "viewer"})
      tenant = tenant_fixture()

      {:ok, view, _html} = live(admin_conn(conn, viewer), ~p"/admin/tenants")
      assert has_element?(view, "#tenant-#{tenant.id}")
      refute has_element?(view, "#edit-tenant-#{tenant.id}")
      refute has_element?(view, "#tenant-form")

      assert render_click(view, "edit", %{"id" => tenant.id}) =~
               "Viewers cannot manage tenants."

      refute has_element?(view, "#tenant-edit-modal")

      render_click(view, "update", %{"tenant_edit" => %{"retention_days" => "90"}})
      render_click(view, "toggle_status", %{"id" => tenant.id})
      render_click(view, "delete", %{"id" => tenant.id})

      unchanged = Tenants.get_tenant!(tenant.id)
      assert unchanged.retention_days == tenant.retention_days
      assert unchanged.status == "active"
    end
  end
end
