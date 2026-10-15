defmodule ConvergerWeb.Protocol.InFlight do
  @moduledoc """
  The per-connection limit on unacked sends (`limits.maxInFlight`,
  docs/protocol/v1.md, section 7) on the Phoenix binding.

  A connection's sends are processed one at a time, in order, by its channel
  process, and each is acked as soon as it is committed. So the sends a
  client has in flight are the one being processed plus the ones still
  queued in the process mailbox. When a send is processed and more than
  `max - 1` further sends are queued behind it, the oldest `max` of them
  (counting this one) are accepted and the newest rest are refused with
  `too_many_in_flight`, which is retryable with the same clientId. Refusing
  the newest keeps the accepted sends in the order the client sent them.

  The window is counted once (one mailbox scan) and then consumed send by
  send; the mailbox is only scanned when its length reaches `max`, so a
  client that waits for its acks never pays for it.
  """

  defstruct accept: 0, reject: 0

  @type t :: %__MODULE__{accept: non_neg_integer(), reject: non_neg_integer()}

  @doc "A fresh window."
  def new, do: %__MODULE__{}

  @doc "The configured limit (`config :converger, :websocket, max_in_flight: 32`)."
  def limit do
    :converger |> Application.get_env(:websocket, []) |> Keyword.get(:max_in_flight, 32)
  end

  @doc """
  Decides whether the send being processed is accepted. `send?` tells which
  queued payloads of the `"frame"` event are sends. Must run in the channel
  process.
  """
  def admit(%__MODULE__{accept: accept} = window, _max, _send?) when accept > 0,
    do: {:accept, %{window | accept: accept - 1}}

  def admit(%__MODULE__{reject: reject} = window, _max, _send?) when reject > 0,
    do: {:reject, %{window | reject: reject - 1}}

  def admit(%__MODULE__{} = window, max, send?) do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)

    queued = if length < max, do: 0, else: queued_sends(send?)
    accept = min(queued, max - 1)

    {:accept, %{window | accept: accept, reject: queued - accept}}
  end

  defp queued_sends(send?) do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.count(messages, fn
      %Phoenix.Socket.Message{event: "frame", payload: payload} -> send?.(payload)
      _ -> false
    end)
  end
end
