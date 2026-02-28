defmodule Converger.AuditLogsTest do
  use Converger.DataCase

  alias Converger.AuditLogs

  import Converger.TenantsFixtures

  @valid_attrs %{
    actor_type: "admin",
    actor_id: "127.0.0.1",
    action: "create",
    resource_type: "tenant",
    resource_id: Ecto.UUID.generate()
  }

  describe "create_audit_log/1" do
    test "creates an audit log with valid attributes" do
      tenant = tenant_fixture()

      assert {:ok, log} =
               AuditLogs.create_audit_log(
                 Map.merge(@valid_attrs, %{
                   tenant_id: tenant.id,
                   resource_id: tenant.id,
                   changes: %{"before" => nil, "after" => %{"name" => "Test"}}
                 })
               )

      assert log.actor_type == "admin"
      assert log.action == "create"
      assert log.resource_type == "tenant"
      assert log.tenant_id == tenant.id
    end

    test "creates an audit log without tenant_id" do
      assert {:ok, log} = AuditLogs.create_audit_log(@valid_attrs)
      assert log.tenant_id == nil
    end

    test "rejects invalid actor_type" do
      assert {:error, changeset} =
               AuditLogs.create_audit_log(Map.put(@valid_attrs, :actor_type, "unknown"))

      assert errors_on(changeset).actor_type != []
    end

    test "rejects invalid action" do
      assert {:error, changeset} =
               AuditLogs.create_audit_log(Map.put(@valid_attrs, :action, "invalid"))

      assert errors_on(changeset).action != []
    end

    test "rejects invalid resource_type" do
      assert {:error, changeset} =
               AuditLogs.create_audit_log(Map.put(@valid_attrs, :resource_type, "invalid"))

      assert errors_on(changeset).resource_type != []
    end

    test "requires actor_type, actor_id, action, resource_type, resource_id" do
      assert {:error, changeset} = AuditLogs.create_audit_log(%{})
      errors = errors_on(changeset)
      assert errors.actor_type != []
      assert errors.actor_id != []
      assert errors.action != []
      assert errors.resource_type != []
      assert errors.resource_id != []
    end
  end

  describe "list_audit_logs/2" do
    test "returns logs filtered by resource_type" do
      {:ok, _} = AuditLogs.create_audit_log(@valid_attrs)

      {:ok, _} =
        AuditLogs.create_audit_log(Map.put(@valid_attrs, :resource_type, "channel"))

      assert [log] = AuditLogs.list_audit_logs(%{"resource_type" => "tenant"})
      assert log.resource_type == "tenant"
    end

    test "returns logs filtered by action" do
      {:ok, _} = AuditLogs.create_audit_log(@valid_attrs)

      {:ok, _} =
        AuditLogs.create_audit_log(Map.put(@valid_attrs, :action, "delete"))

      assert [log] = AuditLogs.list_audit_logs(%{"action" => "delete"})
      assert log.action == "delete"
    end

    test "returns logs filtered by actor_type" do
      {:ok, _} = AuditLogs.create_audit_log(@valid_attrs)

      {:ok, _} =
        AuditLogs.create_audit_log(%{
          @valid_attrs
          | actor_type: "tenant_api",
            actor_id: Ecto.UUID.generate()
        })

      assert [log] = AuditLogs.list_audit_logs(%{"actor_type" => "tenant_api"})
      assert log.actor_type == "tenant_api"
    end

    test "returns logs ordered by most recent first" do
      {:ok, first} = AuditLogs.create_audit_log(@valid_attrs)

      {:ok, second} =
        AuditLogs.create_audit_log(Map.put(@valid_attrs, :action, "update"))

      [most_recent, older] = AuditLogs.list_audit_logs()
      assert most_recent.id == second.id
      assert older.id == first.id
    end

    test "respects limit and offset" do
      for _ <- 1..5 do
        AuditLogs.create_audit_log(%{@valid_attrs | resource_id: Ecto.UUID.generate()})
      end

      assert length(AuditLogs.list_audit_logs(%{}, limit: 2, offset: 0)) == 2
      assert length(AuditLogs.list_audit_logs(%{}, limit: 10, offset: 3)) == 2
    end

    test "ignores empty string filter values" do
      {:ok, _} = AuditLogs.create_audit_log(@valid_attrs)

      assert [_] = AuditLogs.list_audit_logs(%{"action" => "", "resource_type" => ""})
    end
  end

  describe "count_audit_logs/1" do
    test "counts all logs" do
      for _ <- 1..3 do
        AuditLogs.create_audit_log(%{@valid_attrs | resource_id: Ecto.UUID.generate()})
      end

      assert AuditLogs.count_audit_logs() == 3
    end

    test "counts logs matching filters" do
      {:ok, _} = AuditLogs.create_audit_log(@valid_attrs)
      {:ok, _} = AuditLogs.create_audit_log(Map.put(@valid_attrs, :action, "delete"))

      assert AuditLogs.count_audit_logs(%{"action" => "create"}) == 1
      assert AuditLogs.count_audit_logs(%{"action" => "delete"}) == 1
      assert AuditLogs.count_audit_logs(%{"action" => "update"}) == 0
    end
  end

  describe "build_audit_log_entry/1" do
    test "returns a valid changeset" do
      changeset = AuditLogs.build_audit_log_entry(@valid_attrs)
      assert changeset.valid?
    end

    test "returns invalid changeset for bad data" do
      changeset = AuditLogs.build_audit_log_entry(%{})
      refute changeset.valid?
    end
  end
end
