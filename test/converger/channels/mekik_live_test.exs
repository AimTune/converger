defmodule Converger.Channels.MekikLiveTest do
  @moduledoc """
  The `mekik` channel adapter against a real mekik/1 server: the refund demo
  of the mekik repository (`node examples/refund.ts --serve`, on port 8800).

      cd mekik/ts && pnpm install && pnpm build && node examples/refund.ts --serve
      MEKIK_URL=ws://127.0.0.1:8800/ws mix test --only mekik

  An end user's turns are stored on a `websocket` channel routed to the
  `mekik` channel; the approval is answered the way a tapped WhatsApp button
  is (a reply to the interrupt carrying the action), so it reaches the graph
  as `resume`.
  """

  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, RoutingRules}
  alias Converger.Channels.Mekik.{Connections, Relay}

  @moduletag :mekik

  setup do
    webhook = Application.get_env(:converger, :webhook, [])
    Application.put_env(:converger, :webhook, Keyword.put(webhook, :allow_private_targets, true))
    on_exit(fn -> Application.put_env(:converger, :webhook, webhook) end)

    tenant = tenant_fixture()
    widget = channel_fixture(tenant)
    url = System.get_env("MEKIK_URL", "ws://127.0.0.1:8800/ws")
    mekik = channel_fixture(tenant, type: "mekik", config: %{"url" => url})

    {:ok, _rule} =
      RoutingRules.create_routing_rule(%{
        name: "widget to mekik",
        tenant_id: tenant.id,
        source_channel_id: widget.id,
        target_channel_ids: [mekik.id]
      })

    conversation = conversation_fixture(tenant, widget)
    :ok = Relay.watch(mekik.id)
    on_exit(fn -> Connections.stop_channel(mekik.id) end)

    %{tenant: tenant, widget: widget, mekik: mekik, conversation: conversation}
  end

  defp user_turn(ctx, attrs) do
    {:ok, activity} =
      %{
        "type" => "message",
        "sender" => "alice",
        "tenant_id" => ctx.tenant.id,
        "conversation_id" => ctx.conversation.id,
        "source_channel_id" => ctx.widget.id
      }
      |> Map.merge(attrs)
      |> Activities.create_activity()

    activity
  end

  defp wait_for(ctx, fun, attempts \\ 100) do
    activities = Activities.list_activities_since(ctx.conversation.id, nil)

    cond do
      fun.(activities) ->
        activities

      attempts == 0 ->
        flunk("not stored: #{inspect(Enum.map(activities, &{&1.message_type, &1.text}))}")

      true ->
        retry(ctx, fun, attempts)
    end
  end

  defp retry(ctx, fun, attempts) do
    Process.sleep(100)
    wait_for(ctx, fun, attempts - 1)
  end

  test "the refund demo answers, pauses on the approval, and resumes on the tapped button", ctx do
    user_turn(ctx, %{"text" => "ORD-42"})

    activities = wait_for(ctx, fn list -> Enum.any?(list, &(&1.message_type == "interrupt")) end)
    interrupt = Enum.find(activities, &(&1.message_type == "interrupt"))

    assert [%{"label" => "Approve", "value" => approve} | _] =
             interrupt.payload["data"]["actions"]

    assert Enum.any?(activities, &(&1.message_type == "tool_call"))
    assert Enum.any?(activities, &(&1.message_type == "genui"))

    user_turn(ctx, %{
      "text" => "Approve",
      "reply_to_id" => interrupt.id,
      "metadata" => %{"action" => %{"label" => "Approve", "value" => approve}}
    })

    activities =
      wait_for(ctx, fn list ->
        Enum.any?(
          list,
          &(&1.message_type == "text" and &1.payload["data"]["text"] =~ "Refund complete")
        )
      end)

    assert Enum.any?(activities, &(&1.message_type == "interrupt_resolved"))
    refute Activities.interrupt_open?(ctx.conversation.id, interrupt.payload["id"])

    types = Enum.map(activities, &(&1.message_type || "user:" <> &1.text))
    IO.puts("\nstored: " <> Enum.join(types, ", "))
  end
end
