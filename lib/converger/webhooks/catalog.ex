defmodule Converger.Webhooks.Catalog do
  @moduledoc """
  The platform event catalog (ADR-0053). Every type here has a source in
  the code base that emits it through `Converger.Webhooks.emit/3`:

  | Type | Source |
  | --- | --- |
  | `activity.created` | `Converger.Activities.create_activity/2`, in the activity's transaction (`emit_in_transaction/3`, ADR-0071) |
  | `delivery.sent`, `delivery.delivered`, `delivery.read`, `delivery.failed` | delivery status changes in `Converger.Deliveries` |
  | `conversation.created` | `Converger.Conversations.insert_conversation/1` |
  | `conversation.closed`, `conversation.reopened` | conversation lifecycle transitions (manual and inactivity expiry) |
  | `channel.health_changed` | `Converger.Channels.Health.broadcast_health_change/3` |
  | `channel.circuit_opened`, `channel.circuit_closed` | `Converger.Channels.Circuit` transitions |
  | `participant.opted_out` | `Converger.Participants.set_opted_out/3` (e.g. SMS `STOP`) |
  """

  @types ~w(
    activity.created
    delivery.sent
    delivery.delivered
    delivery.read
    delivery.failed
    conversation.created
    conversation.closed
    conversation.reopened
    channel.health_changed
    channel.circuit_opened
    channel.circuit_closed
    participant.opted_out
  )

  @doc "Every event type that can be subscribed to."
  def types, do: @types

  @doc "Whether `type` is in the catalog."
  def known?(type), do: type in @types
end
