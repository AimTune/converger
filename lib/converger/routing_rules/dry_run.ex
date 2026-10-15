defmodule Converger.RoutingRules.DryRun do
  @moduledoc """
  Routing dry-run: what the pipeline would do with an activity, without
  storing or sending anything (ADR-0046).

  It runs the real planning code (`Converger.Pipeline.plan/2`, so
  `Converger.RoutingRules.route/3`) and the real transformation code
  (`Converger.Pipeline.preview/3`) on an activity that is never inserted, and
  reports every rule that was evaluated, every candidate channel and, for
  each channel that would get a delivery, the payload after the type
  downgrade, the channel's middleware and the matched rules' transformations.

  Used by `POST /api/v1/routing_rules/dry_run` and the admin
  **Routing Rules, Dry run** page.
  """

  alias Converger.Activities.{Activity, Serializer}
  alias Converger.Channels.Channel
  alias Converger.{Conversations, Participants, Pipeline, Repo}
  alias Converger.Conversations.Conversation
  alias Converger.Participants.Participant

  @type result :: map()

  @doc """
  Dry-run an activity for `tenant_id`.

  `params` (string keys):

    * `"activity"` - the activity: `type` (default `message`), `text`,
      `sender` (default `user`), `metadata`, `attachments`, `reply_to_id`;
    * `"source_channel_id"` - the channel it arrives on. Defaults to the
      conversation's origin; required without `"conversation_id"`;
    * `"conversation_id"` - an existing conversation of the tenant, whose
      origin, metadata and participant are used;
    * without a conversation id, a conversation that does not exist yet:
      `"origin_channel_id"` (default: the source channel; a different one
      makes the activity a reply), `"conversation"` (`{"metadata": ...}`) and
      `"participant"` (`{"external_id", "display_name", "metadata"}`, on the
      origin channel);
    * `"at"` - ISO 8601 time for `time.*` conditions (default: now).

  Returns `{:ok, result}`, `{:error, :not_found}` for an unknown channel or
  conversation, `{:error, %Ecto.Changeset{}}` for an invalid activity, or
  `{:error, {:bad_request, message}}`.
  """
  def run(tenant_id, params) when is_map(params) do
    with {:ok, at} <- parse_at(params["at"]),
         {:ok, activity_params} <- activity_params(params["activity"]),
         {:ok, conversation, participant, source_id} <- conversation(tenant_id, params),
         {:ok, activity} <- build_activity(activity_params, conversation, source_id, at) do
      {:ok, plan(activity, conversation, participant, at)}
    end
  end

  def run(_tenant_id, _params), do: {:error, {:bad_request, "expected a JSON object"}}

  defp parse_at(nil), do: {:ok, DateTime.utc_now() |> DateTime.truncate(:microsecond)}

  defp parse_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _} -> {:error, {:bad_request, "at must be an ISO 8601 date-time"}}
    end
  end

  defp parse_at(_), do: {:error, {:bad_request, "at must be an ISO 8601 date-time"}}

  defp activity_params(%{} = activity), do: {:ok, activity}
  defp activity_params(nil), do: {:error, {:bad_request, "activity is required"}}
  defp activity_params(_), do: {:error, {:bad_request, "activity must be an object"}}

  defp conversation(tenant_id, %{"conversation_id" => id} = params) when is_binary(id) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <- Conversations.get_conversation(id, tenant_id),
         {:ok, source_id} <-
           source_channel(tenant_id, params["source_channel_id"], conversation) do
      participant =
        conversation.participant_id && Participants.get_participant(conversation.participant_id)

      {:ok, conversation, participant, source_id}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp conversation(tenant_id, params) do
    with {:ok, source} <- tenant_channel(tenant_id, params["source_channel_id"]),
         {:ok, origin} <- tenant_channel(tenant_id, params["origin_channel_id"] || source.id),
         {:ok, metadata} <- object(get_in_map(params, ["conversation", "metadata"]), "metadata"),
         {:ok, participant} <- participant(params["participant"], origin) do
      conversation = %Conversation{
        tenant_id: tenant_id,
        channel_id: origin.id,
        origin_channel_id: origin.id,
        status: Conversations.open_status(),
        metadata: metadata
      }

      {:ok, conversation, participant, source.id}
    end
  end

  defp source_channel(_tenant_id, nil, conversation),
    do: {:ok, Conversation.origin_channel_id(conversation)}

  defp source_channel(tenant_id, id, _conversation) do
    with {:ok, channel} <- tenant_channel(tenant_id, id), do: {:ok, channel.id}
  end

  defp tenant_channel(_tenant_id, nil),
    do: {:error, {:bad_request, "source_channel_id or conversation_id is required"}}

  defp tenant_channel(tenant_id, id) do
    with {:ok, id} <- cast_id(id),
         %{tenant_id: ^tenant_id} = channel <- Repo.get(Channel, id) do
      {:ok, channel}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp get_in_map(%{} = map, [key | rest]), do: get_in_map(Map.get(map, key), rest)
  defp get_in_map(value, []), do: value
  defp get_in_map(_value, _path), do: nil

  defp object(nil, _name), do: {:ok, %{}}
  defp object(%{} = map, _name), do: {:ok, map}
  defp object(_, name), do: {:error, {:bad_request, "#{name} must be an object"}}

  defp participant(nil, _origin), do: {:ok, nil}

  defp participant(%{"external_id" => external_id} = attrs, origin) when is_binary(external_id) do
    with {:ok, metadata} <- object(attrs["metadata"], "participant.metadata") do
      {:ok,
       %Participant{
         external_id: external_id,
         display_name: attrs["display_name"],
         metadata: metadata,
         tenant_id: origin.tenant_id,
         channel_id: origin.id
       }}
    end
  end

  defp participant(_, _origin),
    do: {:error, {:bad_request, "participant must be an object with an external_id"}}

  defp build_activity(params, conversation, source_id, at) do
    sender = params["sender"]

    %Activity{}
    |> Activity.client_changeset(params)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, activity} ->
        {:ok,
         %{
           activity
           | sender: if(is_binary(sender) and sender != "", do: sender, else: "user"),
             tenant_id: conversation.tenant_id,
             conversation_id: conversation.id,
             source_channel_id: source_id,
             inserted_at: at
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp plan(activity, conversation, participant, at) do
    %{route: route, entries: entries} =
      Pipeline.plan(activity, conversation: conversation, participant: participant, at: at)

    %{
      direction: route.direction,
      origin_channel_id: route.origin_channel_id,
      source_channel_id: route.source_channel_id,
      rule_source_channel_id: route.rule_source_channel_id,
      at: at,
      activity: Serializer.canonical(activity),
      rules:
        Enum.map(route.evaluations, fn {rule, result} ->
          %{
            id: rule.id,
            name: rule.name,
            priority: rule.priority,
            stop_processing: rule.stop_processing,
            conditions: rule.conditions,
            target_channel_ids: rule.target_channel_ids,
            transformations: rule.transformations,
            result: result
          }
        end),
      matched_rule_ids: Enum.map(route.matched, & &1.id),
      targets: Enum.map(entries, &target(&1, activity, route.matched))
    }
  end

  defp target(entry, activity, matched) do
    base = %{
      channel_id: entry.channel.id,
      channel_name: entry.channel.name,
      channel_type: entry.channel.type,
      reason: entry.reason,
      rule_ids: entry.rule_ids,
      excluded: entry.excluded
    }

    if entry.excluded do
      Map.merge(base, %{outcome: :excluded, detail: nil, payload: nil})
    else
      case Pipeline.preview(activity, entry.channel, matched) do
        {:ok, transformed} ->
          Map.merge(base, %{
            outcome: :deliver,
            detail: nil,
            payload: Serializer.canonical(transformed)
          })

        {:halt, reason} ->
          Map.merge(base, %{outcome: :halted, detail: reason, payload: nil})

        {:skip, reason} ->
          Map.merge(base, %{outcome: :skipped, detail: reason, payload: nil})
      end
    end
  end
end
