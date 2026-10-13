---
title: Writing an adapter
description: Step-by-step guide to adding a new channel adapter to Converger, from the behaviour module to registration, secrets, inbound parsing, error classification, tests and docs.
sidebar_position: 5
---

This guide walks through adding a new channel type. The running example is a fictional SMS provider, **Acme SMS**, with type string `acme_sms`. It sends text messages over a JSON HTTP API, posts batched inbound messages and delivery reports to a webhook, and signs its webhooks with an HMAC header.

Before you start, read [Channels and adapters](overview.md) for the behaviour, the inbound endpoint and the signature policy. The smallest complete adapter in the code base is [echo](echo.md); the most complete ones are [`whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex) and [`webhook.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex).

An adapter is **one module plus one config line**. The module declares its type string, what it can do (`capabilities/0`) and its config fields (`config_schema/0`). From those declarations Converger derives the channel type list, config validation, the admin config form, health checks, pipeline delivery and the inbound response policy, so no file outside the adapter needs editing ([ADR-0038](../adr/0038-adapter-behaviour-v2-and-config-driven-registry.md)).

## The smallest adapter: echo

The built-in [echo](echo.md) adapter is complete in a few lines. It delivers outbound only and has no config:

```elixir
defmodule Converger.Channels.Adapters.Echo do
  use Converger.Channels.Adapter, type: "echo"

  # Outbound only, so its only supported mode is `outbound`.
  @impl true
  def capabilities, do: [:outbound, activity_types: ~w(message)]

  @impl true
  def deliver_activity(_channel, %{metadata: %{"echo_of" => _}}), do: :ok

  def deliver_activity(_channel, activity) do
    result =
      Converger.Activities.create_activity(%{
        "tenant_id" => activity.tenant_id,
        "conversation_id" => activity.conversation_id,
        "text" => activity.text,
        "sender" => "bot",
        "metadata" => %{"echo_of" => activity.id},
        "idempotency_key" => "echo:#{activity.id}"
      })

    case result do
      {:ok, _reply} -> :ok
      {:error, :conversation_closed} -> :ok
      {:error, reason} -> {:error, {:echo_failed, reason}}
    end
  end

  @impl true
  def parse_inbound(_channel, _params),
    do: {:error, "echo channel does not support inbound webhooks"}
end
```

`use Converger.Channels.Adapter, type: "echo"` sets `@behaviour`, defines `type/0`, and gives every optional callback that has a sensible value a default you can override:

| Default | Value |
| --- | --- |
| `capabilities/0` | `[:inbound, :outbound]` |
| `supported_modes/0` | derived from `capabilities/0`: `duplex` needs both `:inbound` and `:outbound`, so echo gets `["outbound"]` |
| `config_schema/0` | `[]` |
| `validate_config/1` | `:ok` (the schema is checked before it anyway) |
| `retry_policy/0` | `%{}` |
| `rate_limit/0` | `nil` |
| `normalize_error/1` | `DeliveryError.normalize/1` |

What remains to write is `deliver_activity/2` and `parse_inbound/2`. A returned `{:error, {:echo_failed, reason}}` is classified as retryable by the default `normalize_error/1`.

## 1. Implement the behaviour

The rest of this guide builds a richer adapter. Create `lib/converger/channels/adapters/acme_sms.ex` (or any module in a fork or a dependency). One module per file (nested modules are not allowed in this code base).

```elixir
defmodule Converger.Channels.Adapters.AcmeSms do
  @moduledoc """
  Acme SMS channel. Config fields: see `config_schema/0`.
  """

  use Converger.Channels.Adapter, type: "acme_sms"

  alias Converger.Channels.{DeliveryError, InboundSignature, UrlGuard}
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy

  @impl true
  def capabilities,
    do: [:inbound, :outbound, :external_delivery, :receipts, :provider_ack, activity_types: ~w(message)]

  # Validates channel.config and renders the admin form.
  @impl true
  def config_schema do
    [
      %{name: "base_url", type: :url, required: true, label: "Base URL",
        placeholder: "https://api.acme-sms.example"},
      %{name: "api_key", type: :string, required: true, secret: true, label: "API key"},
      %{name: "sender", type: :string, required: true, label: "Sender", summary: true},
      %{name: "webhook_secret", type: :string, required: :with_signature, secret: true,
        label: "Webhook secret", help: "Verifies X-Acme-Signature on inbound webhooks"}
    ]
  end

  # Runs after the schema checks: only what the schema cannot express.
  @impl true
  def validate_config(config) do
    case UrlGuard.check(config["base_url"]) do
      :ok -> :ok
      {:error, message} -> {:error, "acme_sms config 'base_url' is not allowed: #{message}"}
    end
  end

  @impl true
  def retry_policy, do: %{timeout_ms: 10_000}

  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}

    recipient =
      activity.metadata["to"] || Participants.recipient_for(activity, Map.get(channel, :id))

    with {:recipient, to} when is_binary(to) <- {:recipient, recipient},
         {:ok, _target} <- resolve(config["base_url"]) do
      options =
        [
          method: :post,
          url: config["base_url"] <> "/v1/messages",
          json: %{from: config["sender"], to: to, text: activity.text},
          headers: [{"authorization", "Bearer #{config["api_key"]}"}],
          receive_timeout: RetryPolicy.for_channel(channel).timeout_ms
        ]
        |> Keyword.merge(Application.get_env(:converger, :acme_sms_req_options, []))

      case Converger.HTTP.request(options) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, %{provider_message_id: body["id"]}}

        {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
          {:error, DeliveryError.from_http(status, headers, body, "Acme API")}

        {:error, reason} ->
          {:error, DeliveryError.from_transport(reason, "Acme API")}
      end
    else
      {:recipient, _} ->
        {:error, DeliveryError.permanent("no recipient: set metadata 'to' or reply to a participant")}

      {:error, %DeliveryError{}} = error ->
        error
    end
  end

  # An unresolvable host may be a transient DNS failure (retryable); a blocked
  # private target is permanent.
  defp resolve(url) do
    case UrlGuard.resolve(url || "") do
      {:ok, target} ->
        {:ok, target}

      {:error, {:unresolvable, _} = reason} ->
        {:error, %DeliveryError{reason: "Acme target rejected: #{UrlGuard.format_error(reason)}"}}

      {:error, reason} ->
        {:error, DeliveryError.permanent("Acme target rejected: #{UrlGuard.format_error(reason)}")}
    end
  end

  @impl true
  def parse_inbound(_channel, %{"messages" => messages}) when is_list(messages) do
    {:ok, for(%{"id" => id, "from" => from} = m <- messages, do: parse_message(id, from, m))}
  end

  def parse_inbound(_channel, %{"reports" => reports}) when is_list(reports), do: {:ok, []}
  def parse_inbound(_channel, _params), do: {:error, "unable to parse Acme SMS webhook payload"}

  defp parse_message(id, from, message) do
    %{
      "sender" => from,
      "text" => message["text"] || "",
      "type" => "message",
      "attachments" => [],
      "metadata" => %{"acme_message_id" => id},
      "idempotency_key" => "acme:" <> id,
      "participant" => %{"external_id" => from, "display_name" => message["name"]}
    }
  end

  @impl true
  def parse_status_update(_channel, %{"reports" => reports}) when is_list(reports) do
    case for(%{"message_id" => id, "state" => state} = r <- reports, do: report(id, state, r)) do
      [] -> :ignore
      updates -> {:ok, updates}
    end
  end

  def parse_status_update(_channel, _params), do: :ignore

  defp report(id, state, report) do
    %{
      "provider_message_id" => id,
      "status" => normalize(state),
      "timestamp" => report["at"],
      "error" => report["error"]
    }
  end

  defp normalize("DELIVERED"), do: "delivered"
  defp normalize("FAILED"), do: "failed"
  defp normalize(_), do: "sent"

  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    secret = (channel.config || %{})["webhook_secret"]

    case InboundSignature.get_header(headers, "x-acme-signature") do
      nil ->
        :missing

      _ when not is_binary(secret) or secret == "" ->
        :missing

      signature ->
        expected = InboundSignature.hmac_hex(secret, raw_body || "")

        if Plug.Crypto.secure_compare(expected, String.downcase(signature)),
          do: :ok,
          else: {:error, :invalid_signature}
    end
  end
end
```

Callback checklist:

| Callback | Required | Notes |
| --- | --- | --- |
| `type/0` | yes (defined by `use`) | The channel type string. Plain strings only, never atoms built from input. |
| `deliver_activity/2` | yes | Called only by the pipeline. Return `:ok`, `{:ok, map}` or `{:error, reason}`, preferably `{:error, %DeliveryError{}}`. Put the provider's message id under `provider_message_id` in the map, so receipts can find the delivery. Return `{:pending, map}` only when the hand-off succeeded but receipt is confirmed later (the `websocket` adapter); the delivery stays `pending` without a retry. |
| `parse_inbound/2` | yes | Return a list, even for one message. An empty list for payloads with only receipts. `{:error, message}` when the body is not your provider's format at all (answered with `400`). Adapters without inbound support return `{:error, "..."}` unconditionally. |
| `capabilities/0` | no (default `[:inbound, :outbound]`) | What the adapter can do; see [capabilities](#capabilities) below. |
| `supported_modes/0` | no (derived) | Subset of `inbound`, `outbound`, `duplex`, derived from `:inbound` / `:outbound`. The channel changeset enforces it. |
| `config_schema/0` | no (default `[]`) | Config fields; see [config validation](#3-config-validation). |
| `validate_config/1` | no (default `:ok`) | Rules the schema cannot express. Runs after the schema checks on every create and update. Return `{:error, "<type> config ..."}`; it is shown as a `config` error in the admin UI. |
| `parse_status_update/2` | no | `{:ok, [update]}` or `:ignore`. |
| `verify_inbound_signature/3` | no | Implement when the provider signs webhooks natively. Without it, the generic `x-converger-signature` scheme keyed with the channel `secret` applies. |
| `verify_subscription/2` | no | The provider's `GET` webhook handshake (Meta's `hub.challenge`): return `{:ok, body}` (sent with `200`) or `:error` (`403`). Without it, `GET .../inbound` answers `200 ok`. |
| `inbound_challenge/2` | no | A handshake that arrives as an ordinary signed `POST` to `.../inbound` (Slack's `url_verification`): return `{:ok, map}` to answer it with that JSON and `200`, or `:none` to process the request as usual. Called after the signature check, before parsing. |
| `retry_policy/0` | no | Adapter defaults (`max_attempts`, `backoff`, `base_ms`, `max_ms`, `timeout_ms`) between the global config and the channel's own `retry_policy`. |
| `normalize_error/1` | no (default `DeliveryError.normalize/1`) | Classifies an `{:error, reason}` from `deliver_activity/2`; see [delivery errors](#6-delivery-errors). |
| `rate_limit/0` | no | The provider's default outbound rate (`"80/s"`) when the channel sets none. |
| `health_probe/1` | no | Check the provider account (for example a "me" endpoint) for channels without recent deliveries; see [health probe](#health-probe). |
| `send_typing/2` | no | Show (or clear) a typing indicator to the channel's participant when a WebSocket participant types. Return `:ok` or `{:error, reason}`. |
| `send_read_receipt/2` | no | Tell the provider the participant's messages were read when a WebSocket participant sends `read`. Return `:ok` or `{:error, reason}`. |
| `fetch_media/2` | no | Download the file behind an inbound media stub that `parse_inbound/2` returned (an attachment with a provider media id or URL in `channelData` and no `contentUrl`). Return `{:ok, %{data: binary, filename: name_or_nil}}`, `:skip` (nothing to download) or `{:error, reason}`. Converger stores the file and sets `contentUrl`; on error the stub is kept. See [inbound media](#inbound-media). |
| `list_templates/1` | no | List the provider message templates of the channel's account (`{:ok, [map]}`), served and cached by `GET /api/v1/channels/:id/templates`. Return `{:error, {:invalid_config, message}}` (`422`) when the config lacks what the call needs, `{:error, message}` (`502`) when the provider fails. |

### Capabilities

`capabilities/0` returns a list. Each entry changes how the rest of Converger treats the adapter's channels:

| Entry | Effect |
| --- | --- |
| `:inbound` | Accepts inbound messages. Together with `:outbound` it allows the `duplex` mode. |
| `:outbound` | The pipeline creates deliveries for its channels and calls `deliver_activity/2`. |
| `:external_delivery` | Delivers to a provider outside Converger: its channels get [health checks](overview.md#channel-health) and appear on the admin dashboard. |
| `:receipts` | Reports delivery or read receipts (`parse_status_update/2`). |
| `:typing` | Forwards typing indicators (`send_typing/2`). |
| `:lifecycle_events` | Receives conversation close and reopen events, which carry no message content. Leave it out for messaging providers, which would send an empty message. |
| `:provider_ack` | The provider retries every non-`2xx` inbound response (for days, in Meta's case), so a handled request is always answered `200`, even when its messages were rejected permanently. |
| `:consumer` | Inbound messages are pulled by a consumer Converger runs, one per channel in the cluster (a broker subscription, a provider stream such as the Discord Gateway), instead of (or besides) the inbound webhook. The adapter also implements `Converger.Channels.Broker`; see [broker adapters](#broker-adapters-optional). |
| `:media`, `:templates`, `:reactions`, `:edits` | Outbound content the adapter renders natively (descriptive: nothing in Converger branches on them yet; the WhatsApp adapters declare `:media` and `:templates`, see [#68](https://github.com/AimTune/converger/issues/68) for typed messages). |
| `activity_types: [...]` | The activity types `deliver_activity/2` renders natively; see [capabilities and downgrade](#capabilities-and-downgrade). |

`Converger.Channels.Adapter.types_with/1` lists the registered types with a capability, and `capability?/2` checks one type.

### Health probe

`Converger.Channels.Health` checks every active channel whose adapter has `:external_delivery` every five minutes, from its delivery failure rate. A channel without deliveries in the window would stay `unknown`. When the adapter implements `health_probe/1`, the check calls it instead: `:ok` makes the channel `healthy`, and `{:error, reason}` (or a raise) makes it `degraded` and logs the reason. A probe failure never makes a channel `unhealthy`, so one failed call cannot open the circuit breaker. Keep the probe cheap: one read-only request, a timeout of a few seconds, `retry: false`. The WhatsApp Cloud API adapter reads the channel's phone number (`GET /<version>/<phone_number_id>?fields=id`). Probes are switched off with `config :converger, :channel_health, probe_idle_channels: false`.

### Typing and read receipts (optional)

`Converger.Channels.Signals` calls `send_typing/2` and `send_read_receipt/2` for the channels an activity from the same sender would be delivered to, but only when your adapter implements the callback and the conversation has a participant on the channel. Both receive the channel and a signal map:

| Key | Value |
| --- | --- |
| `:conversation_id` | the conversation |
| `:recipient` | the participant's `external_id` on your channel (the number to address) |
| `:provider_message_id` | the `idempotency_key` of the participant's latest inbound activity (for read receipts: the latest one up to `:up_to_seq`), or `nil` |
| `:is_typing` | typing only: `true` or `false` |
| `:up_to_seq` | read receipts only: everything up to this `seq` was read |

Signals are best effort: they run in a task under `Converger.TaskSupervisor`, are never retried, and an `{:error, reason}` or a raise is only logged. Do not retry inside the callback (pass `retry: false` to Req). Return `:ok` without calling the provider when there is nothing to do, for example `is_typing: false` on a provider that clears indicators on its own, or a `nil` `:provider_message_id`. Typing is forwarded at most every 20 seconds per WebSocket connection. See [ADR-0032](../adr/0032-transient-conversation-signals.md) and the WhatsApp Cloud API implementation in `whatsapp_meta.ex`.

### Webhook registration (optional)

If the provider registers its webhook through an API call (Telegram `setWebhook`), implement `register_webhook(channel, inbound_url)` and return `:ok` or `{:error, reason}` (a readable string is shown to the admin). The admin channel list then shows a **Register webhook** button for your channels; it calls `Channels.register_webhook/3` with the channel's public inbound URL (`https://<PHX_HOST>/api/v1/channels/<id>/inbound`) and audits a successful call as `register_webhook`. Pass the channel's verification secret to the provider in the same call, as the Telegram adapter passes `secret_token`. Use `retry: false` and a timeout of a few seconds: an admin is waiting for the answer.

### Broker adapters (optional)

An adapter whose inbound side is a broker topic or queue (the built-in [`kafka`](kafka.md), [`rabbitmq`](rabbitmq.md)
and [`mqtt`](mqtt.md)) or another connection Converger keeps open (the [Discord Gateway](discord.md#gateway-mode))
declares the `:consumer` capability and implements the `Converger.Channels.Broker` behaviour next to the adapter one.
Every callback is optional; a Broadway consumer implements the first three:

| Callback | Returns | Purpose |
| --- | --- | --- |
| `consumer_options(channel)` | `{:ok, keyword}` or `{:error, message}` | Broadway options of the channel's consumer: `producer: [module: {ProducerModule, opts}, concurrency: 1]` and `processors: [default: [concurrency: n]]`. |
| `message_info(channel, %Broadway.Message{})` | `%{payload:, message_id:, source:, key:, headers:}` | The body and the broker message id (stable across redeliveries: it becomes the idempotency key), plus what dead-lettering keeps. |
| `dead_letter(channel, info, reason)` | `:ok` or `{:error, term}` | Write a poison message to the channel's dead-letter destination. Retried until it returns `:ok`. Without it, such messages are logged and dropped. |
| `consumer_child_spec(channel)` | a child spec | The consumer process when it is not a Broadway pipeline (the MQTT subscriber, the Discord Gateway connection). Its `start_link` returns `{:error, reason}` for a channel it cannot consume. It hands each message to `Broker.handle/4` (an envelope payload) or `Broker.handle_message/5` (a message it parsed itself). |
| `consume?(channel)` | boolean | Whether this channel needs a consumer, when it depends on the config (Discord: `gateway: true`). Default: every active `inbound` or `duplex` channel of the type. |

Everything else is shared: `Converger.Channels.Consumers` starts one consumer per active inbound channel in the
cluster and follows channel changes, and `Converger.Channels.Broker.handle/4` decodes the
[envelope](brokers.md#envelope), applies idempotency, retries transient failures and dead-letters poison messages.
`deliver_activity/2` should skip activities consumed from the same channel (`Broker.echo?/2`). Use `required: :inbound`
and `required: :outbound` for the topics in `config_schema/0`. See [Broker channels](brokers.md) and
[ADR-0047](../adr/0047-broker-channels-kafka-and-rabbitmq.md) and [ADR-0055](../adr/0055-mqtt-channel-and-discord-gateway.md).

## 2. Register the type

Add the module to the registry with one config line, in `config/config.exs` of your fork or application:

```elixir
config :converger, :adapters, [Converger.Channels.Adapters.AcmeSms]
```

The registry (`Converger.Channels.Adapter.adapters/0`) is the built-in adapters (`echo`, `webhook`, `websocket`, `whatsapp_meta`, `whatsapp_infobip`, `slack`, `telegram`, `email`, `sms_twilio`, `sms_vonage`, `messenger`, `instagram`, `viber`, `discord`, `teams`, `http_pull`, `kafka`, `rabbitmq`, `mqtt`) followed by this list, in order. An adapter whose `type/0` equals a built-in type replaces the built-in, so a fork can swap an implementation without patching core. A built-in adapter that ships with Converger itself is added to `@builtin_adapters` in `adapter.ex` instead.

That is all. From the registry and the adapter's declarations:

| What | Derived from |
| --- | --- |
| Accepted `type` values and the admin type dropdown (`Channel.channel_types/0`) | the registry |
| Dispatch of every callback (`Adapter.adapter_for/1`) | the registry |
| Config validation and the admin config form (labels, password inputs, summary in the channel list) | `config_schema/0` |
| Allowed modes | `capabilities/0` (`:inbound`, `:outbound`) |
| Pipeline delivery | `:outbound` |
| Health checks and dashboard health | `:external_delivery` |
| Lifecycle events | `:lifecycle_events` |
| `200` for handled inbound requests | `:provider_ack` |
| Webhook verification handshake (`GET`) | `verify_subscription/2` |
| In-band handshake (`POST`) | `inbound_challenge/2` |
| Receipt correlation | the `provider_message_id` key returned by `deliver_activity/2` |

`Converger.Application` calls `Adapter.validate_registry!/0` at boot: a configured module that does not exist, does not implement `type/0`, `supported_modes/0`, `deliver_activity/2` and `parse_inbound/2`, or returns an empty type string stops the boot with an `ArgumentError` naming it.

Channel types are plain strings, never atoms created from input. Unknown types fail with `{:error, "unknown channel type: ..."}`.

## 3. Config validation

`config_schema/0` returns one map per config field:

| Key | Values | Meaning |
| --- | --- | --- |
| `name` | string | The config key. |
| `type` | `:string`, `:url`, `:integer`, `:boolean`, `:map` | Checked when the value is present. `:url` must be `http` or `https` with a host; `:integer` and `:boolean` also accept the strings the admin form sends (`"5000"`, `"true"`). |
| `required` | `true`, `false` (default), `:with_signature`, `:inbound`, `:outbound` | `:with_signature` makes the field required only on channels with `require_signature: true`, for a provider signing key (Meta's `app_secret`). `:inbound` and `:outbound` make it required only on channels whose mode includes that direction (`duplex` includes both), for a topic to consume or produce to ([Kafka](kafka.md)). |
| `secret` | boolean | Rendered as a password input and masked in the admin channel list. |
| `label`, `placeholder`, `help` | string | Admin form texts. |
| `summary` | boolean | Shown next to the channel in the admin channel list (`Label: value`, or the bare value for a `:url`). |
| `form` | boolean | `false` hides the field from the admin form (API only). `:map` fields are never shown in the form. |

`Converger.Channels.Adapter.validate_config/3` checks the schema first, then calls the adapter's `validate_config/1`. Errors are `config` errors on the changeset: `acme_sms config missing: api_key, sender`, `acme_sms config missing: webhook_secret (required when require_signature is true)`, `acme_sms config 'base_url' must be a valid HTTP/HTTPS URL`. Keys that are not in the schema are allowed (for example `conversation_idle_timeout_seconds` and `unsupported_activities`, which apply to every type).

- Put only rules the schema cannot express in `validate_config/1`: limits, allowed values, the SSRF guard.
- Do not perform network calls in validation except through `UrlGuard.check/1`, which accepts unresolvable hosts and leaves the final check to request time.

## 4. Secrets

- The whole `config` map is stored with `Converger.Encrypted.Map` (Cloak, AES key from `CLOAK_KEY`), and the channel `secret` with `Converger.Encrypted.Binary`. Nothing extra is needed to encrypt a new config key at rest. See [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md).
- Mark secret fields `secret: true` in `config_schema/0`: the admin form renders them as password inputs and the admin channel list masks them.
- **Audit redaction depends on the key name.** `Converger.Secrets.redact/1` (audit logs) and the admin config view mask keys named `access_token`, `api_key`, `secret`, `token`, `password`, `password_hash`, `verify_token`, `app_secret`, `authorization`, `x-api-key`, `x-channel-token`, and any key ending in `_secret`, `_token`, `_hash` or `_password`. Name secret config keys so they match (`api_key`, `webhook_secret`, `refresh_token`), never `key` or `credentials`.
- Never log `channel.config` or request headers unredacted.

## 5. Inbound parsing and idempotency

- **Return every message of a batch.** Returning only the first one was the bug fixed in [#15](https://github.com/AimTune/converger/issues/15); see [ADR-0015](../adr/0015-per-message-idempotent-inbound-batches.md).
- **Set `idempotency_key`** to a stable provider message id. The controller checks it across all conversations of the channel before creating an activity, so a re-delivered webhook produces duplicates, not new activities. Use an id that is unique per channel; prefixing it (`"acme:" <> id`) is optional but makes the origin obvious. Never derive it from a timestamp or from the body hash of a whole batch.
- **Set `participant.external_id`** to the sender's address (phone number, chat id) so messages from the same party share their active conversation and replies can find the recipient through `Participants.recipient_for/2` ([ADR-0016](../adr/0016-participant-based-conversation-resolution.md)).
- **Keep unknown message types** as activities (empty text, `metadata` with the provider type) rather than dropping them.
- Map media to attachment stubs: `contentType` (required, a MIME type; use a wildcard such as `image/*` when the provider does not say) plus provider fields under `channelData` (`provider`, `providerMediaId`). Attachments are validated, so keys outside the [attachment schema](../concepts/activities.md#attachments) are dropped. Do not download media in `parse_inbound/2`; implement `fetch_media/2` instead (below).
- Map reactions to `messageReaction` (`text` is the emoji) and replies to `message`, and set `reply_to_provider_id` to the provider id of the referenced message; the controller resolves it to `reply_to_id` and keeps an unresolvable reaction as an `event`.
- Only client fields of the parsed message (`type`, `text`, `attachments`, `metadata`, `reply_to_id`) end up on the activity; `sender` and `idempotency_key` are passed by the controller as server-controlled attributes.
- Receipts: normalize `status` to one of `sent`, `delivered`, `read`, `failed`. Any other value is silently ignored by `Deliveries.advance_status/2` (it has no rank), so map unknown provider states explicitly, as both WhatsApp adapters map them to `sent`.

### Inbound media

When the adapter implements `fetch_media/2`, `Converger.Inbound.Media` calls it for every attachment of a parsed message that has no `contentUrl`, after the duplicate check and before the activity is created. It stores the returned bytes through `Converger.Uploads` (size limit, sniffed type, tenant allowlist), links the file to the activity, and rewrites the attachment with `contentUrl`, `contentType` and `size`. On `{:error, reason}` the stub is kept with `channelData.downloadError`; the message is never dropped. Channels opt out with the config key `download_media: false`.

- Use `Converger.Channels.MediaDownload.get/2`: it streams the body and stops at the upload size limit, with a 10 s default timeout.
- Treat URLs from the webhook body as untrusted. Send credentials only to the provider's own host (the Infobip adapter requires the media URL host to equal the channel's `base_url` host) and keep the SSRF guard ([section 7](#7-http-and-user-supplied-urls)).
- Return `:skip` for attachments that have nothing to download (locations, contacts).

See [ADR-0039](../adr/0039-whatsapp-rich-outbound-and-inbound-media-download.md).

### Capabilities and downgrade

Declare the [activity types](../concepts/activities.md#types) the adapter can deliver as such:

```elixir
@impl true
def capabilities, do: [:inbound, :outbound, activity_types: ~w(message)]
```

The pipeline (`Converger.Activities.Downgrade`) hands the adapter only those types. Any other type is turned into a `message` with a text rendering (`"user reacted with 👍"`, `"(edited) new text"`, `"user deleted a message"`), or skipped when it has no text (typing, a removed reaction, an event without text), or skipped altogether when the channel config sets `"unsupported_activities": "skip"`. Skipped activities get no delivery row. An adapter without an `activity_types` entry receives every client type, as before [#28](https://github.com/AimTune/converger/issues/28). List a type only when `deliver_activity/2` really renders it (WhatsApp would need the target's `wamid` to send a native reaction).

## 6. Delivery errors

Return `{:error, %Converger.Channels.DeliveryError{}}` so the pipeline can tell retryable from permanent failures ([ADR-0019](../adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md)):

- non-`2xx` responses: `DeliveryError.from_http(status, headers, body, "Acme API")` (retryable for `408`, `425`, `429`, `5xx`; permanent otherwise; honours `Retry-After`);
- transport failures: `DeliveryError.from_transport(reason, "Acme API")` (retryable);
- configuration or input errors no retry can fix (no recipient, invalid method, blocked target): `DeliveryError.permanent(message)`.

Every `{:error, reason}` goes through the adapter's `normalize_error/1` before the circuit breaker and the retry policy see it. The default (`DeliveryError.normalize/1`) keeps a `DeliveryError`, turns a map with `:reason`, `:retryable?` and `:retry_after_ms` into one, and treats any other term as retryable, which wastes attempts on permanent failures. When a provider SDK or helper returns its own error terms, override `normalize_error/1` instead of wrapping every call site:

```elixir
@impl true
def normalize_error({:acme, %{"code" => "INVALID_NUMBER"}}),
  do: %{reason: "invalid number", retryable?: false, retry_after_ms: nil}

def normalize_error({:acme, %{"code" => "THROTTLED", "retry_in" => s}}),
  do: %{reason: "throttled", retryable?: true, retry_after_ms: s * 1000}

def normalize_error(reason), do: DeliveryError.normalize(reason)
```

`retryable?: false` dead-letters the delivery after this attempt; `retry_after_ms` replaces the policy backoff for the next attempt.

## 7. HTTP and user-supplied URLs

- Use [`Converger.HTTP`](https://github.com/AimTune/converger/blob/main/lib/converger/http.ex) (`request/1`, `post/2`) for outbound calls. It wraps Req and attaches `OpentelemetryReq`, so each call becomes a client span under the delivery job's span. (The existing webhook and WhatsApp adapters still call `Req` directly.) Do not add other HTTP clients.
- Set `receive_timeout` from `RetryPolicy.for_channel(channel).timeout_ms`.
- Merge test options from the application env (`Application.get_env(:converger, :acme_sms_req_options, [])`), the same pattern as `:webhook_req_options` and `:whatsapp_req_options`, so tests can inject `plug: {Req.Test, ...}`.
- A provider API URL that carries a credential (Telegram puts the bot token in the path) must not be a tenant setting at all: make it application config, as `config :converger, Converger.Channels.Adapters.Telegram, api_base_url: ...`. Such adapters call `Req` directly, because `OpentelemetryReq` records the full URL (`url.full`) on the client span.
- Any URL a tenant can configure (a base URL, a callback URL) must pass [`Converger.Channels.UrlGuard`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/url_guard.ex): `check/1` at config validation and `resolve/1` before every request. `resolve/1` returns the checked address; to defeat DNS rebinding, pin the connection to it the way the webhook adapter does (`target_url/1` and `connect_options/2` with `hostname:`), and disable redirects (`redirect: false`). The guard is configured with `config :converger, :webhook, allow_private_targets: ..., allowed_targets: [...]` (`WEBHOOK_ALLOW_PRIVATE_TARGETS`, `WEBHOOK_ALLOWED_TARGETS` in releases). See [ADR-0014](../adr/0014-webhook-ssrf-guard-and-outbound-signing.md) and [Outbound webhooks](../webhooks.md#ssrf-protection).

The example above checks `base_url` but, for brevity, does not pin the connection.

## 8. Signatures

- If the provider signs webhooks, implement `verify_inbound_signature/3` and return `:ok`, `{:error, reason}` for a present but invalid signature, and `:missing` when there is no header **or** no secret configured. The controller then applies the channel's `require_signature` policy ([ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md)).
- Verify over `raw_body` (the exact bytes; `CacheBodyReader` caches them for `/api/v1/channels/*`), never over re-encoded params. Compare with `Plug.Crypto.secure_compare/2`.
- If the provider cannot sign at all, do not implement the callback: senders then use the generic `x-converger-signature` header with the channel `secret`, or the channel must be created with `require_signature: false`.
- If the provider's scheme needs a secret, declare it with `required: :with_signature` in `config_schema/0`, as `whatsapp_meta` does for `app_secret`: channels with `require_signature: true` cannot be saved without it.
- If the provider verifies the webhook URL with a `GET` handshake, implement `verify_subscription/2`. If it posts the handshake to the webhook URL itself, implement `inbound_challenge/2` (see `slack.ex`).
- If the provider expects a particular body in the answer to a webhook (Twilio flags any non-TwiML response), implement `inbound_response/1` returning `{content_type, body}` (see `sms_twilio.ex`). When the answer depends on the request (a Discord interaction response, a Teams invoke response), implement `inbound_response/2`, which also gets the params and may return `:default` (see `discord.ex`).
- If the signature covers the request URL (Twilio), note that the adapter does not see it: rebuild the candidate URLs from the channel id and the server URL, as `sms_twilio.ex` does.

## 9. Tests

Mirror the existing adapter tests:

| Test file to add | Pattern to copy | What to cover |
| --- | --- | --- |
| `test/converger/channels/adapters/acme_sms_test.exs` | [`whatsapp_meta_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/whatsapp_meta_test.exs), [`whatsapp_infobip_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/whatsapp_infobip_test.exs) | `use ExUnit.Case, async: true` with a plain `%{type: "acme_sms", config: %{}}` map; real provider payload fixtures; every message of a batch parsed in order with its `idempotency_key`; receipts and status normalization; `:ignore` and `{:error, _}` cases |
| `test/converger/channels/adapters/acme_sms_delivery_test.exs` | [`webhook_delivery_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/webhook_delivery_test.exs) | `use Converger.DataCase, async: false` (it mutates app env); `Application.put_env(:converger, :acme_sms_req_options, plug: {Req.Test, __MODULE__})` and restore it `on_exit`; `Req.Test.stub/2` to assert the request and return `200`, `400`, `429` with `Retry-After`, `503`; assert `DeliveryError` classification |
| controller tests | [`inbound_batch_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_batch_test.exs), [`inbound_signature_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_signature_test.exs) | `use ConvergerWeb.ConnCase`; create the channel with `Channels.create_channel/1`; a batch of 3 creates 3 activities; re-delivery creates none (`"duplicates" => 3`); a partially processed batch completes; valid, invalid, tampered and missing signatures |
| retry policy | [`channel_retry_policy_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/channel_retry_policy_test.exs) | end-to-end with `Oban.Testing`: a permanent error is dead-lettered after one attempt |
| registration (adapters outside core) | [`adapter_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapter_test.exs) with [`test_sms_adapter.ex`](https://github.com/AimTune/converger/blob/main/test/support/test_sms_adapter.ex) | `Application.put_env(:converger, :adapters, [YourAdapter])` restored `on_exit` (`async: false`); the type is accepted, its schema validated, its channels delivered to and health-checked |

Notes:

- Tests run with the inline pipeline (`config/test.exs`), so creating an activity delivers it synchronously. Stub HTTP for any outbound channel in the test, or the delivery fails fast.
- DNS is deterministic in tests (`Converger.TestDnsResolver`, configured as the `:webhook` resolver); use hosts it knows or IP literals when exercising `UrlGuard`.
- `ConnCase.signed_post/5` signs a request with the generic scheme; for a native scheme, build the header yourself as `inbound_batch_test.exs` does for Meta.
- Run `mix precommit` before opening the pull request.

## 10. Documentation and ADR

Every pull request updates the docs it affects ([ADR-0025](../adr/0025-docusaurus-site-and-docs-with-every-change.md)); the "Docs required" CI check fails when `lib/` changes without a change under `docs/`. For a new adapter:

- add `docs/channels/<adapter>.md` with config keys, outbound mapping, inbound payloads (real JSON), signature scheme, receipts and error classification;
- add a row to the capability matrix in [Channels and adapters](overview.md#capability-matrix) and a link to the new page;
- write an ADR in `docs/adr/` if the adapter introduces a decision (a new signature scheme, a new idempotency strategy, a change to the behaviour) and add it to the ADR index;
- update `CHANGELOG.md`.

## Checklist

- [ ] the module `use`s `Converger.Channels.Adapter, type: "<type>"`
- [ ] registered: `config :converger, :adapters, [...]` (or `@builtin_adapters` for a core adapter)
- [ ] `capabilities/0` declares `:external_delivery`, `:receipts`, `:typing`, `:lifecycle_events`, `:provider_ack` as they apply
- [ ] `config_schema/0` lists every config field; secrets `secret: true`, signing keys `required: :with_signature`
- [ ] `deliver_activity/2` returns the provider id as `provider_message_id` (if receipts are supported)
- [ ] secret config keys named so they are redacted in audit logs
- [ ] user-supplied URLs go through `UrlGuard`
- [ ] every message of a batch parsed, each with a stable `idempotency_key`
- [ ] `capabilities/0` lists only the activity types `deliver_activity/2` renders
- [ ] failures returned as `DeliveryError`, or classified by `normalize_error/1`
- [ ] `health_probe/1` if the provider has a cheap account check
- [ ] unit, delivery and controller tests
- [ ] docs page, capability matrix row, ADR if needed
