defmodule Converger.Pipeline.MiddlewareIntegrationTest do
  use Converger.DataCase

  alias Converger.Pipeline
  alias Converger.Deliveries

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant, %{type: "echo", mode: "outbound"})
    conversation = conversation_fixture(tenant, channel)
    activity = activity_fixture(tenant, conversation)

    %{tenant: tenant, channel: channel, conversation: conversation, activity: activity}
  end

  describe "Pipeline.deliver/2 with middleware" do
    test "delivers with no transformations", %{activity: activity, channel: channel} do
      assert :ok = Pipeline.deliver(activity, channel)

      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      assert delivery.status == "sent"
    end

    test "applies transformations before delivery", %{tenant: tenant} do
      channel =
        channel_fixture(tenant, %{
          type: "echo",
          mode: "outbound",
          transformations: [
            %{"type" => "add_prefix", "prefix" => "[Test] "}
          ]
        })

      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation, %{text: "Hello"})

      assert :ok = Pipeline.deliver(activity, channel)

      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      assert delivery.status == "sent"
    end

    test "halts delivery when content filter blocks", %{tenant: tenant} do
      channel =
        channel_fixture(tenant, %{
          type: "echo",
          mode: "outbound",
          transformations: [
            %{"type" => "content_filter", "block_patterns" => ["blocked"]}
          ]
        })

      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation, %{text: "This is blocked content"})

      # Creating the activity already ran it through the pipeline once.
      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      assert delivery.status == "failed"
      assert delivery.attempts == 1
      assert delivery.last_error =~ "halted"

      assert {:error, {:halted, _reason}} = Pipeline.deliver(activity, channel)
    end

    test "chains multiple transformations", %{tenant: tenant} do
      channel =
        channel_fixture(tenant, %{
          type: "echo",
          mode: "outbound",
          transformations: [
            %{"type" => "add_prefix", "prefix" => ">> "},
            %{"type" => "add_suffix", "suffix" => " <<"},
            %{"type" => "set_metadata", "values" => %{"tagged" => true}}
          ]
        })

      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation, %{text: "msg"})

      assert :ok = Pipeline.deliver(activity, channel)
    end
  end

  describe "custom middleware" do
    setup do
      Application.put_env(:converger, :extra_middleware, %{
        "channel_name_prefix" => Converger.Test.Middleware.ChannelNamePrefix,
        "crashing" => Converger.Test.Middleware.Crashing
      })

      on_exit(fn -> Application.delete_env(:converger, :extra_middleware) end)
    end

    test "receives the channel struct as second argument", %{tenant: tenant} do
      channel =
        channel_fixture(tenant, %{
          name: "support-desk",
          type: "echo",
          mode: "outbound",
          transformations: [%{"type" => "channel_name_prefix"}]
        })

      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation, %{text: "Hello"})

      assert {:ok, transformed} = Converger.Pipeline.Middleware.run(activity, channel)
      assert transformed.text == "[support-desk] Hello"
    end

    test "an exception halts the chain and dead-letters the delivery", %{tenant: tenant} do
      :telemetry_test.attach_event_handlers(self(), [[:converger, :middleware, :exception]])

      channel =
        channel_fixture(tenant, %{
          type: "echo",
          mode: "outbound",
          transformations: [%{"type" => "crashing"}]
        })

      conversation = conversation_fixture(tenant, channel)

      # Creating the activity runs it through the pipeline once; it must not crash.
      activity = activity_fixture(tenant, conversation, %{text: "Hello"})

      delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)
      assert delivery.status == "failed"
      assert delivery.last_error =~ "middleware crashed: crashing: boom"

      assert {:error, {:halted, "middleware crashed: crashing: boom"}} =
               Pipeline.deliver(activity, channel)

      assert_received {[:converger, :middleware, :exception], _ref, %{count: 1},
                       %{type: "crashing", kind: :error, channel_id: channel_id}}

      assert channel_id == channel.id
    end
  end

  describe "Channel changeset with transformations" do
    test "accepts valid transformations", %{tenant: tenant} do
      channel =
        channel_fixture(tenant, %{
          type: "echo",
          mode: "outbound",
          transformations: [
            %{"type" => "add_prefix", "prefix" => "[!] "},
            %{"type" => "truncate_text", "max_length" => 160}
          ]
        })

      assert channel.transformations == [
               %{"type" => "add_prefix", "prefix" => "[!] "},
               %{"type" => "truncate_text", "max_length" => 160}
             ]
    end

    test "rejects unknown transformation type", %{tenant: tenant} do
      result =
        Converger.Channels.create_channel(%{
          name: "bad-transforms",
          type: "echo",
          mode: "outbound",
          status: "active",
          tenant_id: tenant.id,
          transformations: [%{"type" => "nonexistent"}]
        })

      assert {:error, changeset} = result
      assert errors_on(changeset)[:transformations]
    end

    test "rejects transformation with invalid opts", %{tenant: tenant} do
      result =
        Converger.Channels.create_channel(%{
          name: "bad-opts",
          type: "echo",
          mode: "outbound",
          status: "active",
          tenant_id: tenant.id,
          transformations: [%{"type" => "add_prefix"}]
        })

      assert {:error, changeset} = result
      assert errors_on(changeset)[:transformations]
    end

    test "accepts empty transformations", %{tenant: tenant} do
      channel = channel_fixture(tenant, %{type: "echo", mode: "outbound", transformations: []})
      assert channel.transformations == []
    end
  end
end
