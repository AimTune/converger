defmodule Converger.AuditLogs do
  @moduledoc """
  The AuditLogs context.

  Provides functions to create and query audit log entries.
  Audit logs are immutable records of actions performed on resources.

  Filters (string or atom keys; blank values are ignored): `tenant_id`,
  `actor_type`, `action`, `resource_type`, `resource_id`, plus, for the admin
  page's search, `q` (the exact `resource_id` when it is a UUID, or else a
  case-insensitive substring of `actor_id`), `from` and `to` (ISO 8601 dates,
  inclusive, UTC, on `inserted_at`). Invalid UUIDs and dates match nothing
  rather than raising.
  """

  import Ecto.Query, warn: false
  alias Converger.AuditLogs.AuditLog
  alias Converger.Repo

  def build_audit_log_entry(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
  end

  def create_audit_log(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Audit log entries, newest first, by limit/offset.

  `:limit` is clamped to the configured maximum (see `Converger.Pagination`).
  Offsets get slower the deeper they go; for browsing prefer
  `paginate_audit_logs/2`.
  """
  def list_audit_logs(filters \\ %{}, opts \\ []) do
    limit = Converger.Pagination.clamp_limit(Keyword.get(opts, :limit))
    offset = max(Keyword.get(opts, :offset, 0), 0)

    AuditLog
    |> apply_filters(filters)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Keyset-paginated audit log entries on `(inserted_at, id)`, newest first, or
  oldest first when `filters` has `sort: "oldest"` (or the `:direction`
  option is `:asc`).

  Options: `:limit`, `:cursor`, `:direction`. Returns
  `{:ok, %Converger.Pagination.Page{}}` or `{:error, :invalid_cursor}`. See
  `Converger.Pagination.keyset/2`.
  """
  def paginate_audit_logs(filters \\ %{}, opts \\ []) do
    direction = if filter(filters, :sort) == "oldest", do: :asc, else: :desc

    AuditLog
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(Keyword.put_new(opts, :direction, direction))
  end

  def count_audit_logs(filters \\ %{}) do
    AuditLog
    |> apply_filters(filters)
    |> Repo.aggregate(:count, :id)
  end

  @filter_keys ~w(tenant_id actor_type action resource_type resource_id q from to)a

  defp apply_filters(query, filters) do
    Enum.reduce(@filter_keys, query, fn key, q ->
      case filter(filters, key) do
        value when value in [nil, ""] -> q
        value -> apply_filter(q, key, value)
      end
    end)
  end

  defp filter(filters, key) do
    case Map.get(filters, key, Map.get(filters, Atom.to_string(key))) do
      value when is_binary(value) -> String.trim(value)
      value -> value
    end
  end

  defp apply_filter(q, key, value) when key in [:tenant_id, :resource_id] do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> where(q, [a], field(a, ^key) == ^id)
      :error -> where(q, [_a], false)
    end
  end

  defp apply_filter(q, key, value) when key in [:actor_type, :action, :resource_type],
    do: where(q, [a], field(a, ^key) == ^value)

  defp apply_filter(q, :q, value) do
    pattern = Converger.Pagination.contains(value)

    case Ecto.UUID.cast(value) do
      {:ok, id} -> where(q, [a], a.resource_id == ^id or ilike(a.actor_id, ^pattern))
      :error -> where(q, [a], ilike(a.actor_id, ^pattern))
    end
  end

  defp apply_filter(q, key, value) when key in [:from, :to] do
    case date_bound(key, value) do
      {:ok, bound} when key == :from -> where(q, [a], a.inserted_at >= ^bound)
      {:ok, bound} -> where(q, [a], a.inserted_at <= ^bound)
      :error -> where(q, [_a], false)
    end
  end

  defp date_bound(_key, %DateTime{} = dt), do: {:ok, dt}

  defp date_bound(key, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} when key == :from -> DateTime.new(date, ~T[00:00:00.000000])
      {:ok, date} -> DateTime.new(date, ~T[23:59:59.999999])
      _ -> :error
    end
  end

  defp date_bound(_key, _value), do: :error
end
