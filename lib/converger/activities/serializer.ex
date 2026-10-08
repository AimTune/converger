defmodule Converger.Activities.Serializer do
  @moduledoc """
  The single canonical representation of an activity.

  Every outward-facing payload is built from `canonical/1`, so they cannot drift:

    * the PubSub `new_activity` broadcast (legacy WebSocket clients receive it as-is)
    * the `/api/v1` REST responses (`ConvergerWeb.ActivityJSON`)
    * the Converger API REST and WebSocket `activitySet` frames
      (`ConvergerWeb.ConvergerAPI.ActivityJSON` derives its shape from this map)
    * outbound webhook payloads
  """

  alias Converger.Activities.Activity

  @fields [
    :id,
    :type,
    :sender,
    :text,
    :attachments,
    :metadata,
    :idempotency_key,
    :seq,
    :conversation_id,
    :tenant_id,
    :inserted_at
  ]

  @doc "Field names of the canonical map, in order."
  def fields, do: @fields

  @doc "Build the canonical map (atom keys) for an activity."
  def canonical(%Activity{} = activity) do
    %{
      id: activity.id,
      type: activity.type,
      sender: activity.sender,
      text: activity.text,
      attachments: activity.attachments || [],
      metadata: activity.metadata || %{},
      idempotency_key: activity.idempotency_key,
      seq: activity.seq,
      conversation_id: activity.conversation_id,
      tenant_id: activity.tenant_id,
      inserted_at: activity.inserted_at
    }
  end
end
