defmodule ConvergerWeb.RoutingRuleListLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Accounts, RoutingRules}

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

    tenant = tenant_fixture()
    other = tenant_fixture()

    a = tenant |> rule_fixture("orders to teams") |> backdate(30)
    b = tenant |> rule_fixture("vip escalation", enabled: false) |> backdate(20)
    c = tenant |> rule_fixture("orders fallback") |> backdate(10)
    foreign = rule_fixture(other, "orders elsewhere")

    %{tenant: tenant, other: other, a: a, b: b, c: c, foreign: foreign}
  end

  defp rule_fixture(tenant, name, attrs \\ []) do
    source = channel_fixture(tenant)
    target = channel_fixture(tenant)

    {:ok, rule} =
      attrs
      |> Map.new()
      |> Map.merge(%{
        name: name,
        tenant_id: tenant.id,
        source_channel_id: source.id,
        target_channel_ids: [target.id]
      })
      |> RoutingRules.create_routing_rule()

    rule
  end

  # `inserted_at` has second precision: spread the rules so the order is fixed.
  defp backdate(rule, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

    from(r in Converger.RoutingRules.RoutingRule, where: r.id == ^rule.id)
    |> Converger.Repo.update_all(set: [inserted_at: at])

    rule
  end

  defp put_limit(n) do
    Application.put_env(
      :converger,
      :pagination,
      Keyword.merge(Application.get_env(:converger, :pagination, []), default_limit: n)
    )
  end

  defp row_count(html), do: ~r/id="rule-[0-9a-f-]{36}"/ |> Regex.scan(html) |> length()

  defp admin_conn(conn) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "rule-list-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Rule Lister",
        role: "super_admin"
      })

    conn |> Map.put(:remote_ip, {127, 0, 0, 1}) |> log_in_admin(admin)
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Rules #{role}",
        email: "rule-list-#{System.unique_integer([:positive])}@example.com",
        password: "password-123456",
        role: role
      })

    log_in_tenant_user(conn, user)
  end

  describe "admin" do
    test "searches, filters by tenant and enabled, and sorts", %{conn: conn, tenant: t} = ctx do
      {:ok, view, html} = live(admin_conn(conn), ~p"/admin/routing_rules?tenant_id=#{t.id}")
      assert row_count(html) == 3
      refute html =~ "orders elsewhere"

      html = view |> form("#routing-rule-filter", filters: %{q: "ORDERS"}) |> render_change()
      assert row_count(html) == 2
      refute has_element?(view, "#rule-#{ctx.b.id}")

      html =
        view
        |> form("#routing-rule-filter", filters: %{q: "", enabled: "false"})
        |> render_change()

      assert row_count(html) == 1
      assert has_element?(view, "#rule-#{ctx.b.id}")

      {:ok, _view, html} =
        live(admin_conn(conn), ~p"/admin/routing_rules?tenant_id=#{t.id}&sort=asc")

      {first, _} = :binary.match(html, "orders to teams")
      {last, _} = :binary.match(html, "orders fallback")
      assert first < last

      {:ok, _view, html} = live(admin_conn(conn), ~p"/admin/routing_rules?q=nothing-matches")
      assert html =~ "No routing rules found."
    end

    test "Load more and toggling keep the stream in sync", %{conn: conn, tenant: t} = ctx do
      put_limit(2)

      {:ok, view, html} = live(admin_conn(conn), ~p"/admin/routing_rules?tenant_id=#{t.id}")
      assert row_count(html) == 2
      assert html =~ "Showing 2 rules"

      html = view |> element("#load-more-routing-rules") |> render_click()
      assert row_count(html) == 3
      refute has_element?(view, "#load-more-routing-rules")

      view |> element("#rule-#{ctx.a.id} button", "Disable") |> render_click()
      assert has_element?(view, "#rule-#{ctx.a.id} button", "Enable")

      view |> element("#rule-#{ctx.c.id} button", "Delete") |> render_click()
      refute has_element?(view, "#rule-#{ctx.c.id}")
      assert render(view) =~ "Showing 2 rules"
    end
  end

  describe "portal" do
    test "lists only the tenant's rules with search, filter and Load more", %{
      conn: conn,
      tenant: t
    } do
      put_limit(2)

      {:ok, view, html} = live(portal_conn(conn, t, "member"), ~p"/portal/routing_rules")
      assert row_count(html) == 2
      refute html =~ "orders elsewhere"

      html = view |> element("#load-more-routing-rules") |> render_click()
      assert row_count(html) == 3

      html =
        view
        |> form("#routing-rule-filter", filters: %{q: "vip"})
        |> render_change()

      assert row_count(html) == 1
      assert html =~ "vip escalation"

      html =
        view
        |> form("#routing-rule-filter", filters: %{q: "", enabled: "true"})
        |> render_change()

      assert row_count(html) == 2
      refute html =~ "vip escalation"
    end

    test "toggles a rule and rejects another tenant's rule", %{conn: conn, tenant: t} = ctx do
      {:ok, view, _html} = live(portal_conn(conn, t, "admin"), ~p"/portal/routing_rules")

      view |> element("#rule-#{ctx.a.id} button", "Disable") |> render_click()
      refute RoutingRules.get_routing_rule!(ctx.a.id).enabled
      assert has_element?(view, "#rule-#{ctx.a.id} button", "Enable")

      assert render_click(view, "toggle_enabled", %{"id" => ctx.foreign.id}) =~ "Unauthorized"
      assert RoutingRules.get_routing_rule!(ctx.foreign.id).enabled
    end

    test "viewers cannot toggle", %{conn: conn, tenant: t} = ctx do
      {:ok, view, _html} = live(portal_conn(conn, t, "viewer"), ~p"/portal/routing_rules")

      refute has_element?(view, "#rule-#{ctx.a.id} button")
      assert render_click(view, "toggle_enabled", %{"id" => ctx.a.id}) =~ "permission"
      assert RoutingRules.get_routing_rule!(ctx.a.id).enabled
    end
  end
end
