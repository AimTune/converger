defmodule ConvergerWeb.Admin.RoutingRuleLiveTest do
  use ConvergerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Accounts, RoutingRules}

  setup %{conn: conn} do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "rules-admin-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Rules Admin",
        role: "super_admin"
      })

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> log_in_admin(admin)

    tenant = tenant_fixture()
    origin = channel_fixture(tenant, %{name: "widget #{System.unique_integer([:positive])}"})

    hook =
      webhook_channel_fixture(tenant, %{
        name: "vip hook #{System.unique_integer([:positive])}",
        mode: "outbound"
      })

    %{conn: conn, tenant: tenant, origin: origin, hook: hook}
  end

  defp fill(view, tenant, origin, hook, extra) do
    view
    |> form("#routing-rule-form", routing_rule: %{tenant_id: tenant.id})
    |> render_change()

    view
    |> form("#routing-rule-form",
      routing_rule: %{tenant_id: tenant.id, source_channel_id: origin.id}
    )
    |> render_change()

    view
    |> form("#routing-rule-form",
      routing_rule:
        Map.merge(
          %{
            tenant_id: tenant.id,
            source_channel_id: origin.id,
            name: "vip rule",
            priority: "5",
            stop_processing: "true",
            target_channel_ids: [hook.id]
          },
          extra
        )
    )
    |> render_submit()
  end

  test "creates and edits a conditional rule", %{
    conn: conn,
    tenant: tenant,
    origin: origin,
    hook: hook
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/routing_rules")

    html =
      fill(view, tenant, origin, hook, %{
        conditions: ~s({"field": "metadata.vip", "op": "eq", "value": true}),
        transformations: ~s([{"type": "add_prefix", "prefix": "[VIP] "}])
      })

    assert html =~ "Routing rule created"

    [rule] = RoutingRules.list_routing_rules_for_tenant(tenant.id)
    assert rule.conditions == %{"field" => "metadata.vip", "op" => "eq", "value" => true}
    assert rule.transformations == [%{"type" => "add_prefix", "prefix" => "[VIP] "}]
    assert %{priority: 5, stop_processing: true} = rule
    assert html =~ "metadata.vip"

    html = view |> element("#rule-#{rule.id} button", "Edit") |> render_click()
    assert html =~ "Edit Routing Rule: vip rule"

    html =
      view
      |> form("#routing-rule-form",
        routing_rule: %{
          source_channel_id: origin.id,
          name: "vip rule",
          priority: "7",
          target_channel_ids: [hook.id],
          conditions: ~s({"field": "type", "op": "eq", "value": "message"}),
          transformations: ""
        }
      )
      |> render_submit()

    assert html =~ "Routing rule updated"

    assert %{priority: 7, transformations: [], conditions: %{"field" => "type"}} =
             RoutingRules.get_routing_rule!(rule.id)
  end

  test "shows JSON and validation errors", %{
    conn: conn,
    tenant: tenant,
    origin: origin,
    hook: hook
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/routing_rules")

    html = fill(view, tenant, origin, hook, %{conditions: "{not json"})
    assert html =~ "is not valid JSON"

    html =
      fill(view, tenant, origin, hook, %{
        conditions: ~s({"field": "text", "op": "regex", "value": "(a"})
      })

    assert html =~ "does not compile"
    assert RoutingRules.list_routing_rules_for_tenant(tenant.id) == []
  end

  test "the dry-run page shows matched rules and transformed payloads", %{
    conn: conn,
    tenant: tenant,
    origin: origin,
    hook: hook
  } do
    {:ok, rule} =
      RoutingRules.create_routing_rule(%{
        name: "vip only",
        tenant_id: tenant.id,
        source_channel_id: origin.id,
        target_channel_ids: [hook.id],
        conditions: %{"field" => "metadata.vip", "op" => "eq", "value" => true},
        transformations: [%{"type" => "add_prefix", "prefix" => "[VIP] "}]
      })

    {:ok, view, _html} = live(conn, ~p"/admin/routing_rules/dry_run")

    view |> form("#dry-run-form", dry_run: %{tenant_id: tenant.id}) |> render_change()

    html =
      view
      |> form("#dry-run-form",
        dry_run: %{
          tenant_id: tenant.id,
          source_channel_id: origin.id,
          activity: ~s({"text": "upgrade", "metadata": {"vip": true}})
        }
      )
      |> render_submit()

    assert view |> element("#dry-run-rule-#{rule.id}") |> render() =~ "matched"
    assert view |> element("#dry-run-target-#{hook.id}") |> render() =~ "[VIP] upgrade"
    assert html =~ "inbound"

    html =
      view
      |> form("#dry-run-form",
        dry_run: %{tenant_id: tenant.id, source_channel_id: origin.id, activity: "{oops"}
      )
      |> render_submit()

    assert html =~ "Activity is not valid JSON"
  end
end
