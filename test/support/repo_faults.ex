defmodule Converger.RepoFaults do
  @moduledoc """
  Fault injection for tests of behaviour under database pressure (issue #35).

  `fail/2` makes every Ecto query on the given tables raise
  `DBConnection.ConnectionError`, as a saturated pool or a paused database
  does, until the test ends. Only queries built from `Ecto.Query` are
  affected (reads, `update_all`, `delete_all`), through
  `Converger.Repo.prepare_query/3`, which exists only in the test build.

  By default only the calling process and the processes it started
  (`$callers`: channel processes, tasks) fail. `pids: :any` fails every
  process, for code served by another process tree (a WebSocket over a real
  connection); only use it in `async: false` tests.
  """

  @key {__MODULE__, :faults}

  @doc "Makes queries on `tables` fail until the test exits."
  def fail(tables, opts \\ []) do
    pids = Keyword.get(opts, :pids, [self()])
    :persistent_term.put(@key, {MapSet.new(tables), pids})
    ExUnit.Callbacks.on_exit(&clear/0)
  end

  @doc "Removes every fault."
  def clear do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc false
  def check!(query) do
    case :persistent_term.get(@key, nil) do
      {tables, pids} ->
        if MapSet.member?(tables, table(query)) and caller?(pids) do
          raise DBConnection.ConnectionError,
                "connection not available and request was dropped from queue after 50ms " <>
                  "(injected by Converger.RepoFaults)"
        end

      nil ->
        :ok
    end
  end

  defp table(%Ecto.Query{from: %{source: {table, _schema}}}), do: table
  defp table(_query), do: nil

  defp caller?(:any), do: true
  defp caller?(pids), do: Enum.any?([self() | Process.get(:"$callers", [])], &(&1 in pids))
end
