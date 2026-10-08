defmodule Converger.Channels.Adapter do
  @moduledoc """
  Behaviour for channel adapters. Each channel type implements this behaviour
  to define how activities are delivered, how inbound payloads are parsed,
  and what configuration is required.
  """

  @type channel :: Converger.Channels.Channel.t()
  @type activity :: Converger.Activities.Activity.t()
  @type config :: map()

  @callback deliver_activity(channel, activity) ::
              :ok | {:ok, map()} | {:error, term()}

  @callback validate_config(config) ::
              :ok | {:error, String.t()}

  @doc """
  Parse an inbound webhook payload into the messages it carries.

  Providers batch several messages into one webhook call, so this returns a
  **list**. The list may be empty, e.g. for a well-formed payload that only
  carries status updates or events Converger does not handle. Each parsed
  message is a map with:

    - "type", "text", "attachments", "metadata" - activity client fields
    - "sender" (required) - the sender identifier stored on the activity
    - "idempotency_key" (optional) - a stable provider message id (e.g. a
      WhatsApp `wamid`); a re-delivered webhook carrying the same id never
      creates a second activity

  `parse_inbound/2` below also accepts an adapter returning a single map.
  """
  @callback parse_inbound(channel, params :: map()) ::
              {:ok, [map()]} | {:ok, map()} | {:error, term()}

  @doc """
  Parse a provider status update (delivery receipt / read receipt).
  Returns {:ok, list_of_status_updates} or :ignore or {:error, reason}.

  Each status update map contains:
    - "provider_message_id" (required) - the provider's message ID
    - "status" (required) - one of "sent", "delivered", "read", "failed"
    - "timestamp" (optional) - ISO8601 or Unix timestamp from provider
    - "recipient_id" (optional) - provider recipient identifier
    - "error" (optional) - error details for failed status
  """
  @callback parse_status_update(channel, params :: map()) ::
              {:ok, [map()]} | :ignore | {:error, term()}

  @doc """
  Verify the signature of an inbound webhook request using the provider's
  native scheme (e.g. WhatsApp Meta's `X-Hub-Signature-256`).

  Receives the channel, the request headers (lowercase names) and the raw
  request body. Must return one of the results documented in
  `Converger.Channels.InboundSignature`: `:ok`, `:legacy`, `:missing` or
  `{:error, reason}`. Adapters that do not implement it fall back to the
  generic `x-converger-signature` scheme.
  """
  @callback verify_inbound_signature(
              channel,
              headers :: [{String.t(), String.t()}],
              raw_body :: binary() | nil
            ) :: :ok | :legacy | :missing | {:error, term()}

  @doc """
  Adapter-specific retry policy defaults (e.g. `%{timeout_ms: 10_000}`), merged
  over the global defaults and under the channel's own `retry_policy`. See
  `Converger.Pipeline.RetryPolicy`.
  """
  @callback retry_policy() :: map()

  @optional_callbacks [parse_status_update: 2, verify_inbound_signature: 3, retry_policy: 0]

  @callback supported_modes() :: [String.t()]

  @doc "Resolve adapter module from channel type string."
  def adapter_for(type) do
    case type do
      "echo" -> {:ok, Converger.Channels.Adapters.Echo}
      "webhook" -> {:ok, Converger.Channels.Adapters.Webhook}
      "websocket" -> {:ok, Converger.Channels.Adapters.WebSocket}
      "whatsapp_meta" -> {:ok, Converger.Channels.Adapters.WhatsAppMeta}
      "whatsapp_infobip" -> {:ok, Converger.Channels.Adapters.WhatsAppInfobip}
      _ -> {:error, "unknown channel type: #{type}"}
    end
  end

  def validate_config(nil, _config), do: :ok

  def validate_config(type, config) do
    case adapter_for(type) do
      {:ok, mod} -> mod.validate_config(config)
      {:error, _} = err -> err
    end
  end

  def deliver_activity(%{type: type} = channel, activity) do
    case adapter_for(type) do
      {:ok, mod} -> mod.deliver_activity(channel, activity)
      {:error, _} = err -> err
    end
  end

  @doc """
  Parse an inbound payload with the channel's adapter. Always returns
  `{:ok, list_of_messages}` or `{:error, reason}`.
  """
  def parse_inbound(%{type: type} = channel, params) do
    case adapter_for(type) do
      {:ok, mod} ->
        case mod.parse_inbound(channel, params) do
          {:ok, messages} when is_list(messages) -> {:ok, messages}
          {:ok, %{} = message} -> {:ok, [message]}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  def parse_status_update(%{type: type} = channel, params) do
    case adapter_for(type) do
      {:ok, mod} ->
        Code.ensure_loaded(mod)

        if function_exported?(mod, :parse_status_update, 2) do
          # apply/3 because the callback is optional and not every adapter defines it
          apply(mod, :parse_status_update, [channel, params])
        else
          :ignore
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Verify an inbound webhook signature with the channel's adapter, falling
  back to the generic `x-converger-signature` scheme.
  """
  def verify_inbound_signature(%{type: type} = channel, headers, raw_body) do
    case adapter_for(type) do
      {:ok, mod} ->
        Code.ensure_loaded(mod)

        if function_exported?(mod, :verify_inbound_signature, 3) do
          # apply/3 because the callback is optional and not every adapter defines it
          apply(mod, :verify_inbound_signature, [channel, headers, raw_body])
        else
          Converger.Channels.InboundSignature.verify(channel, headers, raw_body)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Retry policy defaults of the adapter for `type` (empty when it defines none)."
  def retry_policy(type) do
    with {:ok, mod} <- adapter_for(type),
         true <- Code.ensure_loaded?(mod) and function_exported?(mod, :retry_policy, 0) do
      mod.retry_policy()
    else
      _ -> %{}
    end
  end

  def supported_modes(nil), do: ~w(inbound outbound duplex)

  def supported_modes(type) do
    case adapter_for(type) do
      {:ok, mod} -> mod.supported_modes()
      {:error, _} -> []
    end
  end
end
