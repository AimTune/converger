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
      assert log.changes["after"]["secret"] == "[REDACTED]"
      refute Jason.encode!(log.changes) =~ channel.secret
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
      assert log.changes["after"]["api_key"] == "[REDACTED]"
      assert log.changes["after"]["api_key_hash"] == "[REDACTED]"
      refute Jason.encode!(log.changes) =~ tenant.api_key
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
      assert log.changes["after"]["secret"] == "[REDACTED]"
      assert log.changes["after"]["secret_hash"] == "[REDACTED]"
      refute Jason.encode!(log.changes) =~ channel.secret
    end

    test "WhatsApp channel update audit log contains no token values" do
      tenant = tenant_fixture()

      {:ok, channel} =
        Channels.create_channel(%{
          name: "WA Meta",
          tenant_id: tenant.id,
          type: "whatsapp_meta",
          mode: "duplex",
          config: %{
            "phone_number_id" => "1234567890",
            "access_token" => "EAAG-old-access-token-value",
            "verify_token" => "old-verify-token-value"
          }
        })

      {:ok, _} =
        Channels.update_channel(
          channel,
          %{
            config: %{
              "phone_number_id" => "1234567890",
              "access_token" => "EAAG-new-access-token-value",
              "verify_token" => "new-verify-token-value"
            }
          },
          @admin_actor
        )

      [log] = AuditLogs.list_audit_logs(%{"resource_type" => "channel"})
      encoded = Jason.encode!(log.changes)

      for value <- [
            "EAAG-old-access-token-value",
            "EAAG-new-access-token-value",
            "old-verify-token-value",
            "new-verify-token-value",
            channel.secret
          ] do
        refute encoded =~ value
      end

      for side <- ["before", "after"] do
        config = log.changes[side]["config"]
        assert config["access_token"] == "[REDACTED]"
        assert config["verify_token"] == "[REDACTED]"
        assert config["phone_number_id"] == "1234567890"
      end
    end

    test "Infobip api_key and webhook auth headers are redacted" do
      tenant = tenant_fixture()

      {:ok, _} =
        Channels.create_channel(
          %{
            name: "Infobip",
            tenant_id: tenant.id,
            type: "whatsapp_infobip",
            mode: "duplex",
            config: %{
              "base_url" => "https://xyz.api.infobip.com",
              "api_key" => "infobip-secret-key",
              "sender" => "4412345"
            }
          },
          @admin_actor
        )

      {:ok, _} =
        Channels.create_channel(
          %{
            name: "Hook",
            tenant_id: tenant.id,
            type: "webhook",
            config: %{
              "url" => "https://example.com/hook",
              "headers" => %{"Authorization" => "Bearer hook-bearer-token"}
            }
          },
          @admin_actor
        )

      encoded = AuditLogs.list_audit_logs() |> Enum.map(& &1.changes) |> Jason.encode!()
      refute encoded =~ "infobip-secret-key"
      refute encoded =~ "hook-bearer-token"
      assert encoded =~ "https://example.com/hook"
    end

    test "API key rotation is audited without leaking keys" do
      tenant = tenant_fixture()
      {:ok, rotated} = Tenants.rotate_api_key(tenant, actor: @admin_actor)

      [log] = AuditLogs.list_audit_logs(%{"action" => "rotate_api_key"})
      assert log.resource_id == tenant.id
      encoded = Jason.encode!(log.changes)
      refute encoded =~ tenant.api_key
      refute encoded =~ rotated.api_key
      assert log.changes["after"]["previous_api_key_hash"] == "[REDACTED]"
    end
  end
end
