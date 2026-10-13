defmodule ConvergerWeb.ManagementApiTest do
  @moduledoc """
  The management and admin APIs with scoped API keys (issue #51, ADR-0061).
  """
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{ApiKeys, AuditLogs, Channels, Repo}
  alias Converger.ApiKeys.ApiKey
  alias Converger.Auth.Token

  @admin_token String.duplicate("a", 40)

  setup do
    previous = Application.get_env(:converger, :admin_api_token)
    Application.put_env(:converger, :admin_api_token, @admin_token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :admin_api_token, previous),
        else: Application.delete_env(:converger, :admin_api_token)
    end)

    :ok
  end

  defp admin(conn \\ build_conn()),
    do: conn |> put_req_header("authorization", "Bearer " <> @admin_token)

  defp api(key), do: build_conn() |> put_req_header("x-api-key", key)

  defp scoped_key(tenant, scopes, attrs \\ %{}) do
    {:ok, api_key} =
      ApiKeys.create_api_key(
        tenant.id,
        Map.merge(%{"name" => "test", "scopes" => scopes}, attrs),
        %{type: "system", id: "test"}
      )

    api_key
  end

  describe "provisioning with only the API (acceptance)" do
    test "creates a tenant, a channel, a routing rule and a webhook subscription" do
      tenant =
        admin()
        |> post(~p"/api/v1/admin/tenants", %{"tenant" => %{"name" => "Acme via API"}})
        |> json_response(201)
        |> Map.fetch!("data")

      assert "cvg_live_" <> _ = primary_key = tenant["api_key"]

      # The tenant issues itself a manage-only key for its IaC pipeline.
      key =
        api(primary_key)
        |> post(~p"/api/v1/manage/api_keys", %{
          "api_key" => %{"name" => "terraform", "scopes" => ["manage"]}
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert key["scopes"] == ["manage"]
      manage = key["key"]

      inbound =
        api(manage)
        |> post(~p"/api/v1/manage/channels", %{
          "channel" => %{"name" => "web", "type" => "websocket"}
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert is_binary(inbound["secret"])
      assert inbound["tenant_id"] == tenant["id"]

      hook =
        api(manage)
        |> post(~p"/api/v1/manage/channels", %{
          "channel" => %{
            "name" => "crm",
            "type" => "webhook",
            "mode" => "outbound",
            "config" => %{"url" => "https://example.com/hook"}
          }
        })
        |> json_response(201)
        |> Map.fetch!("data")

      rule =
        api(manage)
        |> post(~p"/api/v1/routing_rules", %{
          "routing_rule" => %{
            "name" => "to crm",
            "source_channel_id" => inbound["id"],
            "target_channel_ids" => [hook["id"]]
          }
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert rule["tenant_id"] == tenant["id"]

      subscription =
        api(manage)
        |> post(~p"/api/v1/webhook_subscriptions", %{
          "webhook_subscription" => %{
            "url" => "https://example.com/events",
            "events" => ["delivery.failed"]
          }
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert subscription["tenant_id"] == tenant["id"]

      # Every management call is audited with the key as the actor.
      for {resource_type, id} <- [
            {"channel", inbound["id"]},
            {"routing_rule", rule["id"]},
            {"webhook_subscription", subscription["id"]}
          ] do
        assert [%{actor_type: "tenant_api", actor_id: actor_id}] =
                 AuditLogs.list_audit_logs(%{
                   "resource_type" => resource_type,
                   "tenant_id" => tenant["id"]
                 })
                 |> Enum.filter(&(&1.resource_id == id))

        assert actor_id == key["id"]
      end

      assert [%{actor_type: "admin_api", actor_id: "admin_api_token", action: "create"}] =
               AuditLogs.list_audit_logs(%{"resource_type" => "tenant"})
               |> Enum.filter(&(&1.resource_id == tenant["id"]))
    end
  end

  describe "scopes" do
    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      %{tenant: tenant, channel: channel, conversation: conversation}
    end

    test "a read key reads but cannot create activities", %{conversation: conversation} = ctx do
      read = scoped_key(ctx.tenant, ["read"]).key

      api(read) |> get(~p"/api/v1/conversations") |> json_response(200)

      error =
        api(read)
        |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{"text" => "hi"})
        |> assert_api_error(403, "insufficient_scope")

      assert error["details"] == %{"required" => "write"}
    end

    test "a write key creates activities but needs manage for channel changes", ctx do
      write = scoped_key(ctx.tenant, ["read", "write"]).key

      api(write)
      |> post(~p"/api/v1/conversations/#{ctx.conversation.id}/activities", %{"text" => "hi"})
      |> json_response(201)

      api(write)
      |> post(~p"/api/v1/manage/channels", %{"channel" => %{"name" => "x"}})
      |> assert_api_error(403, "insufficient_scope")

      api(write)
      |> post(~p"/api/v1/channels/#{ctx.channel.id}/pause")
      |> assert_api_error(403, "insufficient_scope")

      api(write)
      |> post(~p"/api/v1/routing_rules", %{"routing_rule" => %{"name" => "x"}})
      |> assert_api_error(403, "insufficient_scope")

      # A dry-run only reads.
      api(write)
      |> post(~p"/api/v1/routing_rules/dry_run", %{
        "source_channel_id" => ctx.channel.id,
        "activity" => %{"text" => "hi"}
      })
      |> json_response(200)
    end

    test "a manage-only key cannot touch conversation data", ctx do
      manage = scoped_key(ctx.tenant, ["manage"]).key

      api(manage)
      |> get(~p"/api/v1/conversations")
      |> assert_api_error(403, "insufficient_scope")

      api(manage) |> get(~p"/api/v1/manage/channels") |> json_response(200)
    end

    test "the primary key has every scope", ctx do
      api(ctx.tenant.api_key) |> get(~p"/api/v1/manage/channels") |> json_response(200)

      api(ctx.tenant.api_key)
      |> post(~p"/api/v1/conversations/#{ctx.conversation.id}/activities", %{"text" => "hi"})
      |> json_response(201)
    end

    test "revoked and expired keys are rejected", ctx do
      revoked = scoped_key(ctx.tenant, ["read"])
      {:ok, _} = ApiKeys.revoke_api_key(revoked, %{type: "system", id: "test"})

      api(revoked.key) |> get(~p"/api/v1/conversations") |> assert_api_error(401, "unauthorized")

      expired = scoped_key(ctx.tenant, ["read"])

      expired
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
      |> Repo.update!()

      api(expired.key) |> get(~p"/api/v1/conversations") |> assert_api_error(401, "unauthorized")
    end

    test "keys of an inactive tenant are rejected", ctx do
      key = scoped_key(ctx.tenant, ["read"]).key
      {:ok, _} = Converger.Tenants.update_tenant(ctx.tenant, %{status: "inactive"})

      api(key) |> get(~p"/api/v1/conversations") |> assert_api_error(401, "unauthorized")
    end

    test "records last_used_at", ctx do
      api_key = scoped_key(ctx.tenant, ["read"])
      api(api_key.key) |> get(~p"/api/v1/conversations") |> json_response(200)

      assert %ApiKey{last_used_at: %DateTime{}} = Repo.get!(ApiKey, api_key.id)
    end

    test "channel tokens cannot use the management API", ctx do
      {:ok, token, _} = Token.generate_channel_token(ctx.channel)

      build_conn()
      |> put_req_header("x-channel-token", token)
      |> get(~p"/api/v1/manage/channels")
      |> assert_api_error(403, "forbidden")
    end

    test "a key cannot issue a key with scopes it lacks", ctx do
      manage = scoped_key(ctx.tenant, ["manage"]).key

      error =
        api(manage)
        |> post(~p"/api/v1/manage/api_keys", %{
          "api_key" => %{"name" => "wider", "scopes" => ["read", "manage"]}
        })
        |> assert_api_error(403, "insufficient_scope")

      assert error["details"] == %{"required" => "read"}
    end

    test "rejects unknown scopes", ctx do
      api(ctx.tenant.api_key)
      |> post(~p"/api/v1/manage/api_keys", %{"api_key" => %{"name" => "x", "scopes" => ["root"]}})
      |> assert_api_error(422, "validation_failed")
    end

    test "revoking a key keeps it listed", ctx do
      api_key = scoped_key(ctx.tenant, ["read"])

      api(ctx.tenant.api_key)
      |> delete(~p"/api/v1/manage/api_keys/#{api_key.id}")
      |> response(204)

      [listed] =
        api(ctx.tenant.api_key)
        |> get(~p"/api/v1/manage/api_keys")
        |> json_response(200)
        |> Map.fetch!("data")

      assert listed["id"] == api_key.id
      assert listed["revoked_at"]
      refute Map.has_key?(listed, "key")
    end
  end

  describe "channels" do
    setup do
      tenant = tenant_fixture()
      %{tenant: tenant, manage: scoped_key(tenant, ["manage"]).key}
    end

    test "redacts config secrets and keeps them when sent back", %{manage: manage} do
      created =
        api(manage)
        |> post(~p"/api/v1/manage/channels", %{
          "channel" => %{
            "name" => "hook",
            "type" => "webhook",
            "mode" => "outbound",
            "config" => %{
              "url" => "https://example.com/hook",
              "headers" => %{"authorization" => "Bearer provider-secret"}
            }
          }
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert created["config"]["headers"] == %{"authorization" => "[REDACTED]"}

      shown = api(manage) |> get(~p"/api/v1/manage/channels/#{created["id"]}")
      config = json_response(shown, 200)["data"]["config"]
      refute Map.has_key?(json_response(shown, 200)["data"], "secret")

      # Terraform-style: send back what was read, with one change.
      api(manage)
      |> put(~p"/api/v1/manage/channels/#{created["id"]}", %{
        "channel" => %{"name" => "hook-2", "config" => config}
      })
      |> json_response(200)

      channel = Channels.get_channel!(created["id"])
      assert channel.name == "hook-2"
      assert channel.config["headers"] == %{"authorization" => "Bearer provider-secret"}
    end

    test "If-Match: stale ETags get 412, current ones apply", %{tenant: tenant, manage: manage} do
      channel = channel_fixture(tenant)

      etag =
        api(manage)
        |> get(~p"/api/v1/manage/channels/#{channel.id}")
        |> get_resp_header("etag")
        |> List.first()

      assert etag

      changed =
        api(manage)
        |> put_req_header("if-match", etag)
        |> patch(~p"/api/v1/manage/channels/#{channel.id}", %{"channel" => %{"name" => "v2"}})

      assert json_response(changed, 200)["data"]["name"] == "v2"
      assert [new_etag] = get_resp_header(changed, "etag")
      refute new_etag == etag

      error =
        api(manage)
        |> put_req_header("if-match", etag)
        |> patch(~p"/api/v1/manage/channels/#{channel.id}", %{"channel" => %{"name" => "v3"}})
        |> assert_api_error(412, "precondition_failed")

      assert error["details"]["current_etag"] == new_etag

      api(manage)
      |> put_req_header("if-match", etag)
      |> delete(~p"/api/v1/manage/channels/#{channel.id}")
      |> assert_api_error(412, "precondition_failed")

      api(manage)
      |> put_req_header("if-match", new_etag)
      |> delete(~p"/api/v1/manage/channels/#{channel.id}")
      |> response(204)
    end

    test "PUT with the same body is idempotent", %{tenant: tenant, manage: manage} do
      channel = channel_fixture(tenant)
      body = %{"channel" => %{"name" => "same", "rate_limit" => "10/s"}}

      first = api(manage) |> put(~p"/api/v1/manage/channels/#{channel.id}", body)
      second = api(manage) |> put(~p"/api/v1/manage/channels/#{channel.id}", body)

      assert Map.drop(json_response(first, 200)["data"], ["updated_at"]) ==
               Map.drop(json_response(second, 200)["data"], ["updated_at"])
    end

    test "rotate_secret replaces the secret", %{tenant: tenant, manage: manage} do
      channel = channel_fixture(tenant)

      rotated =
        api(manage)
        |> post(~p"/api/v1/manage/channels/#{channel.id}/rotate_secret")
        |> json_response(200)
        |> Map.fetch!("data")

      refute rotated["secret"] == channel.secret

      assert {:error, :unauthorized} =
               Channels.validate_channel_secret(channel.id, channel.secret)

      assert Channels.get_channel_by_secret(rotated["secret"]).id == channel.id

      assert [%{action: "rotate_secret"}] =
               AuditLogs.list_audit_logs(%{
                 "resource_type" => "channel",
                 "action" => "rotate_secret"
               })
               |> Enum.filter(&(&1.resource_id == channel.id))
    end

    test "cannot reach another tenant's channel or move a channel", %{manage: manage} do
      other = channel_fixture(tenant_fixture())

      api(manage)
      |> get(~p"/api/v1/manage/channels/#{other.id}")
      |> assert_api_error(404, "not_found")

      created =
        api(manage)
        |> post(~p"/api/v1/manage/channels", %{
          "channel" => %{"name" => "mine", "type" => "websocket", "tenant_id" => other.tenant_id}
        })
        |> json_response(201)

      refute created["data"]["tenant_id"] == other.tenant_id
    end
  end

  describe "users and settings" do
    setup do
      tenant = tenant_fixture()
      %{tenant: tenant, manage: scoped_key(tenant, ["manage"]).key}
    end

    test "creates, updates and deletes portal users", %{tenant: tenant, manage: manage} do
      user =
        api(manage)
        |> post(~p"/api/v1/manage/users", %{
          "user" => %{
            "email" => "owner@example.com",
            "name" => "Owner",
            "password" => Converger.AccountsFixtures.valid_password(),
            "role" => "owner"
          }
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert %{"role" => "owner", "tenant_id" => tenant_id, "totp_enabled" => false} = user
      assert tenant_id == tenant.id
      refute Map.has_key?(user, "password_hash")

      api(manage)
      |> patch(~p"/api/v1/manage/users/#{user["id"]}", %{"user" => %{"role" => "viewer"}})
      |> json_response(200)
      |> then(&assert(&1["data"]["role"] == "viewer"))

      api(manage) |> delete(~p"/api/v1/manage/users/#{user["id"]}") |> response(204)

      api(manage)
      |> get(~p"/api/v1/manage/users/#{user["id"]}")
      |> assert_api_error(404, "not_found")
    end

    test "updates settings; invalid limits change nothing", %{tenant: tenant, manage: manage} do
      api(manage)
      |> patch(~p"/api/v1/manage/settings", %{
        "settings" => %{
          "retention_days" => 400,
          "limits" => %{"activity_create" => %{"limit" => 5, "scale_ms" => 1000}},
          "tier" => "high",
          "name" => "renamed"
        }
      })
      |> json_response(200)
      |> then(fn %{"data" => data} ->
        assert data["retention_days"] == 400
        assert data["limits"] == %{"activity_create" => %{"limit" => 5, "scale_ms" => 1000}}
        # Platform settings are not the tenant's to change.
        assert data["tier"] == "default"
        assert data["name"] == tenant.name
      end)

      api(manage)
      |> patch(~p"/api/v1/manage/settings", %{
        "settings" => %{"retention_days" => 500, "limits" => %{"nope" => %{}}}
      })
      |> assert_api_error(422, "validation_failed")

      assert Converger.Tenants.get_tenant!(tenant.id).retention_days == 400
    end
  end

  describe "admin API" do
    test "requires the admin token" do
      build_conn() |> get(~p"/api/v1/admin/tenants") |> assert_api_error(401, "unauthorized")

      build_conn()
      |> put_req_header("authorization", "Bearer " <> String.duplicate("b", 40))
      |> get(~p"/api/v1/admin/tenants")
      |> assert_api_error(401, "unauthorized")

      Application.delete_env(:converger, :admin_api_token)
      admin() |> get(~p"/api/v1/admin/tenants") |> assert_api_error(401, "unauthorized")
    end

    test "tenant API keys do not unlock it" do
      tenant = tenant_fixture()

      build_conn()
      |> put_req_header("authorization", "Bearer " <> tenant.api_key)
      |> get(~p"/api/v1/admin/tenants")
      |> assert_api_error(401, "unauthorized")
    end

    test "updates, rotates the primary key and deletes tenants" do
      tenant = tenant_fixture()

      admin()
      |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{
        "tenant" => %{"tier" => "high", "status" => "inactive"}
      })
      |> json_response(200)
      |> then(&assert(%{"tier" => "high", "status" => "inactive"} = &1["data"]))

      rotated =
        admin()
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/rotate_api_key")
        |> json_response(200)

      refute rotated["data"]["api_key"] == tenant.api_key

      admin() |> delete(~p"/api/v1/admin/tenants/#{tenant.id}") |> response(204)
      admin() |> get(~p"/api/v1/admin/tenants/#{tenant.id}") |> assert_api_error(404, "not_found")
    end

    test "issues and revokes scoped keys for a tenant" do
      tenant = tenant_fixture()

      key =
        admin()
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/api_keys", %{
          "api_key" => %{"name" => "ci", "scopes" => ["read"]}
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert key["created_by"] == "admin_api:admin_api_token"
      api(key["key"]) |> get(~p"/api/v1/conversations") |> json_response(200)

      admin()
      |> delete(~p"/api/v1/admin/tenants/#{tenant.id}/api_keys/#{key["id"]}")
      |> response(204)

      api(key["key"]) |> get(~p"/api/v1/conversations") |> assert_api_error(401, "unauthorized")
    end

    test "invalid limits create no tenant" do
      admin()
      |> post(~p"/api/v1/admin/tenants", %{
        "tenant" => %{"name" => "bad limits", "limits" => %{"nope" => %{}}}
      })
      |> assert_api_error(422, "validation_failed")

      refute Converger.Tenants.get_tenant_by_name("bad limits")
    end
  end
end
