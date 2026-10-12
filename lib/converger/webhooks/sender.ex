defmodule Converger.Webhooks.Sender do
  @moduledoc """
  Sends one `Converger.Webhooks.Event` to its subscription.

  The request reuses the webhook adapter's hardening (ADR-0014): the target
  is re-checked and pinned by `Converger.Channels.UrlGuard`, redirects are
  not followed, timeouts and the response size are bounded, and the body is
  signed with `Converger.Channels.InboundSignature.sign/3`:

      POST <subscription url>
      content-type: application/json
      user-agent: Converger-Webhooks/1
      x-converger-event: delivery.failed
      x-converger-event-id: <event_id, same for every subscription>
      x-converger-delivery-id: <webhook_events.id, stable across retries>
      x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>

  Body (`body/2`):

      {"id": "<event_id>", "type": "delivery.failed", "created_at": "...",
       "tenant_id": "...", "data": {...}}

  A subscription managed by `tenants.alert_webhook_url` gets the legacy
  alert body instead (see `Converger.Webhooks.sync_alert_subscription/1`).

  Limits come from `config :converger, :platform_webhooks` (`connect_timeout`,
  default 5000 ms; `receive_timeout`, default 10000 ms; `max_response_bytes`,
  default 65536). Tests can merge Req options with
  `config :converger, :platform_webhook_req_options`.
  """

  alias Converger.Channels.{DeliveryError, InboundSignature, OutboundRequest, UrlGuard}
  alias Converger.Webhooks.{Event, Subscription}

  @user_agent "Converger-Webhooks/1"

  @doc """
  POSTs `event` to `subscription`. Returns `{:ok, status}` for a 2xx
  response, otherwise `{:error, %DeliveryError{}}` (with `status` when the
  receiver answered).
  """
  @spec deliver(Subscription.t(), Event.t()) ::
          {:ok, pos_integer()} | {:error, DeliveryError.t()}
  def deliver(%Subscription{} = subscription, %Event{} = event) do
    with {:ok, target} <- resolve_target(subscription.url) do
      body = subscription |> body(event) |> Jason.encode!()

      headers =
        OutboundRequest.user_headers(subscription.headers) ++
          [
            {"content-type", "application/json"},
            {"user-agent", @user_agent},
            {"x-converger-event", event.type},
            {"x-converger-event-id", event.event_id},
            {"x-converger-delivery-id", event.id},
            {"x-converger-signature", InboundSignature.sign(subscription.secret, body)}
          ]

      [
        method: :post,
        body: body,
        headers: headers,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        receive_timeout: config(:receive_timeout, 10_000),
        into: OutboundRequest.limited_body(config(:max_response_bytes, 65_536))
      ]
      |> OutboundRequest.pin(target, config(:connect_timeout, 5_000))
      |> Keyword.merge(Application.get_env(:converger, :platform_webhook_req_options, []))
      |> Converger.HTTP.request()
      |> case do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, status}

        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:error, DeliveryError.from_http(status, headers, truncate(body), "webhook")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "webhook")}
      end
    end
  end

  @doc "The JSON body sent for `event` (before encoding)."
  def body(%Subscription{managed_by: "alert_webhook_url"}, %Event{} = event),
    do: legacy_alert_body(event)

  def body(_subscription, %Event{} = event), do: envelope(event)

  defp envelope(event) do
    %{
      id: event.event_id,
      type: event.type,
      created_at: event.inserted_at,
      tenant_id: event.tenant_id,
      data: event.payload
    }
  end

  # The body tenants.alert_webhook_url received before platform webhooks.
  defp legacy_alert_body(%Event{type: "channel.health_changed", payload: data}) do
    %{
      event: "channel_health_changed",
      channel_id: data["channel_id"],
      channel_name: data["channel_name"],
      tenant_id: data["tenant_id"],
      previous_status: data["previous_status"],
      new_status: data["status"],
      failure_rate: data["failure_rate"],
      total_deliveries: data["total_deliveries"],
      failed_deliveries: data["failed_deliveries"],
      checked_at: data["checked_at"]
    }
  end

  defp legacy_alert_body(%Event{type: "channel.circuit_" <> _ = type, payload: data}) do
    %{
      event: type,
      channel_id: data["channel_id"],
      channel_name: data["channel_name"],
      tenant_id: data["tenant_id"],
      reason: data["reason"],
      changed_at: data["changed_at"]
    }
  end

  defp legacy_alert_body(event), do: envelope(event)

  # An unresolvable host may be a transient DNS failure (retried); an invalid
  # URL or a blocked private target is permanent.
  defp resolve_target(url) do
    case UrlGuard.resolve(url || "") do
      {:ok, target} ->
        {:ok, target}

      {:error, {:unresolvable, _host} = reason} ->
        {:error,
         %DeliveryError{reason: "webhook target rejected: #{UrlGuard.format_error(reason)}"}}

      {:error, reason} ->
        {:error,
         DeliveryError.permanent("webhook target rejected: #{UrlGuard.format_error(reason)}")}
    end
  end

  defp truncate(body) when is_binary(body) and byte_size(body) > 512,
    do: binary_part(body, 0, 512) <> "..."

  defp truncate(body), do: body

  defp config(key, default) do
    :converger |> Application.get_env(:platform_webhooks, []) |> Keyword.get(key, default)
  end
end
