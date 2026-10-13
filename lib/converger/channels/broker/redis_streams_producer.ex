defmodule Converger.Channels.Broker.RedisStreamsProducer do
  @moduledoc """
  Broadway producer of a `redis_streams` channel: reads a stream as a
  member of a consumer group.

  On start it opens two Redis connections (one for blocking reads, one for
  acknowledgements, so an `XACK` never waits behind a blocked read) and
  creates the consumer group (`XGROUP CREATE ... MKSTREAM`) when it does
  not exist. Then:

    1. **Recovery.** It walks the group's pending entries list with
       `XAUTOCLAIM` (minimum idle time 0) and takes over every entry that
       was delivered to a consumer of the group but never acknowledged: by
       an earlier run of this consumer, or by the consumer of another node
       that ran the channel before (consumers are named after their node).
       The channel's consumer is a singleton in the cluster
       (`Converger.Channels.Broker.Consumer`), so no other consumer is
       processing them.
    2. **New entries.** `XREADGROUP ... BLOCK 2000 STREAMS <stream> >`, at
       most `batch_size` entries per read, as long as there is demand.

  An entry is acknowledged (`XACK`) once
  `Converger.Channels.Broker.Pipeline` handled it (accepted or
  dead-lettered). A failed entry is left pending and is recovered by the
  next start. The connections are linked: when one closes the producer
  exits and the pipeline restarts (see `Converger.Channels.Broker.Consumer`).

  Options: `:config` (the channel config), `:stream`, `:group`,
  `:consumer`, `:start_id` (`"0"` or `"$"`, for a new group), `:batch_size`.
  """

  use GenStage

  @behaviour Broadway.Producer
  @behaviour Broadway.Acknowledger

  require Logger

  alias Converger.Channels.Adapters.RedisStreams

  @block_ms 2_000
  @ack_chunk 500

  @impl GenStage
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    stream = Keyword.fetch!(opts, :stream)
    group = Keyword.fetch!(opts, :group)

    with {:ok, read_conn} <- connect(config),
         {:ok, ack_conn} <- connect(config),
         :ok <- create_group(read_conn, stream, group, Keyword.get(opts, :start_id, "0")) do
      {:producer,
       %{
         read_conn: read_conn,
         ack_conn: ack_conn,
         stream: stream,
         group: group,
         consumer: Keyword.fetch!(opts, :consumer),
         batch_size: Keyword.fetch!(opts, :batch_size),
         # The XAUTOCLAIM cursor while recovering pending entries, nil after.
         recover_cursor: "0-0",
         demand: 0,
         read_scheduled: false,
         draining: false
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp connect(config) do
    with {:ok, conn} <- RedisStreams.connect(config) do
      Process.link(conn)
      {:ok, conn}
    end
  end

  defp create_group(conn, stream, group, start_id) do
    case Redix.command(conn, ["XGROUP", "CREATE", stream, group, start_id, "MKSTREAM"]) do
      {:ok, _} -> :ok
      {:error, %Redix.Error{message: "BUSYGROUP" <> _}} -> :ok
      {:error, reason} -> {:error, {:group_create_failed, reason}}
    end
  end

  @impl GenStage
  def handle_demand(incoming, state) do
    {:noreply, [], schedule_read(%{state | demand: state.demand + incoming})}
  end

  @impl GenStage
  def handle_info(:read, state) do
    state = %{state | read_scheduled: false}

    if state.draining or state.demand == 0 do
      {:noreply, [], state}
    else
      case read(state) do
        {:ok, entries, state} ->
          messages = Enum.map(entries, &to_broadway_message(&1, state))
          state = %{state | demand: max(state.demand - length(messages), 0)}
          {:noreply, messages, schedule_read(state)}

        {:error, reason} ->
          {:stop, {:redis_read_failed, reason}, state}
      end
    end
  end

  def handle_info(_message, state), do: {:noreply, [], state}

  @impl Broadway.Producer
  def prepare_for_draining(state), do: {:noreply, [], %{state | draining: true}}

  @impl GenStage
  def terminate(_reason, state) do
    for conn <- [state.read_conn, state.ack_conn], Process.alive?(conn), do: Redix.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_read(%{read_scheduled: false, draining: false, demand: demand} = state)
       when demand > 0 do
    send(self(), :read)
    %{state | read_scheduled: true}
  end

  defp schedule_read(state), do: state

  ## Reads

  defp read(%{recover_cursor: cursor} = state) when is_binary(cursor) do
    command =
      xautoclaim_command(state.stream, state.group, state.consumer, cursor, count(state))

    case Redix.command(state.read_conn, command, timeout: 10_000) do
      {:ok, [next_cursor, entries | _deleted]} ->
        next = if next_cursor == "0-0", do: nil, else: next_cursor

        if next == nil do
          Logger.info("Redis stream consumer recovered its pending entries",
            source: "#{state.stream} group #{state.group}"
          )
        end

        {:ok, parse_entries(entries), %{state | recover_cursor: next}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read(state) do
    command =
      xreadgroup_command(state.stream, state.group, state.consumer, count(state), @block_ms)

    case Redix.command(state.read_conn, command, timeout: @block_ms + 5_000) do
      {:ok, nil} -> {:ok, [], state}
      {:ok, [[_stream, entries] | _]} -> {:ok, parse_entries(entries), state}
      {:ok, []} -> {:ok, [], state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count(state), do: min(state.demand, state.batch_size)

  @doc false
  def xautoclaim_command(stream, group, consumer, cursor, count),
    do: [
      "XAUTOCLAIM",
      stream,
      group,
      consumer,
      "0",
      cursor,
      "COUNT",
      Integer.to_string(count)
    ]

  @doc false
  def xreadgroup_command(stream, group, consumer, count, block_ms),
    do: [
      "XREADGROUP",
      "GROUP",
      group,
      consumer,
      "COUNT",
      Integer.to_string(count),
      "BLOCK",
      Integer.to_string(block_ms),
      "STREAMS",
      stream,
      ">"
    ]

  @doc """
  Parse stream entries (`[[id, [field, value, ...]], ...]`) into
  `[{id, [{field, value}]}]`. Entries deleted from the stream while pending
  (`nil`, or an id with nil fields) are skipped.
  """
  @spec parse_entries(list() | nil) :: [{String.t(), [{String.t(), String.t()}]}]
  def parse_entries(entries) when is_list(entries) do
    for [id, fields] <- entries, is_binary(id), is_list(fields) do
      {id, pairs(fields)}
    end
  end

  def parse_entries(_entries), do: []

  defp pairs([name, value | rest]), do: [{name, value} | pairs(rest)]
  defp pairs(_), do: []

  defp to_broadway_message({id, fields}, state) do
    %Broadway.Message{
      data: fields,
      metadata: %{id: id, stream: state.stream},
      acknowledger: {__MODULE__, {state.ack_conn, state.stream, state.group}, id}
    }
  end

  ## Acknowledgements

  @impl Broadway.Acknowledger
  def ack({conn, stream, group}, successful, failed) do
    successful
    |> Enum.map(fn %{acknowledger: {_, _, id}} -> id end)
    |> Enum.chunk_every(@ack_chunk)
    |> Enum.each(&xack(conn, stream, group, &1))

    if failed != [] do
      Logger.warning("Redis stream entries failed, left pending until the consumer restarts",
        source: stream,
        count: length(failed)
      )
    end

    :ok
  end

  # An XACK that fails leaves the entry pending: it is claimed again on the
  # next start, and the idempotency key makes it a duplicate.
  defp xack(conn, stream, group, ids) do
    case Redix.command(conn, ["XACK", stream, group | ids], timeout: 10_000) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Redis XACK failed", source: stream, reason: inspect(reason))
    end
  catch
    :exit, reason ->
      Logger.warning("Redis XACK failed", source: stream, reason: inspect(reason))
  end
end
