defmodule Converger.AuditLogs do
  @moduledoc """
  The AuditLogs context.

  Provides functions to create and query audit log entries.
  Audit logs are immutable records of actions performed on resources.
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
  Keyset-paginated audit log entries on `(inserted_at, id)`, newest first.

  Options: `:limit`, `:cursor`. Returns `{:ok, %Converger.Pagination.Page{}}`
  or `{:error, :invalid_cursor}`. See `Converger.Pagination.keyset/2`.
  """
  def paginate_audit_logs(filters \\ %{}, opts \\ []) do
    AuditLog
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(opts)
  end

  def count_audit_logs(filters \\ %{}) do
    AuditLog
    |> apply_filters(filters)
    |> Repo.aggregate(:count, :id)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {"tenant_id", value}, q when value != "" -> where(q, tenant_id: ^value)
      {:tenant_id, value}, q when value != "" -> where(q, tenant_id: ^value)
      {"actor_type", value}, q when value != "" -> where(q, actor_type: ^value)
      {:actor_type, value}, q when value != "" -> where(q, actor_type: ^value)
      {"action", value}, q when value != "" -> where(q, action: ^value)
      {:action, value}, q when value != "" -> where(q, action: ^value)
      {"resource_type", value}, q when value != "" -> where(q, resource_type: ^value)
      {:resource_type, value}, q when value != "" -> where(q, resource_type: ^value)
      {_, _}, q -> q
    end)
  end
end
