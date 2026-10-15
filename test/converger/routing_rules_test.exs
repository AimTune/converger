defmodule Converger.RoutingRulesTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.RoutingRules
  alias Converger.RoutingRules.RoutingRule

  setup do
    tenant = tenant_fixture()
    a = channel_fixture(tenant)
    b = channel_fixture(tenant)
    %{tenant: tenant, a: a, b: b}
  end

  defp attrs(tenant, source, targets, extra \\ %{}) do
    Map.merge(
      %{
        "name" => "rule #{System.unique_integer([:positive])}",
        "tenant_id" => tenant.id,
        "source_channel_id" => source.id,
        "target_channel_ids" => Enum.map(targets, & &1.id)
      },
      extra
    )
  end

  defp errors(changeset), do: errors_on(changeset)

  describe "create_routing_rule/2" do
    test "defaults keep the unconditional behaviour", %{tenant: tenant, a: a, b: b} do
      {:ok, rule} = RoutingRules.create_routing_rule(attrs(tenant, a, [b]))

      assert rule.conditions == %{}
      assert rule.transformations == []
      assert rule.priority == RoutingRule.default_priority()
      refute rule.stop_processing
    end

    test "stores conditions, a list being shorthand for all", %{tenant: tenant, a: a, b: b} do
      {:ok, rule} =
        RoutingRules.create_routing_rule(
          attrs(tenant, a, [b], %{
            "conditions" => [%{"field" => "metadata.vip", "op" => "eq", "value" => true}],
            "transformations" => [%{"type" => "add_prefix", "prefix" => "[VIP] "}],
            "priority" => 5,
            "stop_processing" => true
          })
        )

      assert rule.conditions == %{
               "all" => [%{"field" => "metadata.vip", "op" => "eq", "value" => true}]
             }

      assert %{priority: 5, stop_processing: true} = RoutingRules.get_routing_rule!(rule.id)
    end

    test "validates conditions in the changeset", %{tenant: tenant, a: a, b: b} do
      for {conditions, message} <- [
            {%{"field" => "nope", "op" => "eq", "value" => 1}, "unknown field nope"},
            {%{"field" => "text", "op" => "regex", "value" => "(a"}, "does not compile"},
            {%{"field" => "text", "op" => "regex", "value" => String.duplicate("a", 257)},
             "longer than 256 bytes"},
            {"text", "is invalid"}
          ] do
        assert {:error, changeset} =
                 RoutingRules.create_routing_rule(
                   attrs(tenant, a, [b], %{"conditions" => conditions})
                 )

        [error] = errors(changeset).conditions
        assert error =~ message
      end
    end

    test "validates transformations and priority", %{tenant: tenant, a: a, b: b} do
      assert {:error, changeset} =
               RoutingRules.create_routing_rule(
                 attrs(tenant, a, [b], %{"transformations" => [%{"type" => "explode"}]})
               )

      assert ["unknown middleware type: explode"] = errors(changeset).transformations

      assert {:error, changeset} =
               RoutingRules.create_routing_rule(
                 attrs(tenant, a, [b], %{"priority" => 10_000_000})
               )

      assert errors(changeset).priority != []
    end
  end

  describe "cycle detection" do
    test "treats conditional edges as edges", %{tenant: tenant, a: a, b: b} do
      {:ok, _} =
        RoutingRules.create_routing_rule(
          attrs(tenant, a, [b], %{
            "conditions" => %{"field" => "metadata.never", "op" => "eq", "value" => "set"}
          })
        )

      assert {:error, changeset} =
               RoutingRules.create_routing_rule(
                 attrs(tenant, b, [a], %{
                   "conditions" => %{"field" => "type", "op" => "eq", "value" => "typing"}
                 })
               )

      assert "would create a routing cycle" in errors(changeset).target_channel_ids
      assert RoutingRules.would_create_cycle?(tenant.id, b.id, [a.id])
    end
  end

  describe "enabled_rules_for_source/2" do
    test "orders by priority, then name, and skips disabled rules", %{tenant: tenant, a: a, b: b} do
      c = channel_fixture(tenant)

      {:ok, late} =
        RoutingRules.create_routing_rule(
          attrs(tenant, a, [b], %{"name" => "a-late", "priority" => 50})
        )

      {:ok, early} =
        RoutingRules.create_routing_rule(
          attrs(tenant, a, [c], %{"name" => "z-early", "priority" => 1})
        )

      {:ok, tie} =
        RoutingRules.create_routing_rule(
          attrs(tenant, a, [c], %{"name" => "b-tie", "priority" => 50})
        )

      {:ok, _disabled} =
        RoutingRules.create_routing_rule(
          attrs(tenant, a, [b], %{"enabled" => false, "priority" => 0})
        )

      assert Enum.map(RoutingRules.enabled_rules_for_source(a.id, tenant.id), & &1.id) ==
               [early.id, late.id, tie.id]
    end
  end
end
