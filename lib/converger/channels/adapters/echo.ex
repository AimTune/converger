defmodule Converger.Channels.Adapters.Echo do
  @moduledoc """
  Replies to every activity with a copy sent by `"bot"`.

  Delivered through the pipeline like any other outbound adapter. Replies are
  tagged with `metadata["echo_of"]` and are not echoed again (no loop), and use
  an idempotency key derived from the original activity, so a retried delivery
  never produces a second reply.
  """

  @behaviour Converger.Channels.Adapter

  @impl true
  def supported_modes, do: ~w(outbound)

  # Echoes chat messages only; reactions, edits and deletes reach it
  # downgraded to text (or skipped), see Converger.Activities.Downgrade.
  @impl true
  def capabilities, do: [:outbound, activity_types: ~w(message)]

  @impl true
  def validate_config(_config), do: :ok

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
      # Closed since the original was accepted: nothing to reply into.
      {:error, :conversation_closed} -> :ok
      {:error, reason} -> {:error, {:echo_failed, reason}}
    end
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "echo channel does not support inbound webhooks"}
  end
end
