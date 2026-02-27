defmodule Converger.AuditLogsIntegrationTest do
  use Converger.DataCase

  alias Converger.{Tenants, Channels, RoutingRules, AuditLogs}

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  @admin_actor %{type: "admin", id: "127.0.0.1"}
  @api_actor %{type: "tenant_api", id: "some-tenant-id"}

  describe "tenant audit logging" do
    test "create_tenant with actor produces audit log" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Audited Tenant"}, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "tenant"})
      assert log.action == "create"
      assert log.actor_type == "admin"
      assert log.actor_id == "127.0.0.1"
      assert log.resource_id == tenant.id
      assert log.changes["before"] == nil
      assert log.changes["after"]["name"] == "Audited Tenant"
    end

    test "update_tenant with actor produces audit log" do
      tenant = tenant_fixture()
      {:ok, _updated} = Tenants.update_tenant(tenant, %{status: "inactive"}, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "tenant"})
      assert log.action == "update"
      assert log.changes["before"]["status"] == "active"
      assert log.changes["after"]["status"] == "inactive"
    end

    test "delete_tenant with actor produces audit log" do
      tenant = tenant_fixture()
      {:ok, _} = Tenants.delete_tenant(tenant, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "tenant"})
      assert log.action == "delete"
      assert log.resource_id == tenant.id
      assert log.changes["before"]["name"] == tenant.name
      assert log.changes["after"] == nil
      # tenant_id should be nilified since the tenant was deleted
      assert log.tenant_id == nil
    end

    test "create_tenant without actor does not produce audit log" do
      {:ok, _} = Tenants.create_tenant(%{name: "No Audit"})
      assert AuditLogs.list_audit_logs() == []
    end
  end

  describe "channel audit logging" do
    test "create_channel with actor includes tenant_id and strips secret" do
      tenant = tenant_fixture()

      {:ok, channel} =
        Channels.create_channel(
          %{name: "Audited Channel", tenant_id: tenant.id, type: "echo", mode: "outbound"},
          @admin_actor
        )

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "channel"})
      assert log.tenant_id == tenant.id
      assert log.resource_id == channel.id
      assert log.action == "create"
      assert log.changes["after"]["name"] == "Audited Channel"
      # Secret must NOT be in the audit log
      refute Map.has_key?(log.changes["after"], "secret")
    end

    test "update_channel with actor produces audit log" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)

      {:ok, _} = Channels.update_channel(channel, %{status: "inactive"}, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "channel"})
      assert log.action == "update"
      assert log.changes["before"]["status"] == "active"
      assert log.changes["after"]["status"] == "inactive"
    end

    test "delete_channel with actor produces audit log" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)

      {:ok, _} = Channels.delete_channel(channel, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "channel"})
      assert log.action == "delete"
      assert log.resource_id == channel.id
    end
  end

  describe "routing_rule audit logging" do
    setup do
      tenant = tenant_fixture()

      source =
        webhook_channel_fixture(tenant, %{name: "Source"})

      target =
        webhook_channel_fixture(tenant, %{name: "Target"})

      %{tenant: tenant, source: source, target: target}
    end

    test "create_routing_rule with actor produces audit log", ctx do
      {:ok, rule} =
        RoutingRules.create_routing_rule(
          %{
            name: "Audited Rule",
            tenant_id: ctx.tenant.id,
            source_channel_id: ctx.source.id,
            target_channel_ids: [ctx.target.id]
          },
          @api_actor
        )

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "routing_rule"})
      assert log.action == "create"
      assert log.actor_type == "tenant_api"
      assert log.resource_id == rule.id
      assert log.tenant_id == ctx.tenant.id
    end

    test "toggle_routing_rule with actor produces audit log", ctx do
      {:ok, rule} =
        RoutingRules.create_routing_rule(%{
          name: "Toggle Rule",
          tenant_id: ctx.tenant.id,
          source_channel_id: ctx.source.id,
          target_channel_ids: [ctx.target.id]
        })

      {:ok, _} = RoutingRules.toggle_routing_rule(rule, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"action" => "toggle_enabled"})
      assert log.action == "toggle_enabled"
      assert log.changes["before"]["enabled"] == true
      assert log.changes["after"]["enabled"] == false
    end

    test "delete_routing_rule with actor produces audit log", ctx do
      {:ok, rule} =
        RoutingRules.create_routing_rule(%{
          name: "Delete Rule",
          tenant_id: ctx.tenant.id,
          source_channel_id: ctx.source.id,
          target_channel_ids: [ctx.target.id]
        })

      {:ok, _} = RoutingRules.delete_routing_rule(rule, @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"action" => "delete"})
      assert log.action == "delete"
      assert log.resource_id == rule.id
    end
  end

  describe "sensitive field stripping" do
    test "tenant audit log does not contain api_key" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Sensitive Tenant"}, @admin_actor)
      assert tenant.api_key != nil

      [log] = AuditLogs.list_audit_logs()
      refute Map.has_key?(log.changes["after"], "api_key")
    end

    test "channel audit log does not contain secret" do
      tenant = tenant_fixture()

      {:ok, channel} =
        Channels.create_channel(
          %{name: "Secret Channel", tenant_id: tenant.id, type: "echo", mode: "outbound"},
          @admin_actor
        )

      assert channel.secret != nil

      [log] = AuditLogs.list_audit_logs()
      refute Map.has_key?(log.changes["after"], "secret")
    end
  end
end
