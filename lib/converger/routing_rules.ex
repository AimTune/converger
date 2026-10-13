defmodule Converger.RoutingRules do
  @moduledoc """
  The RoutingRules context.

  Manages tenant-scoped routing rules that define how activities
  are fan-out delivered from a source channel to target channels, and routes
  activities through them (`route/3`): conditions, priority, first-match
  `stop_processing` and reply-back routing (ADR-0046).

  Cycle detection (`would_create_cycle?/4`) treats every enabled rule as an
  edge, whatever its conditions: a conditional edge can carry an activity, so
  it counts.
  """

  import Ecto.Query, warn: false
  alias Converger.AuditLogs
  alias Converger.AuditLogs.Changes
  alias Converger.Conversations.Conversation
  alias Converger.Repo
  alias Converger.RoutingRules.{Conditions, RoutingRule}
  alias Ecto.Multi

  def list_routing_rules do
    RoutingRule
    |> order_by([r], asc: r.name, asc: r.id)
    |> Converger.Pagination.bounded_all()
    |> Repo.preload([:tenant, :source_channel])
  end

  def list_routing_rules_for_tenant(tenant_id) do
    from(r in RoutingRule,
      where: r.tenant_id == ^tenant_id,
      order_by: [asc: r.name, asc: r.id]
    )
    |> Converger.Pagination.bounded_all()
  end

  @doc """
  Keyset-paginated routing rules on `(inserted_at, id)`, newest first by
  default (the admin and portal lists).

  Filters (string or atom keys, `""` ignored): `tenant_id`, `enabled`
  (`"true"` / `"false"` or a boolean) and `q` (case-insensitive "contains"
  on the rule name). Options: `:limit`, `:cursor`, `:direction`
  (`:desc` | `:asc`), `:preload`. See `Converger.Pagination.keyset/2`.

  Returns `{:ok, %Converger.Pagination.Page{}}` or `{:error, :invalid_cursor}`.
  """
  def paginate_routing_rules(filters \\ %{}, opts \\ []) do
    RoutingRule
    |> apply_list_filters(filters)
    |> Converger.Pagination.keyset(opts)
  end

  defp apply_list_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, q ->
      apply_list_filter(q, to_string(key), value)
    end)
  end

  defp apply_list_filter(query, "tenant_id", value) when is_binary(value) and value != "" do
    case Ecto.UUID.cast(value) do
      {:ok, tenant_id} -> where(query, tenant_id: ^tenant_id)
      :error -> where(query, [r], false)
    end
  end

  defp apply_list_filter(query, "enabled", value) when value in [true, "true"],
    do: where(query, enabled: true)

  defp apply_list_filter(query, "enabled", value) when value in [false, "false"],
    do: where(query, enabled: false)

  defp apply_list_filter(query, "q", value) do
    case Converger.Pagination.contains(value) do
      nil -> query
      pattern -> where(query, [r], ilike(r.name, ^pattern))
    end
  end

  defp apply_list_filter(query, _key, _value), do: query

  def get_routing_rule!(id), do: Repo.get!(RoutingRule, id)

  @doc "The routing rule `id` of `tenant_id`, or `nil` (also for a malformed id)."
  def get_routing_rule(id, tenant_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(RoutingRule, id: id, tenant_id: tenant_id)
      :error -> nil
    end
  end

  def get_routing_rule!(id, tenant_id) do
    Repo.get_by!(RoutingRule, id: id, tenant_id: tenant_id)
  end

  def create_routing_rule(attrs, actor \\ nil) do
    changeset =
      %RoutingRule{}
      |> RoutingRule.changeset(attrs)
      |> validate_tenant_isolation()
      |> validate_channel_modes()
      |> validate_no_cycle()

    if actor do
      Multi.new()
      |> Multi.insert(:routing_rule, changeset)
      |> Multi.insert(:audit_log, fn %{routing_rule: rule} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: rule.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "create",
          resource_type: "routing_rule",
          resource_id: rule.id,
          changes: Changes.for_create(rule)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{routing_rule: rule}} -> {:ok, rule}
        {:error, :routing_rule, changeset, _} -> {:error, changeset}
      end
    else
      Repo.insert(changeset)
    end
  end

  def update_routing_rule(%RoutingRule{} = rule, attrs, actor \\ nil) do
    changeset =
      rule
      |> RoutingRule.changeset(attrs)
      |> validate_tenant_isolation()
      |> validate_channel_modes()
      |> validate_no_cycle()

    if actor do
      Multi.new()
      |> Multi.update(:routing_rule, changeset)
      |> Multi.insert(:audit_log, fn %{routing_rule: updated} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: rule.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "update",
          resource_type: "routing_rule",
          resource_id: rule.id,
          changes: Changes.for_update(rule, updated)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{routing_rule: updated}} -> {:ok, updated}
        {:error, :routing_rule, changeset, _} -> {:error, changeset}
      end
    else
      Repo.update(changeset)
    end
  end

  def delete_routing_rule(%RoutingRule{} = rule, actor \\ nil) do
    if actor do
      Multi.new()
      |> Multi.insert(:audit_log, fn _ ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: rule.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "delete",
          resource_type: "routing_rule",
          resource_id: rule.id,
          changes: Changes.for_delete(rule)
        })
      end)
      |> Multi.delete(:routing_rule, rule)
      |> Repo.transaction()
      |> case do
        {:ok, %{routing_rule: rule}} -> {:ok, rule}
        {:error, :routing_rule, changeset, _} -> {:error, changeset}
      end
    else
      Repo.delete(rule)
    end
  end

  def toggle_routing_rule(%RoutingRule{} = rule, actor \\ nil) do
    changeset =
      rule
      |> RoutingRule.changeset(%{enabled: !rule.enabled})
      |> validate_tenant_isolation()
      |> validate_no_cycle()

    if actor do
      Multi.new()
      |> Multi.update(:routing_rule, changeset)
      |> Multi.insert(:audit_log, fn %{routing_rule: updated} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: rule.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "toggle_enabled",
          resource_type: "routing_rule",
          resource_id: rule.id,
          changes: Changes.for_update(rule, updated)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{routing_rule: updated}} -> {:ok, updated}
        {:error, :routing_rule, changeset, _} -> {:error, changeset}
      end
    else
      Repo.update(changeset)
    end
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

  @doc """
  Enabled rules of `tenant_id` whose source is `source_channel_id`, in
  evaluation order: ascending `priority`, then `name`, then `id`.
  """
  def enabled_rules_for_source(nil, _tenant_id), do: []

  def enabled_rules_for_source(source_channel_id, tenant_id) do
    from(r in RoutingRule,
      where:
        r.source_channel_id == ^source_channel_id and r.tenant_id == ^tenant_id and
          r.enabled == true,
      order_by: [asc: r.priority, asc: r.name, asc: r.id]
    )
    |> Repo.all()
  end

  @doc """
  Route an activity: which rules apply to it and which of them match.

  The conversation's origin channel (`Conversation.origin_channel_id/1`) and
  the channel the activity came in on (`activity.source_channel_id`) decide
  the direction:

    * `:inbound` - the activity came in on the origin channel, or without a
      channel (tenant API, system events, activities stored before ADR-0046).
      The origin channel's rules are evaluated.
    * `:reply` - the activity came in on another channel (an agent console a
      rule routed the conversation to). It goes back to the origin channel
      (`Converger.Pipeline.plan/2`); only the replying channel's own rules
      are evaluated, so a reply is not fanned out to the origin's other
      targets unless a rule of the replying channel says so.

  Rules are evaluated in `enabled_rules_for_source/2` order against their
  `conditions` (`Converger.RoutingRules.Conditions`). A matching rule with
  `stop_processing` ends the evaluation: later rules are reported as
  `:skipped`.

  Options:

    * `:participant` - the conversation's participant (loaded when not given);
    * `:rules` - the candidate rules (loaded when not given);
    * `:at` - evaluation time for an activity without `inserted_at`.

  Returns a map with `:direction`, `:origin_channel_id`, `:source_channel_id`,
  `:rule_source_channel_id`, `:evaluations` (`[{rule, :matched | :not_matched
  | :skipped}]`) and `:matched` (the matched rules, in order).
  """
  def route(activity, conversation, opts \\ []) do
    origin = Conversation.origin_channel_id(conversation)
    source = Map.get(activity, :source_channel_id)
    direction = if is_nil(source) or source == origin, do: :inbound, else: :reply
    rule_source = if direction == :reply, do: source, else: origin

    rules =
      Keyword.get_lazy(opts, :rules, fn ->
        enabled_rules_for_source(rule_source, conversation.tenant_id)
      end)

    participant =
      Keyword.get_lazy(opts, :participant, fn ->
        conversation.participant_id &&
          Converger.Participants.get_participant(conversation.participant_id)
      end)

    context = Conditions.context(activity, conversation, participant, Keyword.get(opts, :at))
    evaluations = evaluate(rules, context)

    %{
      direction: direction,
      origin_channel_id: origin,
      source_channel_id: source,
      rule_source_channel_id: rule_source,
      evaluations: evaluations,
      matched: for({rule, :matched} <- evaluations, do: rule)
    }
  end

  defp evaluate(rules, context) do
    {evaluations, _stopped?} =
      Enum.map_reduce(rules, false, fn
        rule, true ->
          {{rule, :skipped}, true}

        rule, false ->
          if Conditions.matches?(rule.conditions, context),
            do: {{rule, :matched}, rule.stop_processing},
            else: {{rule, :not_matched}, false}
      end)

    evaluations
  end

  @doc """
  Whether an enabled rule of `tenant_id` targeting `channel_id` has its own
  transformations (a cheap check before routing an activity at delivery time).
  """
  def transformations_target?(tenant_id, channel_id) do
    from(r in RoutingRule,
      where:
        r.tenant_id == ^tenant_id and r.enabled == true and
          ^channel_id in r.target_channel_ids and
          fragment("jsonb_array_length(?) > 0", r.transformations)
    )
    |> Repo.exists?()
  end

  @doc """
  Whether an enabled routing rule of `tenant_id` delivers from
  `source_channel_id` to `target_channel_id`. A `websocket` channel's sockets
  may follow the conversations routed to it this way.
  """
  def routes_to?(source_channel_id, target_channel_id, tenant_id) do
    target_channel_id in resolve_target_channels(source_channel_id, tenant_id)
  end

  # --- Validations ---

  defp validate_channel_modes(changeset) do
    if changeset.valid? do
      source_id = Ecto.Changeset.get_field(changeset, :source_channel_id)
      target_ids = Ecto.Changeset.get_field(changeset, :target_channel_ids) || []

      changeset
      |> validate_source_mode(source_id)
      |> validate_target_modes(target_ids)
    else
      changeset
    end
  end

  defp validate_source_mode(changeset, nil), do: changeset

  defp validate_source_mode(changeset, source_id) do
    case Repo.get(Converger.Channels.Channel, source_id) do
      %{mode: mode} when mode in ["inbound", "duplex"] ->
        changeset

      %{mode: "outbound"} ->
        Ecto.Changeset.add_error(
          changeset,
          :source_channel_id,
          "source channel is outbound-only and cannot receive inbound messages"
        )

      nil ->
        changeset
    end
  end

  defp validate_target_modes(changeset, []), do: changeset

  defp validate_target_modes(changeset, target_ids) do
    inbound_only =
      from(c in Converger.Channels.Channel,
        where: c.id in ^target_ids and c.mode == "inbound",
        select: c.name
      )
      |> Repo.all()

    if inbound_only == [] do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :target_channel_ids,
        "these target channels are inbound-only and cannot deliver outbound: #{Enum.join(inbound_only, ", ")}"
      )
    end
  end

  defp validate_tenant_isolation(changeset) do
    tenant_id = Ecto.Changeset.get_field(changeset, :tenant_id)
    source_id = Ecto.Changeset.get_field(changeset, :source_channel_id)
    target_ids = Ecto.Changeset.get_field(changeset, :target_channel_ids) || []

    all_ids = [source_id | target_ids] |> Enum.reject(&is_nil/1)

    if tenant_id && all_ids != [] do
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
