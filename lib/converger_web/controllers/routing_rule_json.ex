defmodule ConvergerWeb.RoutingRuleJSON do
  alias Converger.RoutingRules.RoutingRule

  def index(%{routing_rules: rules}) do
    %{data: for(rule <- rules, do: data(rule))}
  end

  def show(%{routing_rule: rule}) do
    %{data: data(rule)}
  end

  @doc "Renders a routing dry-run (`Converger.RoutingRules.DryRun.run/2`)."
  def dry_run(%{result: result}) do
    %{
      data: %{
        direction: result.direction,
        origin_channel_id: result.origin_channel_id,
        source_channel_id: result.source_channel_id,
        rule_source_channel_id: result.rule_source_channel_id,
        at: result.at,
        activity: result.activity,
        rules: result.rules,
        matched_rule_ids: result.matched_rule_ids,
        targets: result.targets
      }
    }
  end

  defp data(%RoutingRule{} = rule) do
    %{
      id: rule.id,
      name: rule.name,
      source_channel_id: rule.source_channel_id,
      target_channel_ids: rule.target_channel_ids,
      enabled: rule.enabled,
      conditions: rule.conditions,
      transformations: rule.transformations,
      priority: rule.priority,
      stop_processing: rule.stop_processing,
      tenant_id: rule.tenant_id,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end
end
