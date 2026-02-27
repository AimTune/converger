defmodule Converger.RoutingRules do
  @moduledoc """
  The RoutingRules context.

  Manages tenant-scoped routing rules that define how activities
  are fan-out delivered from a source channel to target channels.
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.RoutingRules.RoutingRule

  def list_routing_rules do
    RoutingRule
    |> order_by([r], asc: r.name)
    |> Repo.all()
    |> Repo.preload([:tenant, :source_channel])
  end

  def list_routing_rules_for_tenant(tenant_id) do
    from(r in RoutingRule,
      where: r.tenant_id == ^tenant_id,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  def get_routing_rule!(id), do: Repo.get!(RoutingRule, id)

  def get_routing_rule!(id, tenant_id) do
    Repo.get_by!(RoutingRule, id: id, tenant_id: tenant_id)
  end

  def create_routing_rule(attrs) do
    changeset =
      %RoutingRule{}
      |> RoutingRule.changeset(attrs)
      |> validate_tenant_isolation()
      |> validate_no_cycle()

    Repo.insert(changeset)
  end

  def update_routing_rule(%RoutingRule{} = rule, attrs) do
    changeset =
      rule
      |> RoutingRule.changeset(attrs)
      |> validate_tenant_isolation()
      |> validate_no_cycle()

    Repo.update(changeset)
  end

  def delete_routing_rule(%RoutingRule{} = rule), do: Repo.delete(rule)

  def toggle_routing_rule(%RoutingRule{} = rule) do
    update_routing_rule(rule, %{enabled: !rule.enabled})
  end

  def change_routing_rule(%RoutingRule{} = rule, attrs \\ %{}) do
    RoutingRule.changeset(rule, attrs)
  end

  @doc """
  Returns target channel IDs for all enabled routing rules
  whose source_channel_id matches the given channel_id and tenant_id.
  Results are flattened and deduplicated.
  """
  def resolve_target_channels(source_channel_id, tenant_id) do
    from(r in RoutingRule,
      where:
        r.source_channel_id == ^source_channel_id and
          r.tenant_id == ^tenant_id and
          r.enabled == true,
      select: r.target_channel_ids
    )
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
  end

  # --- Validations ---

  defp validate_tenant_isolation(changeset) do
    tenant_id = Ecto.Changeset.get_field(changeset, :tenant_id)
    source_id = Ecto.Changeset.get_field(changeset, :source_channel_id)
    target_ids = Ecto.Changeset.get_field(changeset, :target_channel_ids) || []

    all_ids = [source_id | target_ids] |> Enum.reject(&is_nil/1)

    if tenant_id && length(all_ids) > 0 do
      count =
        from(c in Converger.Channels.Channel,
          where: c.id in ^all_ids and c.tenant_id == ^tenant_id,
          select: count(c.id)
        )
        |> Repo.one()

      if count == length(all_ids) do
        changeset
      else
        Ecto.Changeset.add_error(
          changeset,
          :target_channel_ids,
          "all channels must belong to the same tenant"
        )
      end
    else
      changeset
    end
  end

  defp validate_no_cycle(changeset) do
    if changeset.valid? do
      tenant_id = Ecto.Changeset.get_field(changeset, :tenant_id)
      source_id = Ecto.Changeset.get_field(changeset, :source_channel_id)
      target_ids = Ecto.Changeset.get_field(changeset, :target_channel_ids) || []
      rule_id = Ecto.Changeset.get_field(changeset, :id)

      if would_create_cycle?(tenant_id, source_id, target_ids, rule_id) do
        Ecto.Changeset.add_error(
          changeset,
          :target_channel_ids,
          "would create a routing cycle"
        )
      else
        changeset
      end
    else
      changeset
    end
  end

  @doc """
  Detects if adding source -> targets would create a cycle in the routing graph.
  Uses BFS from each target to see if any path leads back to source.
  Excludes the current rule (by rule_id) to allow updates.
  """
  def would_create_cycle?(tenant_id, source_id, target_ids, exclude_rule_id \\ nil) do
    # Load all existing enabled rules for this tenant
    query =
      from(r in RoutingRule,
        where: r.tenant_id == ^tenant_id and r.enabled == true,
        select: {r.id, r.source_channel_id, r.target_channel_ids}
      )

    all_rules = Repo.all(query)

    # Build adjacency map, excluding the rule being updated
    adjacency =
      all_rules
      |> Enum.reject(fn {id, _, _} -> id == exclude_rule_id end)
      |> Enum.reduce(%{}, fn {_id, src, targets}, acc ->
        Map.update(acc, src, targets, &(&1 ++ targets))
      end)

    # Add the proposed new edges
    adjacency = Map.update(adjacency, source_id, target_ids, &(&1 ++ target_ids))

    # BFS: can we reach source_id starting from any of its targets?
    bfs_has_cycle?(target_ids, source_id, adjacency, MapSet.new([source_id]))
  end

  defp bfs_has_cycle?([], _target, _adj, _visited), do: false

  defp bfs_has_cycle?([current | rest], target, adj, visited) do
    cond do
      current == target ->
        true

      MapSet.member?(visited, current) ->
        bfs_has_cycle?(rest, target, adj, visited)

      true ->
        neighbors = Map.get(adj, current, [])
        bfs_has_cycle?(rest ++ neighbors, target, adj, MapSet.put(visited, current))
    end
  end
end
