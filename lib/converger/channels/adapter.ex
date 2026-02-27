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
end
