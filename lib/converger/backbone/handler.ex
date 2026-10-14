defmodule Converger.Backbone.Handler do
  @moduledoc """
  A module that handles backbone events (`Converger.Backbone.subscribe/3`).

  `c:handle_event/1` returns `:ok` once the event is handled, or
  `{:error, reason}` to have it retried (shared subscriptions). It runs
  inside the database transaction that records the event's idempotency
  receipt when the subscription has `dedup: true`, so its database writes
  commit exactly once per event id; side effects outside the database (an
  HTTP call) are at least once.

  `c:accept?/1` (optional) decides whether the subscription wants an event
  at all. On the Native backbone it runs when the event is published, so an
  unwanted event costs no job.
  """

  alias Converger.Backbone.Event

  @callback handle_event(Event.t()) :: :ok | {:error, term()}
  @callback accept?(Event.t()) :: boolean()

  @optional_callbacks accept?: 1
end
