defmodule Converger.RoutingRules.PaginateTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.RoutingRules

  defp rule_fixture(tenant, attrs) do
    source = channel_fixture(tenant)
    target = channel_fixture(tenant)

    {:ok, rule} =
      attrs
      |> Enum.into(%{
        name: "rule #{System.unique_integer([:positive])}",
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

  defp names({:ok, page}), do: Enum.map(page.entries, & &1.name)

  setup do
    tenant = tenant_fixture()
    other = tenant_fixture()

    a = rule_fixture(tenant, %{name: "WhatsApp to Teams"}) |> backdate(30)
    b = rule_fixture(tenant, %{name: "VIP 100%", enabled: false}) |> backdate(20)
    c = rule_fixture(tenant, %{name: "whatsapp fallback"}) |> backdate(10)
    _foreign = rule_fixture(other, %{name: "whatsapp elsewhere"})

    %{tenant: tenant, a: a, b: b, c: c}
  end

  test "searches names case-insensitively within a tenant", %{tenant: t} do
    assert names(RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id, "q" => "WHATSAPP"})) ==
             ["whatsapp fallback", "WhatsApp to Teams"]

    assert names(RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id, "q" => "100%"})) ==
             ["VIP 100%"]

    assert names(RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id, "q" => "0%_"})) ==
             []
  end

  test "filters on enabled and an invalid tenant id matches nothing", %{tenant: t} do
    assert names(RoutingRules.paginate_routing_rules(%{tenant_id: t.id, enabled: "false"})) ==
             ["VIP 100%"]

    assert length(
             names(RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id, "enabled" => true}))
           ) == 2

    assert names(RoutingRules.paginate_routing_rules(%{"tenant_id" => "nope"})) == []
  end

  test "keyset pages in both directions", %{tenant: t} do
    {:ok, first} = RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id}, limit: 2)
    assert first.has_more
    assert Enum.map(first.entries, & &1.name) == ["whatsapp fallback", "VIP 100%"]

    {:ok, second} =
      RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id},
        limit: 2,
        cursor: first.next_cursor
      )

    assert Enum.map(second.entries, & &1.name) == ["WhatsApp to Teams"]
    refute second.has_more

    assert names(RoutingRules.paginate_routing_rules(%{"tenant_id" => t.id}, direction: :asc)) ==
             ["WhatsApp to Teams", "VIP 100%", "whatsapp fallback"]
  end
end
