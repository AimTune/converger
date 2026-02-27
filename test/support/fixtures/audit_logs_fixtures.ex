defmodule Converger.AuditLogsFixtures do
  @moduledoc """
  Test helpers for creating audit log entries.
  """

  def audit_log_fixture(attrs \\ %{}) do
    {:ok, audit_log} =
      attrs
      |> Enum.into(%{
        actor_type: "admin",
        actor_id: "127.0.0.1",
        action: "create",
        resource_type: "tenant",
        resource_id: Ecto.UUID.generate(),
        changes: %{"before" => nil, "after" => %{"name" => "Test"}}
      })
      |> Converger.AuditLogs.create_audit_log()

    audit_log
  end
end
