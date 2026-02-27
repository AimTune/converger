defmodule ConvergerWeb.RoutingRuleJSON do
  alias Converger.RoutingRules.RoutingRule

  def index(%{routing_rules: rules}) do
    %{data: for(rule <- rules, do: data(rule))}
  end

  def show(%{routing_rule: rule}) do
    %{data: data(rule)}
  end

  defp data(%RoutingRule{} = rule) do
    %{
      id: rule.id,
      name: rule.name,
      source_channel_id: rule.source_channel_id,
      target_channel_ids: rule.target_channel_ids,
      enabled: rule.enabled,
      tenant_id: rule.tenant_id,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end
end
