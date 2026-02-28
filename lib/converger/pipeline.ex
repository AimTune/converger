defmodule Converger.Pipeline do
  @moduledoc """
  Parametric activity processing pipeline.

  After an activity is persisted, it flows through the pipeline for:
  1. Broadcasting to WebSocket clients (PubSub)
  2. Delivering to external channels (webhook, WhatsApp, etc.)

  The pipeline backend is configurable:

      config :converger, :pipeline,
        backend: Converger.Pipeline.Oban   # default - persistent job queue
        # backend: Converger.Pipeline.GenStage  # in-memory with backpressure
        # backend: Converger.Pipeline.Inline    # synchronous (testing/dev)

  All backends receive the same activity struct and handle broadcast + delivery.
  """

  @type activity :: Converger.Activities.Activity.t()

  @doc """
  Process an activity through the pipeline after persistence.
  Handles both PubSub broadcast and external channel delivery.
  """
  @callback process(activity) :: :ok | {:error, term()}

  @doc """
  Called on application start. Backends that need supervision (GenStage)
  return child specs. Others return an empty list.
  """
  @callback child_specs() :: [Supervisor.child_spec()]

  @doc "Dispatch activity to the configured pipeline backend."
  def process(activity) do
    backend().process(activity)
  end

  @doc "Get child specs for the configured backend's supervision tree."
  def child_specs do
    backend().child_specs()
  end

  @doc "Broadcast activity to WebSocket clients via PubSub."
  def broadcast(activity) do
    ConvergerWeb.Endpoint.broadcast!(
      "conversation:#{activity.conversation_id}",
      "new_activity",
      %{
        id: activity.id,
        text: activity.text,
        sender: activity.sender,
        inserted_at: activity.inserted_at
      }
    )

    :ok
  end

  @external_delivery_types ~w(webhook whatsapp_meta whatsapp_infobip)

  @doc """
  Resolve all channels that should receive a delivery for this activity.
  Returns a list of Channel structs (may be empty).
  Includes: primary channel (if external) + routing rule targets (if external and active).
  """
  def resolve_delivery_channels(activity) do
    conversation = Converger.Conversations.get_conversation!(activity.conversation_id)
    primary_channel = Converger.Channels.get_channel!(conversation.channel_id)

    primary =
      if primary_channel.type in @external_delivery_types and
           primary_channel.mode in ["outbound", "duplex"],
         do: [primary_channel],
         else: []

    target_ids =
      Converger.RoutingRules.resolve_target_channels(
        primary_channel.id,
        conversation.tenant_id
      )

    additional_ids = target_ids -- [primary_channel.id]

    additional =
      additional_ids
      |> Enum.map(fn id ->
        try do
          Converger.Channels.get_channel!(id)
        rescue
          Ecto.NoResultsError -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.type in @external_delivery_types))
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.filter(&(&1.mode in ["outbound", "duplex"]))

    (primary ++ additional) |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Execute the actual delivery via middleware + adapter + delivery tracking.

  The middleware chain (from `channel.transformations`) runs before the adapter.
  If any middleware halts, the delivery is marked as failed and skipped.
  """
  def deliver(activity, channel) do
    alias Converger.{Deliveries, Channels.Adapter}
    alias Converger.Pipeline.Middleware

    delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)

    case Middleware.run(activity, channel) do
      {:halt, reason} ->
        Deliveries.mark_attempt_failed(delivery, "halted: #{reason}")
        {:error, {:halted, reason}}

      {:ok, transformed_activity} ->
        case Adapter.deliver_activity(channel, transformed_activity) do
          :ok ->
            Deliveries.mark_sent(delivery)
            :ok

          {:ok, response_meta} ->
            Deliveries.mark_sent(delivery, response_meta)
            :ok

          {:error, reason} ->
            Deliveries.mark_attempt_failed(delivery, inspect(reason))
            {:error, reason}
        end
    end
  end

  defp backend do
    config = Application.get_env(:converger, :pipeline, [])
    Keyword.get(config, :backend, Converger.Pipeline.Oban)
  end
end
