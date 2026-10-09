defmodule Converger.Retention do
  @moduledoc """
  Data retention (issue #30, ADR-0026).

  ## Activities and deliveries

  Each tenant keeps its activities and deliveries for `tenants.retention_days`
  (default 365, at least `:min_retention_days`, default 30). `run/1` (the
  monthly `Converger.Workers.RetentionWorker`) looks at every monthly
  partition whose month ended more than `:min_retention_days` ago:

  * **Whole month expired** (the common case: every tenant with rows in the
    month is past its retention): both partitions are detached
    (`DETACH PARTITION ... CONCURRENTLY`, never blocks writers), every
    tenant's rows are exported to object storage
    (`Converger.Archive`), each archived object is downloaded again and its
    SHA-256 checked, the archived row count must equal the partition's row
    count, and only then are the detached tables dropped (milliseconds).
  * **Only some tenants expired** (a tenant with a shorter retention than
    others in the same month): that tenant's rows are archived and deleted
    from the live partition in batches of `part_rows`; each batch is
    uploaded and verified before its rows are deleted, in one transaction.
    The partition itself is dropped once the last tenant expires.

  Nothing is dropped or deleted that is not in a verified archive object.
  Every step is idempotent: an interrupted run continues where it stopped
  (detached partitions waiting for their archive are picked up first).

  ## Other tables

  `prune/1` (daily, `Converger.Workers.PruneWorker`) deletes, in batches,
  `channel_health_checks` older than `:health_check_days` (default 7) and
  `audit_logs` older than `:audit_log_days` (default 365). `nil` or `0`
  disables a window.

      config :converger, Converger.Retention,
        min_retention_days: 30,
        health_check_days: 7,
        audit_log_days: 365,
        prune_batch_size: 10_000
  """

  import Ecto.Query, warn: false
  require Logger

  alias Converger.{Archive, Partitions, Repo}
  alias Converger.Tenants.Tenant

  @doc "Platform-wide minimum for `tenants.retention_days`."
  def min_retention_days, do: config(:min_retention_days, 30)

  def health_check_days, do: config(:health_check_days, 7)

  def audit_log_days, do: config(:audit_log_days, 365)

  ## Activities and deliveries

  @doc """
  Applies retention to every eligible month. Returns
  `{:ok, [%{month: date, action: atom, ...}]}` or `{:error, reason}` (the
  first month that failed; earlier months are done, later ones untouched).

  Options: `:today` (default `Date.utc_today/0`), `:months` (only these
  months, for tests and manual runs).
  """
  def run(opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)

    months =
      case Keyword.get(opts, :months) do
        nil -> candidate_months(today)
        months -> Enum.map(months, &Partitions.month_start/1)
      end

    Enum.reduce_while(months, {:ok, []}, fn month, {:ok, acc} ->
      case process_month(month, today) do
        {:ok, result} ->
          {:cont, {:ok, [result | acc]}}

        {:error, reason} = error ->
          Logger.error("Retention failed",
            month: Partitions.month_label(month),
            reason: inspect(reason)
          )

          {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  Months with a partition (attached or detached) that ended at least
  `min_retention_days` before `today`, oldest first.
  """
  def candidate_months(%Date{} = today) do
    cutoff = Date.add(today, -min_retention_days())

    Partitions.tables()
    |> Enum.flat_map(&Partitions.months/1)
    |> Enum.uniq()
    |> Enum.filter(&(Date.compare(Partitions.next_month(&1), cutoff) != :gt))
    |> Enum.sort(Date)
  end

  @doc """
  Whether all of `month` is older than `retention_days` on `today`. The
  platform minimum always applies.
  """
  def expired?(%Date{} = month, retention_days, %Date{} = today) do
    days = max(retention_days || 0, min_retention_days())
    Date.compare(Partitions.next_month(month), Date.add(today, -days)) != :gt
  end

  @doc "Applies retention to one month."
  def process_month(%Date{} = month, %Date{} = today) do
    month = Partitions.month_start(month)

    if Enum.any?(Partitions.tables(), &detached?(&1, month)) do
      # A previous run decided to drop this month and was interrupted.
      archive_detached_month(month)
    else
      tenants = tenants_in_month(month)
      retention = retention_days(tenants)

      {expired, kept} =
        Enum.split_with(tenants, &expired?(month, Map.get(retention, &1), today))

      if kept == [] do
        archive_detached_month(month)
      else
        archive_and_delete_tenants(month, expired, length(kept))
      end
    end
  end

  defp archive_and_delete_tenants(month, expired, kept_count) do
    Enum.reduce_while(expired, {:ok, 0}, fn tenant_id, {:ok, rows} ->
      case archive_and_delete(tenant_id, month) do
        {:ok, n} -> {:cont, {:ok, rows + n}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} ->
        {:ok,
         %{
           month: month,
           action: :tenant_rows_archived,
           tenants: expired,
           rows: rows,
           tenants_kept: kept_count
         }}

      error ->
        error
    end
  end

  # Tenants with rows in the month, in either table (attached partitions).
  defp tenants_in_month(month) do
    Partitions.tables()
    |> Enum.filter(&attached?(&1, month))
    |> Enum.flat_map(&tenants_in(Partitions.leaf_name(&1, month)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Distinct tenant ids in a relation, as UUID strings. A loose index scan
  over the `(tenant_id, id)` index: one index probe per tenant, not a scan of
  the partition.
  """
  # Identifiers interpolated here are partition and table names built by
  # Converger.Partitions from a fixed table list and a Date, never user input;
  # values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def tenants_in(rel) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE t AS (
          (SELECT tenant_id FROM #{rel} ORDER BY tenant_id LIMIT 1)
          UNION ALL
          SELECT (SELECT tenant_id FROM #{rel} WHERE tenant_id > t.tenant_id ORDER BY tenant_id LIMIT 1)
          FROM t WHERE t.tenant_id IS NOT NULL
        )
        SELECT tenant_id FROM t WHERE tenant_id IS NOT NULL
        """,
        [],
        timeout: :infinity
      )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  # Tenants that no longer exist map to nil: their leftovers count as expired.
  defp retention_days([]), do: %{}

  defp retention_days(tenant_ids) do
    from(t in Tenant, where: t.id in ^tenant_ids, select: {t.id, t.retention_days})
    |> Repo.all()
    |> Map.new()
  end

  ## Whole month: detach, archive, verify, drop

  defp archive_detached_month(month) do
    Enum.each(Partitions.tables(), &Partitions.detach(&1, month))

    Partitions.tables()
    |> Enum.filter(&detached?(&1, month))
    |> Enum.reduce_while({:ok, %{}}, fn table, {:ok, acc} ->
      case archive_detached_table(table, month) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, table, rows)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, %{month: month, action: :partition_dropped, rows: rows}}
      error -> error
    end
  end

  defp archive_detached_table(table, month) do
    leaf = Partitions.leaf_name(table, month)

    with :ok <- export_detached(table, leaf, month),
         {:ok, rows} <- verify_detached(table, leaf, month),
         :ok <- Partitions.drop_detached(table, month) do
      Logger.info("Retention dropped partition", partition: leaf, rows: rows)
      {:ok, rows}
    end
  end

  defp export_detached(table, leaf, month) do
    Enum.reduce_while(tenants_in(leaf), :ok, fn tenant_id, :ok ->
      case export_tenant_from_detached(table, leaf, tenant_id, month) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Resumes after the last part recorded for this table/tenant/month in
  # "detached" mode. If a previous attempt uploaded a part but crashed before
  # recording it, the same part number and rows are exported again and the
  # object is overwritten.
  defp export_tenant_from_detached(table, leaf, tenant_id, month) do
    cursor =
      case Archive.parts(month, table: table, tenant_id: tenant_id, mode: "detached") do
        [] -> nil
        parts -> parts |> List.last() |> Map.fetch!(:last_id) |> Ecto.UUID.dump!()
      end

    case Archive.fetch_rows(leaf, tenant_id, cursor, Archive.part_rows()) do
      [] ->
        :ok

      rows ->
        part = Archive.next_part(table, tenant_id, month)

        with {:ok, attrs} <- Archive.upload_part(table, tenant_id, month, part, "detached", rows) do
          Archive.record_part(attrs)
          export_tenant_from_detached(table, leaf, tenant_id, month)
        end
    end
  end

  # Zero data loss: every row of the detached partition must be in a part,
  # and every part must be readable with the recorded checksum, before the
  # partition may be dropped.
  # Identifiers interpolated here are partition and table names built by
  # Converger.Partitions from a fixed table list and a Date, never user input;
  # values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp verify_detached(table, leaf, month) do
    parts = Archive.parts(month, table: table, mode: "detached")
    archived = parts |> Enum.map(& &1.row_count) |> Enum.sum()

    %{rows: [[actual]]} = Repo.query!("SELECT count(*) FROM #{leaf}", [], timeout: :infinity)

    with :ok <- check_count(leaf, actual, archived),
         :ok <- verify_objects(parts) do
      Archive.mark_verified(parts)
      {:ok, actual}
    end
  end

  defp check_count(_leaf, n, n), do: :ok

  defp check_count(leaf, actual, archived),
    do: {:error, {:archive_incomplete, leaf, actual: actual, archived: archived}}

  defp verify_objects(parts) do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      case Archive.verify(part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  ## One tenant in a live partition: archive and delete in batches

  @doc """
  Archives and deletes `tenant_id`'s rows of `month` from the live
  partitions, one verified part per transaction. Returns `{:ok, rows}`.
  """
  def archive_and_delete(tenant_id, %Date{} = month) do
    Partitions.tables()
    |> Enum.filter(&attached?(&1, month))
    |> Enum.reduce_while({:ok, 0}, fn table, {:ok, total} ->
      case archive_and_delete_table(table, tenant_id, month, 0) do
        {:ok, n} -> {:cont, {:ok, total + n}}
        error -> {:halt, error}
      end
    end)
  end

  defp archive_and_delete_table(table, tenant_id, month, total) do
    leaf = Partitions.leaf_name(table, month)

    result =
      Repo.transaction(
        fn ->
          case Archive.fetch_rows(leaf, tenant_id, nil, Archive.part_rows(), lock: true) do
            [] -> 0
            rows -> archive_and_delete_batch(table, leaf, tenant_id, month, rows)
          end
        end,
        timeout: :infinity
      )

    case result do
      {:ok, 0} -> {:ok, total}
      {:ok, n} -> archive_and_delete_table(table, tenant_id, month, total + n)
      {:error, reason} -> {:error, reason}
    end
  end

  # Upload, read back and verify, record, delete: all inside the transaction
  # that locked the rows, so a failure anywhere rolls the delete back.
  # Identifiers interpolated here are partition and table names built by
  # Converger.Partitions from a fixed table list and a Date, never user input;
  # values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp archive_and_delete_batch(table, leaf, tenant_id, month, rows) do
    part = Archive.next_part(table, tenant_id, month)

    with {:ok, attrs} <- Archive.upload_part(table, tenant_id, month, part, "deleted", rows),
         :ok <- Archive.verify(attrs) do
      Archive.record_part(Map.put(attrs, :verified_at, DateTime.utc_now()))
      ids = Enum.map(rows, &elem(&1, 0))

      %{num_rows: n} =
        Repo.query!("DELETE FROM #{leaf} WHERE id = ANY($1::uuid[])", [ids], timeout: :infinity)

      n
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp attached?(table, month) do
    leaf = Partitions.leaf_name(table, month)
    Enum.any?(Partitions.attached(table), &(&1.name == leaf))
  end

  defp detached?(table, month) do
    leaf = Partitions.leaf_name(table, month)
    Enum.any?(Partitions.detached(table), &(&1.name == leaf))
  end

  ## Time-based pruning

  @doc """
  Prunes `channel_health_checks` and `audit_logs` by their configured
  windows. Returns `%{channel_health_checks: n, audit_logs: n}` (`nil` for a
  disabled window).

  Options: `:now`, `:health_check_days`, `:audit_log_days`.
  """
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    %{
      channel_health_checks:
        prune_window(
          "channel_health_checks",
          "checked_at",
          Keyword.get(opts, :health_check_days, health_check_days()),
          now
        ),
      audit_logs:
        prune_window(
          "audit_logs",
          "inserted_at",
          Keyword.get(opts, :audit_log_days, audit_log_days()),
          now
        )
    }
  end

  defp prune_window(_table, _column, days, _now) when days in [nil, 0], do: nil

  defp prune_window(table, column, days, now) when is_integer(days) and days > 0 do
    prune_older_than(table, column, DateTime.add(now, -days, :day))
  end

  @doc """
  Deletes rows of `table` with `column` before `cutoff`, `:prune_batch_size`
  rows per statement so locks and WAL stay small. Returns the count.
  """
  # Identifiers interpolated here are partition and table names built by
  # Converger.Partitions from a fixed table list and a Date, never user input;
  # values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def prune_older_than(table, column, %DateTime{} = cutoff)
      when table in ["channel_health_checks", "audit_logs"] and
             column in ["checked_at", "inserted_at"] do
    batch = config(:prune_batch_size, 10_000)
    cutoff = DateTime.to_naive(cutoff)

    Stream.repeatedly(fn ->
      %{num_rows: n} =
        Repo.query!(
          "DELETE FROM #{table} WHERE id IN " <>
            "(SELECT id FROM #{table} WHERE #{column} < $1 LIMIT $2)",
          [cutoff, batch],
          timeout: :infinity
        )

      n
    end)
    |> Enum.reduce_while(0, fn
      n, acc when n < batch -> {:halt, acc + n}
      n, acc -> {:cont, acc + n}
    end)
  end

  defp config(key, default) do
    :converger |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
