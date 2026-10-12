defmodule Converger.Pipeline.ConditionalRoutingTest do
  # Conditional routing rules (#43, ADR-0046). Mutates :webhook_req_options.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Channels, Conversations, Deliveries, Pipeline, Repo, RoutingRules}
  alias Converger.Conversations.Conversation

  setup do
    previous = Application.get_env(:converger, :webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :webhook_req_options, previous),
        else: Application.delete_env(:converger, :webhook_req_options)
    end)

    Application.put_env(:converger, :webhook_req_options, plug: {Req.Test, __MODULE__})
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [route] = Plug.Conn.get_req_header(conn, "x-route")
      send(test_pid, {:webhook, route, Jason.decode!(body)})
      Req.Test.json(conn, %{ok: true})
    end)

    tenant = tenant_fixture()
    origin = channel_fixture(tenant)
    vip_hook = hook(tenant, "vip")
    all_hook = hook(tenant, "all")

    {:ok, vip_rule} =
      RoutingRules.create_routing_rule(%{
        name: "vip to priority webhook",
        tenant_id: tenant.id,
        source_channel_id: origin.id,
        target_channel_ids: [vip_hook.id],
        conditions: [%{field: "metadata.vip", op: "eq", value: true}],
        transformations: [%{"type" => "add_prefix", "prefix" => "[VIP] "}],
        priority: 10
      })

    {:ok, all_rule} =
      RoutingRules.create_routing_rule(%{
        name: "everything to crm",
        tenant_id: tenant.id,
        source_channel_id: origin.id,
        target_channel_ids: [all_hook.id]
      })

    conversation = conversation_fixture(tenant, origin)

    %{
      tenant: tenant,
      origin: origin,
      vip_hook: vip_hook,
      all_hook: all_hook,
      vip_rule: vip_rule,
      all_rule: all_rule,
      conversation: conversation
    }
  end

  defp hook(tenant, route) do
    webhook_channel_fixture(tenant, %{
      mode: "outbound",
      config: %{"url" => "https://#{route}.example.com/hook", "headers" => %{"x-route" => route}}
    })
  end

  defp post(conversation, origin, text, metadata \\ %{}) do
    {:ok, activity} =
      Activities.create_activity(%{
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id,
        "sender" => "user-1",
        "text" => text,
        "metadata" => metadata,
        "source_channel_id" => origin.id
      })

    activity
  end

  describe "a metadata.vip == true rule" do
    test "routes to the priority webhook only for matching activities, with its transformations",
         %{conversation: conversation, origin: origin, vip_hook: vip_hook, all_hook: all_hook} do
      vip = post(conversation, origin, "upgrade me", %{"vip" => true})

      assert_received {:webhook, "vip", %{"text" => "[VIP] upgrade me"}}
      # The rule's transformations apply only to the rule's own targets.
      assert_received {:webhook, "all", %{"text" => "upgrade me"}}

      assert %{status: "sent"} =
               Deliveries.get_delivery_for_activity_and_channel(vip.id, vip_hook.id)

      regular = post(conversation, origin, "just a question", %{"vip" => false})

      assert_received {:webhook, "all", %{"text" => "just a question"}}
      refute_received {:webhook, "vip", _}
      assert Deliveries.get_delivery_for_activity_and_channel(regular.id, vip_hook.id) == nil
      assert Deliveries.get_delivery_for_activity_and_channel(regular.id, all_hook.id)

      untagged = post(conversation, origin, "no metadata")
      refute_received {:webhook, "vip", _}
      assert Deliveries.get_delivery_for_activity_and_channel(untagged.id, vip_hook.id) == nil
    end

    test "rule transformations run after the target channel's own middleware", %{
      conversation: conversation,
      origin: origin,
      vip_hook: vip_hook
    } do
      {:ok, _} =
        Channels.update_channel(vip_hook, %{
          transformations: [%{"type" => "add_suffix", "suffix" => " (channel)"}]
        })

      post(conversation, origin, "hi", %{"vip" => true})
      assert_received {:webhook, "vip", %{"text" => "[VIP] hi (channel)"}}
    end

    test "a halting rule transformation dead-letters that target only", %{
      conversation: conversation,
      origin: origin,
      vip_rule: vip_rule,
      vip_hook: vip_hook
    } do
      {:ok, _} =
        RoutingRules.update_routing_rule(vip_rule, %{
          transformations: [%{"type" => "content_filter", "block_patterns" => ["secret"]}]
        })

      activity = post(conversation, origin, "a secret", %{"vip" => true})

      refute_received {:webhook, "vip", _}
      assert_received {:webhook, "all", _}

      assert %{status: "failed", last_error: "halted: " <> _} =
               Deliveries.get_delivery_for_activity_and_channel(activity.id, vip_hook.id)
    end
  end

  describe "priority and stop_processing" do
    test "rules are evaluated in priority order and a matching stop rule ends evaluation", %{
      conversation: conversation,
      origin: origin,
      vip_rule: vip_rule,
      all_rule: all_rule
    } do
      {:ok, vip_rule} = RoutingRules.update_routing_rule(vip_rule, %{stop_processing: true})

      vip = post(conversation, origin, "vip only", %{"vip" => true})
      assert_received {:webhook, "vip", _}
      refute_received {:webhook, "all", _}

      route = RoutingRules.route(vip, Conversations.get_conversation!(conversation.id))

      assert [{%{id: first}, :matched}, {%{id: second}, :skipped}] = route.evaluations
      assert {first, second} == {vip_rule.id, all_rule.id}

      # A non-matching stop rule does not stop anything.
      post(conversation, origin, "regular", %{"vip" => false})
      assert_received {:webhook, "all", _}

      # Priority, not name, decides the order.
      {:ok, _} = RoutingRules.update_routing_rule(all_rule, %{priority: 1})
      route = RoutingRules.route(vip, Conversations.get_conversation!(conversation.id))
      assert [{%{id: ^second}, :matched}, {%{id: ^first}, :matched}] = route.evaluations
    end
  end

  describe "reply-back routing" do
    test "an activity from a target channel goes back to the origin only, unless a rule of that channel says otherwise",
         %{tenant: tenant, conversation: conversation, origin: origin, all_hook: all_hook} do
      console = channel_fixture(tenant)

      {:ok, _} =
        RoutingRules.create_routing_rule(%{
          name: "widget to console",
          tenant_id: tenant.id,
          source_channel_id: origin.id,
          target_channel_ids: [console.id]
        })

      inbound = post(conversation, origin, "hello")
      assert_received {:webhook, "all", _}

      assert [origin.id, all_hook.id, console.id] --
               Enum.map(Pipeline.resolve_delivery_channels(inbound), & &1.id) == []

      {:ok, reply} =
        Activities.create_activity(%{
          "tenant_id" => tenant.id,
          "conversation_id" => conversation.id,
          "sender" => "agent-1",
          "text" => "hi there",
          "source_channel_id" => console.id
        })

      # Back to the origin (and the replying websocket hub), not to the CRM.
      refute_received {:webhook, "all", _}

      assert Enum.map(Pipeline.resolve_delivery_channels(reply), & &1.id) == [
               origin.id,
               console.id
             ]

      assert Deliveries.get_delivery_for_activity_and_channel(reply.id, all_hook.id) == nil
      assert Deliveries.get_delivery_for_activity_and_channel(reply.id, origin.id)

      # A rule of the replying channel adds targets.
      {:ok, _} =
        RoutingRules.create_routing_rule(%{
          name: "console replies to crm",
          tenant_id: tenant.id,
          source_channel_id: console.id,
          target_channel_ids: [all_hook.id]
        })

      {:ok, _} =
        Activities.create_activity(%{
          "tenant_id" => tenant.id,
          "conversation_id" => conversation.id,
          "sender" => "agent-1",
          "text" => "audited",
          "source_channel_id" => console.id
        })

      assert_received {:webhook, "all", %{"text" => "audited"}}

      # The conversation spans the channels it was routed to and written from.
      roles =
        conversation.id
        |> Conversations.list_conversation_channels()
        |> Map.new(&{&1.channel_id, &1.role})

      assert roles == %{
               origin.id => "origin",
               all_hook.id => "target",
               console.id => "target"
             }
    end

    test "activities without a source channel keep the fan-out of the origin's rules", %{
      tenant: tenant,
      conversation: conversation
    } do
      {:ok, _} =
        Activities.create_activity(%{
          "tenant_id" => tenant.id,
          "conversation_id" => conversation.id,
          "sender" => "agent-7",
          "text" => "posted with the tenant API"
        })

      assert_received {:webhook, "all", %{"text" => "posted with the tenant API"}}
    end

    test "a conversation without a backfilled origin falls back to its channel", %{
      conversation: conversation,
      origin: origin
    } do
      Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
        set: [origin_channel_id: nil]
      )

      post(conversation, origin, "legacy row")
      assert_received {:webhook, "all", _}
    end
  end

  describe "conversations" do
    test "record their origin channel and participant", %{tenant: tenant, origin: origin} do
      conversation = conversation_fixture(tenant, origin)
      assert conversation.origin_channel_id == origin.id
      assert Conversation.origin_channel_id(conversation) == origin.id

      assert [%{channel_id: channel_id, role: "origin"}] =
               Conversations.list_conversation_channels(conversation.id)

      assert channel_id == origin.id

      # origin_channel_id is never cast.
      other = channel_fixture(tenant)

      {:ok, updated} =
        Conversations.update_conversation(conversation, %{origin_channel_id: other.id})

      assert updated.origin_channel_id == origin.id
    end
  end
end
