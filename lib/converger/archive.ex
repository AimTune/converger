defmodule Converger.Archive do
  @moduledoc """
  Archive of expired `activities` and `deliveries` rows in object storage
  (issue #30, ADR-0034), and re-import of archived files.

  Objects are gzip-compressed JSON Lines, one row per line, every column of
  the table as produced by Postgres `row_to_json` (timestamps are UTC
  without offset, like the columns):

      archive/<tenant_id>/<YYYY-MM>/activities-00001.jsonl.gz
      archive/<tenant_id>/<YYYY-MM>/deliveries-00001.jsonl.gz

  A part holds at most `:part_rows` rows (default 50,000) in primary-key
  order. Part numbers are consecutive from 1 and deterministic, so an
  interrupted export that is retried overwrites the same object. Every part
  is recorded in `archive_parts` (`Converger.Archive.Part`) with its row
  count, size and SHA-256.

  Storage is one of the `Converger.Uploads.Storage` backends (local disk,
  S3/MinIO/R2, GCS, Azure). By default the attachment storage is used;
  configure a separate bucket with

      config :converger, Converger.Archive,
        storage: Converger.Uploads.S3Storage,
        storage_opts: [bucket: "converger-archive", ...],
        prefix: "archive",
        part_rows: 50_000

  (`ARCHIVE_STORAGE` and friends in `config/runtime.exs`, see
  docs/operations/retention.md).
  """

  import Ecto.Query, warn: false
  require Logger

  alias Converger.Archive.Part
  alias Converger.Partitions
  alias Converger.Repo

  @zero_uuid <<0::128>>
  @import_batch 500

  ## Configuration

  def config, do: Application.get_env(:converger, __MODULE__, [])

  @doc "The storage backend module."
  def storage, do: Keyword.get(config(), :storage) || Converger.Uploads.storage()

  @doc "The storage backend configuration."
  def storage_opts do
    if Keyword.get(config(), :storage),
      do: Keyword.get(config(), :storage_opts, []),
      else: Converger.Uploads.storage_opts()
  end

  def prefix, do: Keyword.get(config(), :prefix) || "archive"

  def part_rows, do: Keyword.get(config(), :part_rows) || 50_000

  @doc "Object key of a part."
  def object_key(tenant_id, %Date{} = month, table, part)
      when table in ["activities", "deliveries"] and is_integer(part) and part > 0 do
    padded = part |> Integer.to_string() |> String.pad_leading(5, "0")
    "#{prefix()}/#{tenant_id}/#{Partitions.month_label(month)}/#{table}-#{padded}.jsonl.gz"
  end

  ## Export

  @doc """
  Up to `limit` rows of `tenant_id` from relation `rel` (a partition) with
  an id greater than `cursor` (raw 16-byte UUID, `nil` for the start), as
  `[{id, json}]` in id order. With `lock: true` the rows are locked
  `FOR UPDATE` (must run in a transaction).
  """
  # Identifiers interpolated here are partition and table names built by
  # Converger.Partitions from a fixed table list and a Date, never user input;
  # values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  def fetch_rows(rel, tenant_id, cursor, limit, opts \\ []) do
    lock = if Keyword.get(opts, :lock, false), do: " FOR UPDATE", else: ""

    %{rows: rows} =
      Repo.query!(
        "SELECT t.id, row_to_json(t)::text FROM #{rel} AS t " <>
          "WHERE t.tenant_id = $1 AND t.id > $2 ORDER BY t.id LIMIT $3" <> lock,
        [dump_uuid(tenant_id), cursor || @zero_uuid, limit],
        timeout: :infinity
      )

    Enum.map(rows, fn [id, json] -> {id, json} end)
  end

  @doc "Gzipped JSON Lines body for rows from `fetch_rows/5`."
  def encode(rows), do: :zlib.gzip(Enum.map(rows, fn {_id, json} -> [json, ?\n] end))

  @doc """
  Uploads one part and returns the attributes of its manifest entry (not
  yet inserted). `rows` must be non-empty.
  """
  def upload_part(table, tenant_id, month, part, mode, rows) when rows != [] do
    body = encode(rows)
    key = object_key(tenant_id, month, table, part)
    {last_id, _} = List.last(rows)

    case storage().put(storage_opts(), key, body, content_type: "application/gzip") do
      :ok ->
        {:ok,
         %{
           tenant_id: tenant_id,
           table_name: table,
           month: Partitions.month_start(month),
           part: part,
           mode: mode,
           object_key: key,
           row_count: length(rows),
           byte_size: byte_size(body),
           sha256: sha256(body),
           last_id: Ecto.UUID.load!(last_id)
         }}

      {:error, reason} ->
        {:error, {:upload_failed, key, reason}}
    end
  end

  @doc """
  Downloads the object of a part (manifest attributes or `%Part{}`) and
  checks its size and SHA-256. Returns `:ok` or `{:error, reason}`.
  """
  def verify(%{object_key: key, sha256: sha, byte_size: size}) do
    case storage().get(storage_opts(), key) do
      {:ok, body} when byte_size(body) == size ->
        if sha256(body) == sha, do: :ok, else: {:error, {:checksum_mismatch, key}}

      {:ok, _body} ->
        {:error, {:size_mismatch, key}}

      {:error, reason} ->
        {:error, {:not_readable, key, reason}}
    end
  end

  @doc "Inserts (or, for a retried part, replaces) a manifest entry."
  def record_part(attrs) do
    part =
      Repo.insert!(struct(Part, attrs),
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:table_name, :tenant_id, :month, :part],
        returning: true
      )

    :telemetry.execute(
      [:converger, :archive, :part],
      %{rows: attrs.row_count, bytes: attrs.byte_size},
      %{table: attrs.table_name, mode: attrs.mode}
    )

    part
  end

  @doc "Next part number for a table, tenant and month."
  def next_part(table, tenant_id, %Date{} = month) do
    from(p in Part,
      where:
        p.table_name == ^table and p.tenant_id == ^tenant_id and
          p.month == ^Partitions.month_start(month),
      select: max(p.part)
    )
    |> Repo.one()
    |> Kernel.||(0)
    |> Kernel.+(1)
  end

  @doc "Manifest entries for a month, optionally filtered by table, tenant and mode."
  def parts(%Date{} = month, filters \\ []) do
    query =
      from(p in Part,
        where: p.month == ^Partitions.month_start(month),
        order_by: [asc: p.table_name, asc: p.tenant_id, asc: p.part]
      )

    filters
    |> Enum.reduce(query, fn
      {:table, t}, q -> where(q, [p], p.table_name == ^t)
      {:tenant_id, t}, q -> where(q, [p], p.tenant_id == ^t)
      {:mode, m}, q -> where(q, [p], p.mode == ^m)
    end)
    |> Repo.all()
  end

  @doc "Marks manifest entries as verified now."
  def mark_verified(parts) do
    ids = Enum.map(parts, & &1.id)
    now = DateTime.utc_now()
    Repo.update_all(from(p in Part, where: p.id in ^ids), set: [verified_at: now])
    :ok
  end

  ## Import

  @doc """
  Import entry point for the mix task and the release command. Options
  (one source): `tenant:` + `month:` (`"YYYY-MM"`), `key:` (object key) or
  `file:` (local path); `table:` overrides the table taken from the file
  name.
  """
  def import(opts) do
    cond do
      opts[:file] ->
        import_file(opts[:file], opts)

      opts[:key] ->
        import_object(opts[:key], opts)

      opts[:tenant] && opts[:month] ->
        with {:ok, tenant_id} <- Ecto.UUID.cast(opts[:tenant]),
             {:ok, month} <- Partitions.parse_month(opts[:month]) do
          import_tenant_month(tenant_id, month, opts)
        else
          :error -> {:error, :invalid_tenant_or_month}
        end

      true ->
        {:error, :missing_source}
    end
  end

  @doc """
  Re-imports every archived part of a tenant and month (activities first),
  reading parts `1, 2, ...` until one is missing, so it also works against a
  database without the manifest. Parts listed in `archive_parts` are checked
  against their recorded SHA-256 first.

  Returns `{:ok, %{"activities" => %{parts: n, rows: n, inserted: n}, ...}}`.
  Rows that already exist are skipped (`ON CONFLICT DO NOTHING`), so an
  import can be repeated.
  """
  def import_tenant_month(tenant_id, %Date{} = month, opts \\ []) do
    Enum.reduce_while(Partitions.tables(), {:ok, %{}}, fn table, {:ok, acc} ->
      case import_parts(table, tenant_id, month, 1, %{parts: 0, rows: 0, inserted: 0}, opts) do
        {:ok, stats} -> {:cont, {:ok, Map.put(acc, table, stats)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp import_parts(table, tenant_id, month, part, stats, opts) do
    key = object_key(tenant_id, month, table, part)

    case import_object(key, opts) do
      {:ok, %{rows: rows, inserted: inserted}} ->
        stats = %{
          parts: stats.parts + 1,
          rows: stats.rows + rows,
          inserted: stats.inserted + inserted
        }

        import_parts(table, tenant_id, month, part + 1, stats, opts)

      {:error, {:not_readable, ^key, :not_found}} ->
        {:ok, stats}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Re-imports one archived object by key. The table is taken from the file
  name (`activities-NNNNN.jsonl.gz`) unless `:table` is given. When the key
  is in `archive_parts`, its checksum is verified first.
  """
  def import_object(key, opts \\ []) when is_binary(key) do
    with {:ok, table} <- table_for(key, opts),
         {:ok, body} <- fetch(key),
         :ok <- check_manifest(key, body) do
      import_binary(body, table, opts)
    end
  end

  @doc "Re-imports a local `.jsonl.gz` (or plain `.jsonl`) file."
  # The path comes from the operator running the mix task / release command.
  # sobelow_skip ["Traversal.FileModule"]
  def import_file(path, opts \\ []) when is_binary(path) do
    with {:ok, table} <- table_for(Path.basename(path), opts),
         {:ok, body} <- File.read(path) do
      import_binary(body, table, opts)
    end
  end

  defp fetch(key) do
    case storage().get(storage_opts(), key) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:not_readable, key, reason}}
    end
  end

  defp check_manifest(key, body) do
    case Repo.get_by(Part, object_key: key) do
      nil ->
        :ok

      %Part{sha256: sha} ->
        if sha256(body) == sha, do: :ok, else: {:error, {:checksum_mismatch, key}}
    end
  end

  defp table_for(name, opts) do
    case Keyword.get(opts, :table) || Path.basename(name) do
      table when table in ["activities", "deliveries"] -> {:ok, table}
      "activities-" <> _ -> {:ok, "activities"}
      "deliveries-" <> _ -> {:ok, "deliveries"}
      _ -> {:error, {:unknown_table, name}}
    end
  end

  @doc """
  Inserts the rows of an archived body into `table`, creating the monthly
  partitions it needs. Returns `{:ok, %{rows: n, inserted: n}}`.
  """
  def import_binary(body, table, _opts \\ []) when table in ["activities", "deliveries"] do
    lines =
      body
      |> maybe_gunzip()
      |> String.split("\n", trim: true)

    columns = table_columns(table)
    key = Partitions.partition_key(table)

    {rows, inserted} =
      lines
      |> Stream.map(&Jason.decode!/1)
      |> Stream.chunk_every(@import_batch)
      |> Enum.reduce({0, 0}, fn records, {rows, inserted} ->
        ensure_months!(table, records, key)
        {rows + length(records), inserted + insert_records(table, columns, records)}
      end)

    {:ok, %{rows: rows, inserted: inserted}}
  end

  defp maybe_gunzip(<<0x1F, 0x8B, _::binary>> = gz), do: :zlib.gunzip(gz)
  defp maybe_gunzip(plain), do: plain

  defp ensure_months!(table, records, key) do
    records
    |> Enum.map(fn r -> r |> Map.fetch!(key) |> NaiveDateTime.from_iso8601!() end)
    |> Enum.map(&Partitions.month_start/1)
    |> Enum.uniq()
    |> Enum.each(fn month ->
      case Partitions.create_partition(table, month) do
        {:ok, _} ->
          :ok

        {:error, :detached_exists} ->
          raise "#{Partitions.leaf_name(table, month)} is detached and waiting for retention " <>
                  "to finish; let the retention job drop it, then import again"

        {:error, reason} ->
          raise "could not create #{Partitions.leaf_name(table, month)}: #{inspect(reason)}"
      end
    end)
  end

  # Identifiers interpolated here are partition and table names built by
  # Converger.Partitions from a fixed table list and a Date, never user input;
  # values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp insert_records(table, columns, [first | _] = records) do
    cols = Enum.filter(columns, &Map.has_key?(first, &1))
    list = Enum.map_join(cols, ", ", &~s("#{&1}"))

    %{num_rows: n} =
      Repo.query!(
        "INSERT INTO #{table} (#{list}) SELECT #{list} " <>
          "FROM jsonb_populate_recordset(NULL::#{table}, $1::jsonb) ON CONFLICT DO NOTHING",
        [records],
        timeout: :infinity
      )

    n
  end

  defp table_columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT attname FROM pg_attribute WHERE attrelid = to_regclass($1) " <>
          "AND attnum > 0 AND NOT attisdropped ORDER BY attnum",
        [table]
      )

    List.flatten(rows)
  end

  ## Helpers

  def sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp dump_uuid(<<_::128>> = raw), do: raw
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
