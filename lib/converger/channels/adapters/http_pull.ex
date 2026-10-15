defmodule Converger.Channels.Adapters.HttpPull do
  @moduledoc """
  Generic "HTTP pull" channel (outbound only): instead of receiving
  webhooks, the integrator polls `GET /api/v1/channels/:id/outbox` (useful
  behind firewalls that allow no inbound connections).

  `deliver_activity/2` hands the activity off into the channel's outbox: the
  canonical activity JSON (after the channel's middleware) is kept in the
  delivery's metadata and the delivery stays `pending` (`{:pending, meta}`).
  The outbox lists those deliveries oldest first; a later poll's
  `watermark` acknowledges everything up to it that was served, which marks
  those deliveries `sent`. Nothing leaves the outbox unacknowledged, so a
  consumer that crashes before it acknowledges gets the same items again
  (at least once). See `ConvergerWeb.ChannelOutboxController`,
  `docs/channels/http-pull.md` and ADR-0048.
  """

  use Converger.Channels.Adapter, type: "http_pull"

  alias Converger.Activities.Serializer

  # Lifecycle events go to the outbox too: like a webhook consumer, the
  # integrator wants to know when a conversation closes.
  @impl true
  def capabilities, do: [:outbound, :lifecycle_events]

  @doc "The delivery metadata key holding the canonical activity."
  def payload_key, do: "outbox"

  @impl true
  def deliver_activity(_channel, activity) do
    {:pending, %{payload_key() => Serializer.canonical(activity)}}
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "http_pull channels are outbound only: poll GET /api/v1/channels/:id/outbox"}
  end
end
