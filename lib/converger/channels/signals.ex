defmodule Converger.Channels.Signals do
  @moduledoc """
  Forwards transient conversation signals (typing indicators and read
  receipts from WebSocket participants) to the conversation's external
  channels, through the optional adapter callbacks
  `c:Converger.Channels.Adapter.send_typing/2` and
  `c:Converger.Channels.Adapter.send_read_receipt/2`.

  The target channels are the ones an activity from the same sender would be
  delivered to (`Converger.Pipeline.resolve_delivery_channels/1`), limited to
  channels whose adapter implements the callback and that have a participant
  in the conversation (the recipient). Channels that do not support a signal
  (Slack, generic webhooks, ...) are skipped.

  Signals are best effort: they are not persisted, not retried, and a
  failure is only logged. `forward_typing/3` and `forward_read/3` run in a
  task under `Converger.TaskSupervisor` so the caller (a channel process) is
  never blocked by a provider call; set
  `config :converger, :channel_signals_async, false` to run them inline.
  """

  require Logger

  alias Converger.{Activities, Participants, Pipeline}
  alias Converger.Channels.Adapter

  @doc "Forward a typing indicator from `sender` in a conversation."
  def forward_typing(conversation_id, sender, is_typing) when is_boolean(is_typing) do
    run(fn ->
      forward(conversation_id, sender, :send_typing, nil, %{is_typing: is_typing})
    end)
  end

  @doc "Forward that `sender` has read every activity up to `up_to_seq`."
  def forward_read(conversation_id, sender, up_to_seq) when is_integer(up_to_seq) do
    run(fn ->
      forward(conversation_id, sender, :send_read_receipt, up_to_seq, %{up_to_seq: up_to_seq})
    end)
  end

  @doc false
  # Synchronous core, returns the per-channel results (used by tests).
  def forward(conversation_id, sender, callback, max_seq, extra) do
    %{conversation_id: conversation_id, sender: sender, type: "signal"}
    |> Pipeline.resolve_delivery_channels()
    |> Enum.filter(&Adapter.supports?(&1.type, callback, 2))
    |> Enum.flat_map(fn channel ->
      case Participants.recipient_for(%{conversation_id: conversation_id}, channel.id) do
        nil ->
          []

        recipient ->
          signal =
            Map.merge(extra, %{
              conversation_id: conversation_id,
              recipient: recipient,
              provider_message_id:
                Activities.latest_idempotency_key(conversation_id, recipient, max_seq)
            })

          [{channel.id, send_signal(channel, callback, signal)}]
      end
    end)
  end

  defp send_signal(channel, callback, signal) do
    result = apply(Adapter, callback, [channel, signal])

    with {:error, reason} <- result do
      Logger.warning("Forwarding a conversation signal failed",
        channel_id: channel.id,
        signal: callback,
        reason: inspect(reason)
      )
    end

    result
  rescue
    error ->
      Logger.warning("Forwarding a conversation signal crashed",
        channel_id: channel.id,
        signal: callback,
        reason: Exception.message(error)
      )

      {:error, error}
  end

  defp run(fun) do
    if Application.get_env(:converger, :channel_signals_async, true) do
      {:ok, _pid} = Task.Supervisor.start_child(Converger.TaskSupervisor, fun)
      :ok
    else
      fun.()
      :ok
    end
  end
end
