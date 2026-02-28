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

  @callback parse_inbound(channel, params :: map()) ::
              {:ok, map()} | {:error, term()}

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

  @optional_callbacks [parse_status_update: 2]

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

  def parse_inbound(%{type: type} = channel, params) do
    case adapter_for(type) do
      {:ok, mod} -> mod.parse_inbound(channel, params)
      {:error, _} = err -> err
    end
  end

  def parse_status_update(%{type: type} = channel, params) do
    case adapter_for(type) do
      {:ok, mod} ->
        if function_exported?(mod, :parse_status_update, 2) do
          mod.parse_status_update(channel, params)
        else
          :ignore
        end

      {:error, _} = err ->
        err
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
