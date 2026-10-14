defmodule Converger.Webhooks.BackboneHandler do
  @moduledoc """
  The platform event webhooks as a backbone subscription (`webhooks`, every
  topic, shared, deduplicated; ADR-0070): `Converger.Webhooks.emit/3`
  publishes to the backbone, and this handler turns each event into the
  `webhook_events` rows and delivery jobs of the subscriptions that want it
  (`Converger.Webhooks.record/1`).

  `accept?/1` skips events no enabled subscription of the tenant wants: on
  the Native backbone it runs at publish time, so tenants without
  subscriptions cost no job. The rows are written in the same transaction as
  the event's idempotency receipt, so a redelivered event never creates a
  second set of webhook events.
  """

  @behaviour Converger.Backbone.Handler

  @impl true
  def accept?(event), do: Converger.Webhooks.wants?(event)

  @impl true
  def handle_event(event), do: Converger.Webhooks.record(event)
end
