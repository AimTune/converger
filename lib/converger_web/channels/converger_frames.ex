defmodule ConvergerWeb.ConvergerFrames do
  @moduledoc """
  Builds the transient Converger Protocol v1 frames pushed by
  `ConvergerWeb.ConvergerChannel`: `deliveryStatus`, `typing` and `presence`
  (docs/protocol/v1.md, section 8; schemas in `priv/protocol/v1/frames/server`).

  Each function returns the whole frame (`type` included). On the Phoenix
  channel binding the frame is pushed as the payload of the event named by
  its `type`.

  A **participant** is the `%{id, role}` (plus optional `name`) identity of a
  connection, see `ConvergerWeb.ConvergerChannel`.
  """

  # Delivery statuses as stored (Converger.Deliveries.Delivery) -> v1 statuses.
  @statuses %{
    "pending" => "queued",
    # Parked by a circuit breaker or manual pause: still queued for the client.
    "paused" => "queued",
    "sent" => "sent",
    "delivered" => "delivered",
    "read" => "read",
    "failed" => "failed"
  }

  @doc """
  `deliveryStatus` for one activity and target channel, from the
  `delivery_status` PubSub payload of `Converger.Deliveries`.
  """
  def delivery_status(payload) do
    status = Map.get(@statuses, payload.status, payload.status)

    data =
      %{
        activityId: payload.activity_id,
        seq: payload.seq,
        channelId: payload.channel_id,
        status: status,
        timestamp: ms(status_time(status, payload))
      }
      |> put_failure(status, payload)

    %{type: "deliveryStatus", data: data}
  end

  @doc "`deliveryStatus` read receipt: `by` has read every activity up to `up_to_seq`."
  def read_receipt(up_to_seq, by, %DateTime{} = at) do
    %{
      type: "deliveryStatus",
      data: %{upToSeq: up_to_seq, status: "read", by: by, timestamp: ms(at)}
    }
  end

  @doc "`typing` indicator of `participant` (flat, as chativa's parseChatFrame expects)."
  def typing(is_typing, participant) do
    %{type: "typing", isTyping: is_typing, from: from(participant), sender: participant}
  end

  @doc """
  `presence` of `participant`: `"online"` with the number of its live
  connections, or `"offline"` with `lastSeenAt` once the last one closed.
  """
  def presence(participant, 0, %DateTime{} = last_seen_at) do
    %{
      type: "presence",
      data: %{
        participant: participant,
        status: "offline",
        connections: 0,
        lastSeenAt: ms(last_seen_at)
      }
    }
  end

  def presence(participant, connections, _at) when connections > 0 do
    %{
      type: "presence",
      data: %{participant: participant, status: "online", connections: connections}
    }
  end

  @doc ~s(mekik/1 `from`: `"user"` for the end user, `"bot"` for every other party.)
  def from(%{role: "user"}), do: "user"
  def from(_participant), do: "bot"

  defp status_time("read", payload), do: payload.read_at || payload.updated_at
  defp status_time("delivered", payload), do: payload.delivered_at || payload.updated_at
  defp status_time("sent", payload), do: payload.sent_at || payload.updated_at
  defp status_time(_status, payload), do: payload.updated_at

  defp put_failure(data, "failed", payload) do
    error =
      case payload.last_error do
        message when is_binary(message) ->
          %{code: "delivery_failed", message: message, retryable: false}

        _ ->
          %{code: "delivery_failed", retryable: false}
      end

    data
    |> Map.put(:error, error)
    |> then(fn data ->
      if is_integer(payload.attempts) and payload.attempts >= 1,
        do: Map.put(data, :attempt, payload.attempts),
        else: data
    end)
  end

  defp put_failure(data, _status, _payload), do: data

  defp ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp ms(_), do: System.system_time(:millisecond)
end
