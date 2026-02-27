defmodule Converger.Channels.Adapters.Echo do
  @behaviour Converger.Channels.Adapter

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def deliver_activity(_channel, activity) do
    Converger.Activities.create_activity(%{
      "tenant_id" => activity.tenant_id,
      "conversation_id" => activity.conversation_id,
      "text" => activity.text,
      "sender" => "bot"
    })

    :ok
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "echo channel does not support inbound webhooks"}
  end
end
