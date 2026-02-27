defmodule Converger.AuditLogs do
  @moduledoc """
  The AuditLogs context.

  Provides functions to create and query audit log entries.
  Audit logs are immutable records of actions performed on resources.
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.AuditLogs.AuditLog

  def build_audit_log_entry(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
  end

  def create_audit_log(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
  end

  def list_audit_logs(filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    AuditLog
    |> apply_filters(filters)
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
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
