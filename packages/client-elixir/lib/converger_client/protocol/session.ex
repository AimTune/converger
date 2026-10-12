defmodule ConvergerClient.Protocol.Session do
  @moduledoc """
  Transport-independent Protocol v1 resume state machine.

  The rules are in `packages/conformance/README.md`; the scenarios in
  `packages/conformance/protocol.json` check them. `on_frame/2` returns the
  new session and a step: frames to deliver to the application, frames to
  send now and frames to send after a delay.
  """

  @protocol "converger/1"

  defstruct watermark: 0, conversation_id: nil, sync_pending: false, own: MapSet.new()

  @type frame :: map()
  @type step :: %{deliver: [frame()], send: [frame()], schedule: [{non_neg_integer(), frame()}]}
  @type t :: %__MODULE__{
          watermark: non_neg_integer(),
          conversation_id: String.t() | nil,
          sync_pending: boolean(),
          own: MapSet.t(integer())
        }

  @doc "The protocol identifier sent in `hello`."
  def protocol, do: @protocol

  @doc "A session resuming from `watermark` (and `conversation_id`, when known)."
  @spec new(non_neg_integer(), String.t() | nil) :: t()
  def new(watermark \\ 0, conversation_id \\ nil),
    do: %__MODULE__{watermark: watermark, conversation_id: conversation_id}

  @doc "The first frame of a connection."
  @spec hello(t()) :: frame()
  def hello(%__MODULE__{} = s) do
    frame = %{"type" => "hello", "protocol" => @protocol, "watermark" => s.watermark}
    if s.conversation_id, do: Map.put(frame, "conversationId", s.conversation_id), else: frame
  end

  @doc "A `sync` from the current watermark."
  @spec sync_frame(t()) :: frame()
  def sync_frame(%__MODULE__{watermark: w}), do: %{"type" => "sync", "watermark" => w}

  @doc "Applies one received frame."
  @spec on_frame(t(), frame()) :: {t(), step()}
  def on_frame(%__MODULE__{} = s, frame) do
    step = %{deliver: [], send: [], schedule: []}
    seq = if is_integer(frame["seq"]), do: frame["seq"]
    handle(frame["type"], seq, frame, s, step)
  end

  defp handle("welcome", _seq, frame, s, step) do
    new_id = get_in(frame, ["data", "conversationId"])

    s =
      if s.conversation_id && new_id != s.conversation_id,
        do: %{s | watermark: 0, own: MapSet.new()},
        else: s

    s = if new_id, do: %{s | conversation_id: new_id}, else: s
    {%{s | sync_pending: false}, deliver(step, frame)}
  end

  defp handle("ack", seq, _frame, s, step) when is_integer(seq) do
    cond do
      seq == s.watermark + 1 -> {advance(s, seq), step}
      seq > s.watermark + 1 -> {%{s | own: MapSet.put(s.own, seq)}, step}
      true -> {s, step}
    end
  end

  defp handle("ack", _seq, _frame, s, step), do: {s, step}

  defp handle(_type, seq, frame, s, step) when is_integer(seq) do
    cond do
      seq <= s.watermark or MapSet.member?(s.own, seq) -> {s, step}
      seq == s.watermark + 1 -> {%{advance(s, seq) | sync_pending: false}, deliver(step, frame)}
      true -> sync(s, step)
    end
  end

  defp handle("heartbeat", _seq, frame, s, step) do
    head = frame["headSeq"]
    if is_integer(head) and head > s.watermark, do: sync(s, step), else: {s, step}
  end

  defp handle("replayTruncated", _seq, frame, s, step) do
    step = step |> deliver(frame) |> send_frame(sync_frame(s))
    {%{s | sync_pending: true}, step}
  end

  defp handle("error", _seq, frame, s, step) do
    data = frame["data"] || %{}
    step = deliver(step, frame)

    cond do
      data["code"] == "replay_unavailable" ->
        after_ms = if is_integer(data["retryAfterMs"]), do: data["retryAfterMs"], else: 1000

        {%{s | sync_pending: true},
         %{step | schedule: step.schedule ++ [{after_ms, sync_frame(s)}]}}

      data["code"] == "invalid_watermark" and not Map.has_key?(data, "clientId") ->
        s = %{s | watermark: 0, own: MapSet.new(), sync_pending: true}
        {s, send_frame(step, sync_frame(s))}

      true ->
        {s, step}
    end
  end

  defp handle("tokenRefreshed", _seq, _frame, s, step), do: {s, step}
  defp handle(_type, _seq, frame, s, step), do: {s, deliver(step, frame)}

  defp advance(s, seq) do
    s = %{s | watermark: seq}
    s = absorb(s)
    %{s | own: MapSet.filter(s.own, &(&1 > s.watermark))}
  end

  defp absorb(s) do
    next = s.watermark + 1

    if MapSet.member?(s.own, next),
      do: absorb(%{s | watermark: next, own: MapSet.delete(s.own, next)}),
      else: s
  end

  defp sync(%{sync_pending: true} = s, step), do: {s, step}
  defp sync(s, step), do: {%{s | sync_pending: true}, send_frame(step, sync_frame(s))}

  defp deliver(step, frame), do: %{step | deliver: step.deliver ++ [frame]}
  defp send_frame(step, frame), do: %{step | send: step.send ++ [frame]}
end
