---
title: Writing an adapter
description: Step-by-step guide to adding a new channel adapter to Converger, from the behaviour module to registration, secrets, inbound parsing, error classification, tests and docs.
sidebar_position: 5
---

This guide walks through adding a new channel type. The running example is a fictional SMS provider, **Acme SMS**, with type string `acme_sms`. It sends text messages over a JSON HTTP API, posts batched inbound messages and delivery reports to a webhook, and signs its webhooks with an HMAC header.

Before you start, read [Channels and adapters](overview.md) for the behaviour, the inbound endpoint and the signature policy. The smallest complete adapter in the code base is [echo](echo.md); the most complete ones are [`whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex) and [`webhook.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex).

:::info
Adding an adapter currently means touching several files outside the adapter module (the steps below list all of them). Adapter behaviour v2, with `capabilities/0`, `config_schema/0`, a config-driven adapter registry and generated admin forms, is Planned ([#36](https://github.com/AimTune/converger/issues/36)). Until it lands, follow this checklist.
:::

## 1. Implement the behaviour

Create `lib/converger/channels/adapters/acme_sms.ex`. One module per file (nested modules are not allowed in this code base).

```elixir
defmodule Converger.Channels.Adapters.AcmeSms do
  @moduledoc """
  Acme SMS channel.

  ## Config

    * `base_url` (required) - Acme API base URL, e.g. `https://api.acme-sms.example`
    * `api_key` (required) - sent as `Authorization: Bearer <api_key>`
    * `sender` (required) - the sending number
    * `webhook_secret` - verifies `X-Acme-Signature` on inbound webhooks
  """

  @behaviour Converger.Channels.Adapter

  alias Converger.Channels.{DeliveryError, InboundSignature, UrlGuard}
  alias Converger.Participants
  alias Converger.Pipeline.RetryPolicy

  @required ~w(base_url api_key sender)

  @impl true
  def supported_modes, do: ~w(inbound outbound duplex)

  @impl true
  def validate_config(config) do
    case Enum.reject(@required, &(is_binary(config[&1]) and config[&1] != "")) do
      [] ->
        case UrlGuard.check(config["base_url"]) do
          :ok -> :ok
          {:error, message} -> {:error, "acme_sms config 'base_url' is not allowed: #{message}"}
        end

      missing ->
        {:error, "acme_sms config missing: #{Enum.join(missing, ", ")}"}
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
          {:ok, %{acme_message_id: body["id"]}}

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
| `supported_modes/0` | yes | Subset of `inbound`, `outbound`, `duplex`. The channel changeset enforces it. |
| `validate_config/1` | yes | Return `{:error, "<type> config ..."}` messages; they are shown as `config` errors in the admin UI. Runs on every create and update. |
| `deliver_activity/2` | yes | Called only by the pipeline. Return `:ok`, `{:ok, map}` or `{:error, reason}`, preferably `{:error, %DeliveryError{}}`. |
| `parse_inbound/2` | yes | Return a list, even for one message. An empty list for payloads with only receipts. `{:error, message}` when the body is not your provider's format at all (answered with `400`). Adapters without inbound support return `{:error, "..."}` unconditionally. |
| `parse_status_update/2` | no | `{:ok, [update]}` or `:ignore`. |
| `verify_inbound_signature/3` | no | Implement when the provider signs webhooks natively. Without it, the generic `x-converger-signature` scheme keyed with the channel `secret` applies. |
| `retry_policy/0` | no | Adapter defaults (`max_attempts`, `backoff`, `base_ms`, `max_ms`, `timeout_ms`) between the global config and the channel's own `retry_policy`. |
| `send_typing/2` | no | Show (or clear) a typing indicator to the channel's participant when a WebSocket participant types. Return `:ok` or `{:error, reason}`. |
| `send_read_receipt/2` | no | Tell the provider the participant's messages were read when a WebSocket participant sends `read`. Return `:ok` or `{:error, reason}`. |

### Typing and read receipts (optional)

`Converger.Channels.Signals` calls `send_typing/2` and `send_read_receipt/2` for the channels an activity from the same sender would be delivered to, but only when your adapter implements the callback and the conversation has a participant on the channel. Both receive the channel and a signal map:

| Key | Value |
| --- | --- |
| `:conversation_id` | the conversation |
| `:recipient` | the participant's `external_id` on your channel (the number to address) |
| `:provider_message_id` | the `idempotency_key` of the participant's latest inbound activity (for read receipts: the latest one up to `:up_to_seq`), or `nil` |
| `:is_typing` | typing only: `true` or `false` |
| `:up_to_seq` | read receipts only: everything up to this `seq` was read |

Signals are best effort: they run in a task under `Converger.TaskSupervisor`, are never retried, and an `{:error, reason}` or a raise is only logged. Do not retry inside the callback (pass `retry: false` to Req). Return `:ok` without calling the provider when there is nothing to do, for example `is_typing: false` on a provider that clears indicators on its own, or a `nil` `:provider_message_id`. Typing is forwarded at most every 20 seconds per WebSocket connection. See [ADR-0027](../adr/0027-transient-conversation-signals.md) and the WhatsApp Cloud API implementation in `whatsapp_meta.ex`.

## 2. Register the type

Today the type string is listed in several places. For `acme_sms`:

| File | Change | Why |
| --- | --- | --- |
| [`lib/converger/channels/channel.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/channel.ex) | add `acme_sms` to `@channel_types` | `validate_inclusion(:type, ...)` and the admin type dropdown (`Channel.channel_types/0`) |
| [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex) | add `"acme_sms" -> {:ok, Converger.Channels.Adapters.AcmeSms}` to `adapter_for/1` | dispatch of every callback |
| [`lib/converger/pipeline.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex) | add to `@delivery_types` (outbound adapters only) | without it no delivery is ever created for the channel |
| [`lib/converger/channels/health.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/health.ex) | add to the type list in `check_all_channels/1` | [health checks](overview.md#channel-health) |
| [`lib/converger_web/live/admin/dashboard_live.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/live/admin/dashboard_live.ex) | add to the type list of the health query | dashboard health counts |
| [`lib/converger_web/live/admin/channel_live.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/live/admin/channel_live.ex) | add `config_fields("acme_sms")` and optionally `config_summary/1` | config form; use field type `:password` for secrets |
| [`lib/converger_web/controllers/inbound_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex) | add to `@provider_ack_types` if the provider retries every non-`200` response | the provider gets `200` once the request was handled, even when messages were rejected permanently |
| [`lib/converger/deliveries.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/deliveries.ex) | add your response key (`acme_message_id`) to `mark_sent/2` | only `whatsapp_message_id` and `infobip_message_id` are copied to `provider_message_id` today; without it receipts cannot find the delivery |

If the provider uses a `GET` handshake to verify the webhook URL (like Meta's `hub.challenge`), add a clause to `InboundController.verify/2`; other types answer `200 ok`.

Channel types are plain strings, never atoms created from input: `adapter_for/1` matches literal strings, so unknown types fail with `{:error, "unknown channel type: ..."}`.

## 3. Config validation

- Validate required keys and their types in `validate_config/1`. Values arrive as strings from the admin form; accept strings for numbers where it makes sense (see `to_positive_integer/1` in the webhook adapter).
- Cross-field rules that depend on channel fields rather than config (for example "`app_secret` is required when `require_signature` is true" for Meta) live in the channel changeset (`validate_signature_config/1` in `channel.ex`).
- Do not perform network calls in validation except through `UrlGuard.check/1`, which accepts unresolvable hosts and leaves the final check to request time.

## 4. Secrets

- The whole `config` map is stored with `Converger.Encrypted.Map` (Cloak, AES key from `CLOAK_KEY`), and the channel `secret` with `Converger.Encrypted.Binary`. Nothing extra is needed to encrypt a new config key at rest. See [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md).
- **Redaction depends on the key name.** `Converger.Secrets.redact/1` (audit logs) and the admin config view mask keys named `access_token`, `api_key`, `secret`, `token`, `password`, `password_hash`, `verify_token`, `app_secret`, `authorization`, `x-api-key`, `x-channel-token`, and any key ending in `_secret`, `_token` or `_hash`. Name secret config keys so they match (`api_key`, `webhook_secret`, `refresh_token`), never `key` or `credentials`.
- Never log `channel.config` or request headers unredacted.

## 5. Inbound parsing and idempotency

- **Return every message of a batch.** Returning only the first one was the bug fixed in [#15](https://github.com/AimTune/converger/issues/15); see [ADR-0015](../adr/0015-per-message-idempotent-inbound-batches.md).
- **Set `idempotency_key`** to a stable provider message id. The controller checks it across all conversations of the channel before creating an activity, so a re-delivered webhook produces duplicates, not new activities. Use an id that is unique per channel; prefixing it (`"acme:" <> id`) is optional but makes the origin obvious. Never derive it from a timestamp or from the body hash of a whole batch.
- **Set `participant.external_id`** to the sender's address (phone number, chat id) so messages from the same party share their active conversation and replies can find the recipient through `Participants.recipient_for/2` ([ADR-0016](../adr/0016-participant-based-conversation-resolution.md)).
- **Keep unknown message types** as activities (empty text, `metadata` with the provider type) rather than dropping them.
- Map media to attachment stubs (`contentType`, `provider`, `providerMediaId`); do not download media in the request.
- Only client fields of the parsed message (`type`, `text`, `attachments`, `metadata`) end up on the activity; `sender` and `idempotency_key` are passed by the controller as server-controlled attributes.
- Receipts: normalize `status` to one of `sent`, `delivered`, `read`, `failed`. Any other value is silently ignored by `Deliveries.advance_status/2` (it has no rank), so map unknown provider states explicitly, as both WhatsApp adapters map them to `sent`.

## 6. Delivery errors

Return `{:error, %Converger.Channels.DeliveryError{}}` so the pipeline can tell retryable from permanent failures ([ADR-0019](../adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md)):

- non-`2xx` responses: `DeliveryError.from_http(status, headers, body, "Acme API")` (retryable for `408`, `425`, `429`, `5xx`; permanent otherwise; honours `Retry-After`);
- transport failures: `DeliveryError.from_transport(reason, "Acme API")` (retryable);
- configuration or input errors no retry can fix (no recipient, invalid method, blocked target): `DeliveryError.permanent(message)`.

A plain `{:error, term}` is treated as retryable, which wastes attempts on permanent failures.

## 7. HTTP and user-supplied URLs

- Use [`Converger.HTTP`](https://github.com/AimTune/converger/blob/main/lib/converger/http.ex) (`request/1`, `post/2`) for outbound calls. It wraps Req and attaches `OpentelemetryReq`, so each call becomes a client span under the delivery job's span. (The existing webhook and WhatsApp adapters still call `Req` directly.) Do not add other HTTP clients.
- Set `receive_timeout` from `RetryPolicy.for_channel(channel).timeout_ms`.
- Merge test options from the application env (`Application.get_env(:converger, :acme_sms_req_options, [])`), the same pattern as `:webhook_req_options` and `:whatsapp_req_options`, so tests can inject `plug: {Req.Test, ...}`.
- Any URL a tenant can configure (a base URL, a callback URL) must pass [`Converger.Channels.UrlGuard`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/url_guard.ex): `check/1` at config validation and `resolve/1` before every request. `resolve/1` returns the checked address; to defeat DNS rebinding, pin the connection to it the way the webhook adapter does (`target_url/1` and `connect_options/2` with `hostname:`), and disable redirects (`redirect: false`). The guard is configured with `config :converger, :webhook, allow_private_targets: ..., allowed_targets: [...]` (`WEBHOOK_ALLOW_PRIVATE_TARGETS`, `WEBHOOK_ALLOWED_TARGETS` in releases). See [ADR-0014](../adr/0014-webhook-ssrf-guard-and-outbound-signing.md) and [Outbound webhooks](../webhooks.md#ssrf-protection).

The example above checks `base_url` but, for brevity, does not pin the connection.

## 8. Signatures

- If the provider signs webhooks, implement `verify_inbound_signature/3` and return `:ok`, `{:error, reason}` for a present but invalid signature, and `:missing` when there is no header **or** no secret configured. The controller then applies the channel's `require_signature` policy ([ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md)).
- Verify over `raw_body` (the exact bytes; `CacheBodyReader` caches them for `/api/v1/channels/*`), never over re-encoded params. Compare with `Plug.Crypto.secure_compare/2`.
- If the provider cannot sign at all, do not implement the callback: senders then use the generic `x-converger-signature` header with the channel `secret`, or the channel must be created with `require_signature: false`.
- If the provider's scheme needs a secret, require it in the channel changeset when `require_signature` is `true`, as `whatsapp_meta` does for `app_secret`.

## 9. Tests

Mirror the existing adapter tests:

| Test file to add | Pattern to copy | What to cover |
| --- | --- | --- |
| `test/converger/channels/adapters/acme_sms_test.exs` | [`whatsapp_meta_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/whatsapp_meta_test.exs), [`whatsapp_infobip_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/whatsapp_infobip_test.exs) | `use ExUnit.Case, async: true` with a plain `%{type: "acme_sms", config: %{}}` map; real provider payload fixtures; every message of a batch parsed in order with its `idempotency_key`; receipts and status normalization; `:ignore` and `{:error, _}` cases |
| `test/converger/channels/adapters/acme_sms_delivery_test.exs` | [`webhook_delivery_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/webhook_delivery_test.exs) | `use Converger.DataCase, async: false` (it mutates app env); `Application.put_env(:converger, :acme_sms_req_options, plug: {Req.Test, __MODULE__})` and restore it `on_exit`; `Req.Test.stub/2` to assert the request and return `200`, `400`, `429` with `Retry-After`, `503`; assert `DeliveryError` classification |
| controller tests | [`inbound_batch_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_batch_test.exs), [`inbound_signature_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_signature_test.exs) | `use ConvergerWeb.ConnCase`; create the channel with `Channels.create_channel/1`; a batch of 3 creates 3 activities; re-delivery creates none (`"duplicates" => 3`); a partially processed batch completes; valid, invalid, tampered and missing signatures |
| retry policy | [`channel_retry_policy_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/channel_retry_policy_test.exs) | end-to-end with `Oban.Testing`: a permanent error is dead-lettered after one attempt |

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

- [ ] `lib/converger/channels/adapters/<type>.ex` implements the behaviour
- [ ] type registered in `channel.ex`, `adapter.ex`, `pipeline.ex`, `health.ex`, `dashboard_live.ex`, `channel_live.ex`
- [ ] provider message id key handled in `Deliveries.mark_sent/2` (if receipts are supported)
- [ ] `@provider_ack_types` updated (if the provider retries non-`200`)
- [ ] secret config keys named so they are redacted
- [ ] user-supplied URLs go through `UrlGuard`
- [ ] every message of a batch parsed, each with a stable `idempotency_key`
- [ ] failures returned as `DeliveryError`
- [ ] unit, delivery and controller tests
- [ ] docs page, capability matrix row, ADR if needed
