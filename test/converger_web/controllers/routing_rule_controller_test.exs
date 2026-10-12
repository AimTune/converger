defmodule ConvergerWeb.RoutingRuleControllerTest do
  use ConvergerWeb.ConnCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Deliveries, RoutingRules}

  setup %{conn: conn} do
    tenant = tenant_fixture()
    origin = channel_fixture(tenant)

    vip_hook =
      webhook_channel_fixture(tenant, %{
        mode: "outbound",
        transformations: [%{"type" => "add_suffix", "suffix" => " [hook]"}]
      })

    crm = webhook_channel_fixture(tenant, %{mode: "outbound"})

    conn =
      conn
      |> put_req_header("x-api-key", tenant.api_key)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, tenant: tenant, origin: origin, vip_hook: vip_hook, crm: crm}
  end

  defp create_rules(%{tenant: tenant, origin: origin, vip_hook: vip_hook, crm: crm}) do
    {:ok, vip} =
      RoutingRules.create_routing_rule(%{
        name: "vip",
        tenant_id: tenant.id,
        source_channel_id: origin.id,
        target_channel_ids: [vip_hook.id],
        conditions: %{"field" => "metadata.vip", "op" => "eq", "value" => true},
        transformations: [%{"type" => "add_prefix", "prefix" => "[VIP] "}],
        priority: 10
      })

    {:ok, crm_rule} =
      RoutingRules.create_routing_rule(%{
        name: "crm",
        tenant_id: tenant.id,
        source_channel_id: origin.id,
        target_channel_ids: [crm.id],
        conditions: %{"field" => "type", "op" => "eq", "value" => "message"}
      })

    %{vip_rule: vip, crm_rule: crm_rule}
  end

  describe "CRUD" do
    test "creates and renders conditional rules", %{
      conn: conn,
      origin: origin,
      vip_hook: vip_hook
    } do
      body = %{
        "routing_rule" => %{
          "name" => "vip",
          "source_channel_id" => origin.id,
          "target_channel_ids" => [vip_hook.id],
          "conditions" => [%{"field" => "metadata.vip", "op" => "eq", "value" => true}],
          "transformations" => [%{"type" => "add_prefix", "prefix" => "[VIP] "}],
          "priority" => 10,
          "stop_processing" => true
        }
      }

      data =
        conn |> post(~p"/api/v1/routing_rules", body) |> json_response(201) |> Map.fetch!("data")

      assert %{
               "conditions" => %{
                 "all" => [%{"field" => "metadata.vip", "op" => "eq", "value" => true}]
               },
               "transformations" => [%{"type" => "add_prefix", "prefix" => "[VIP] "}],
               "priority" => 10,
               "stop_processing" => true
             } = data
    end

    test "rejects invalid conditions with 422", %{conn: conn, origin: origin, vip_hook: vip_hook} do
      body = %{
        "routing_rule" => %{
          "name" => "bad",
          "source_channel_id" => origin.id,
          "target_channel_ids" => [vip_hook.id],
          "conditions" => %{"field" => "text", "op" => "regex", "value" => "(unclosed"}
        }
      }

      assert %{"errors" => %{"conditions" => [message]}} =
               conn |> post(~p"/api/v1/routing_rules", body) |> json_response(422)

      assert message =~ "does not compile"
    end
  end

  describe "POST /api/v1/routing_rules/dry_run" do
    setup :create_rules

    test "shows the matched rules and the transformed payload per target", %{
      conn: conn,
      origin: origin,
      vip_hook: vip_hook,
      crm: crm,
      vip_rule: vip_rule,
      crm_rule: crm_rule
    } do
      body = %{
        "source_channel_id" => origin.id,
        "activity" => %{
          "text" => "upgrade me",
          "sender" => "user-1",
          "metadata" => %{"vip" => true}
        }
      }

      data =
        conn
        |> post(~p"/api/v1/routing_rules/dry_run", body)
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["direction"] == "inbound"
      assert data["matched_rule_ids"] == [vip_rule.id, crm_rule.id]

      assert [%{"id" => vip_id, "result" => "matched"}, %{"id" => crm_id, "result" => "matched"}] =
               data["rules"]

      assert {vip_id, crm_id} == {vip_rule.id, crm_rule.id}

      targets = Map.new(data["targets"], &{&1["channel_id"], &1})

      # Channel middleware first, then the rule's transformations.
      assert %{
               "reason" => "rule",
               "rule_ids" => [^vip_id],
               "outcome" => "deliver",
               "payload" => %{"text" => "[VIP] upgrade me [hook]", "metadata" => %{"vip" => true}}
             } = targets[vip_hook.id]

      assert %{"outcome" => "deliver", "payload" => %{"text" => "upgrade me"}} = targets[crm.id]
      assert %{"reason" => "origin", "outcome" => "deliver"} = targets[origin.id]

      # Nothing was stored or sent.
      assert Deliveries.list_dead_letters(%{"tenant_id" => origin.tenant_id}) == []
    end

    test "a non-matching activity reaches only the unconditional targets", %{
      conn: conn,
      origin: origin,
      vip_hook: vip_hook
    } do
      body = %{
        "source_channel_id" => origin.id,
        "activity" => %{"type" => "event", "text" => "x", "metadata" => %{"vip" => false}}
      }

      data =
        conn
        |> post(~p"/api/v1/routing_rules/dry_run", body)
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["matched_rule_ids"] == []
      assert Enum.map(data["rules"], & &1["result"]) == ["not_matched", "not_matched"]
      refute Enum.any?(data["targets"], &(&1["channel_id"] == vip_hook.id))
    end

    test "evaluates time windows at the given time", %{
      conn: conn,
      tenant: tenant,
      origin: origin,
      crm: crm
    } do
      {:ok, rule} =
        RoutingRules.create_routing_rule(%{
          name: "business hours",
          tenant_id: tenant.id,
          source_channel_id: origin.id,
          target_channel_ids: [crm.id],
          priority: 1,
          stop_processing: true,
          conditions: %{
            "all" => [
              %{"field" => "time.hour", "op" => "gt", "value" => 8},
              %{"field" => "time.hour", "op" => "lt", "value" => 17}
            ]
          }
        })

      run = fn at ->
        conn
        |> post(~p"/api/v1/routing_rules/dry_run", %{
          "source_channel_id" => origin.id,
          "at" => at,
          "activity" => %{"text" => "hi"}
        })
        |> json_response(200)
        |> get_in(["data", "rules"])
      end

      assert [%{"id" => id, "result" => "matched"}, %{"result" => "skipped"} | _] =
               run.("2026-10-12T10:00:00Z")

      assert id == rule.id
      assert [%{"result" => "not_matched"} | _] = run.("2026-10-12T22:00:00Z")
    end

    test "for a reply from another channel of an existing conversation", %{
      conn: conn,
      tenant: tenant,
      origin: origin
    } do
      console = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, origin)

      data =
        conn
        |> post(~p"/api/v1/routing_rules/dry_run", %{
          "conversation_id" => conversation.id,
          "source_channel_id" => console.id,
          "activity" => %{"text" => "on it", "sender" => "agent-1"}
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["direction"] == "reply"
      assert data["rule_source_channel_id"] == console.id

      assert [
               %{"channel_id" => origin_id, "reason" => "reply_back"},
               %{"channel_id" => console_id, "reason" => "source_hub"}
             ] = data["targets"]

      assert {origin_id, console_id} == {origin.id, console.id}
      assert {[], false} = Activities.page_activities_since(conversation.id, nil)
    end

    test "reports excluded targets, such as the participant's own channel", %{
      conn: conn,
      tenant: tenant
    } do
      # A webhook origin channel with the sender as its participant.
      origin = webhook_channel_fixture(tenant)

      data =
        conn
        |> post(~p"/api/v1/routing_rules/dry_run", %{
          "source_channel_id" => origin.id,
          "participant" => %{"external_id" => "905551112233"},
          "activity" => %{"text" => "hi", "sender" => "905551112233"}
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert [
               %{
                 "reason" => "origin",
                 "excluded" => "echo",
                 "outcome" => "excluded",
                 "payload" => nil
               }
             ] =
               data["targets"]
    end

    test "errors", %{conn: conn, origin: origin} do
      foreign = channel_fixture(tenant_fixture())

      assert conn
             |> post(~p"/api/v1/routing_rules/dry_run", %{
               "source_channel_id" => foreign.id,
               "activity" => %{"text" => "x"}
             })
             |> json_response(404)

      assert %{"error" => "activity is required"} =
               conn
               |> post(~p"/api/v1/routing_rules/dry_run", %{"source_channel_id" => origin.id})
               |> json_response(400)

      assert %{"error" => "source_channel_id or conversation_id is required"} =
               conn
               |> post(~p"/api/v1/routing_rules/dry_run", %{"activity" => %{}})
               |> json_response(400)

      assert %{"errors" => %{"type" => _}} =
               conn
               |> post(~p"/api/v1/routing_rules/dry_run", %{
                 "source_channel_id" => origin.id,
                 "activity" => %{"type" => "bogus"}
               })
               |> json_response(422)

      assert %{"error" => "at must be an ISO 8601 date-time"} =
               conn
               |> post(~p"/api/v1/routing_rules/dry_run", %{
                 "source_channel_id" => origin.id,
                 "at" => "yesterday",
                 "activity" => %{}
               })
               |> json_response(400)
    end
  end
end
