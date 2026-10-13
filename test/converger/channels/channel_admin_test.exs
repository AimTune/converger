defmodule Converger.Channels.ChannelAdminTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.HealthCheckFixtures

  alias Converger.AuditLogs.AuditLog
  alias Converger.Channels
  alias Converger.Channels.Health
  alias Converger.Deliveries
  alias Converger.Repo

  @actor %{type: "admin", id: "admin@example.com"}

  describe "paginate_channels/2" do
    setup do
      tenant = tenant_fixture()
      other = tenant_fixture()

      a = channel_fixture(tenant, name: "Support Desk", type: "echo") |> created(30)
      b = channel_fixture(tenant, name: "Sales") |> created(20)
      c = channel_fixture(other, name: "Support Other", mode: "inbound") |> created(10)

      %{tenant: tenant, other: other, a: a, b: b, c: c}
    end

    test "searches name and type, case-insensitively", %{a: a, c: c, b: b} do
      {:ok, page} = Channels.paginate_channels(%{"q" => "support"})
      assert ids(page) |> Enum.sort() == Enum.sort([a.id, c.id])

      {:ok, page} = Channels.paginate_channels(%{"q" => "WEBSOCK"})
      assert ids(page) |> Enum.sort() == Enum.sort([b.id, c.id])

      {:ok, page} = Channels.paginate_channels(%{"q" => "%"})
      assert ids(page) == []
    end

    test "filters by tenant, mode and status", %{tenant: t, a: a, b: b, c: c} do
      {:ok, page} = Channels.paginate_channels(%{"tenant_id" => t.id})
      assert Enum.sort(ids(page)) == Enum.sort([a.id, b.id])

      {:ok, page} = Channels.paginate_channels(%{"tenant_id" => "not-a-uuid"})
      assert ids(page) == []

      {:ok, page} = Channels.paginate_channels(%{mode: "inbound"})
      assert ids(page) == [c.id]

      {:ok, _} = Channels.update_channel(b, %{status: "inactive"})
      {:ok, page} = Channels.paginate_channels(%{"status" => "inactive"})
      assert ids(page) == [b.id]
    end

    test "sorts and pages with a cursor", %{a: a, b: b, c: c} do
      {:ok, page} = Channels.paginate_channels(%{}, limit: 2, direction: :asc)
      assert ids(page) == [a.id, b.id]
      assert page.has_more

      {:ok, page} =
        Channels.paginate_channels(%{}, limit: 2, direction: :asc, cursor: page.next_cursor)

      assert ids(page) == [c.id]
      refute page.has_more

      {:ok, page} = Channels.paginate_channels(%{}, direction: :desc)
      assert ids(page) == [c.id, b.id, a.id]
    end
  end

  describe "rotate_secret/2" do
    test "replaces the secret and its hash, audited without the secret" do
      channel = channel_fixture(tenant_fixture())
      old_secret = channel.secret

      assert {:ok, rotated} = Channels.rotate_secret(channel, @actor)
      assert rotated.secret != old_secret
      assert rotated.secret_hash != channel.secret_hash

      assert Channels.get_channel_by_secret(old_secret) == nil
      assert Channels.get_channel_by_secret(rotated.secret).id == channel.id
      assert {:error, :unauthorized} = Channels.validate_channel_secret(channel.id, old_secret)

      log = Repo.get_by!(AuditLog, resource_id: channel.id, action: "rotate_secret")
      assert log.actor_id == @actor.id
      assert log.changes["rotated"] == ["secret"]
      encoded = Jason.encode!(log.changes)
      refute encoded =~ old_secret
      refute encoded =~ rotated.secret
    end
  end

  describe "send_test_message/3" do
    test "posts an activity delivered to the channel, reusing the test conversation" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant, type: "echo")

      assert {:ok, %{conversation: conversation, activity: activity, delivery: delivery}} =
               Channels.send_test_message(channel, "  hello  ", @actor)

      assert activity.text == "hello"
      assert activity.conversation_id == conversation.id
      assert conversation.channel_id == channel.id
      assert conversation.metadata["converger_test"] == true
      assert delivery.channel_id == channel.id
      assert delivery.status == "sent"

      assert Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)

      assert {:ok, %{conversation: again}} = Channels.send_test_message(channel, "again", @actor)
      assert again.id == conversation.id

      logs =
        Repo.all(
          from(l in AuditLog,
            where: l.resource_id == ^channel.id and l.action == "send_test_message"
          )
        )

      assert Enum.any?(logs, &(&1.changes["after"]["test_message"]["activity_id"] == activity.id))
    end

    test "rejects inbound-only, inactive channels and blank text" do
      tenant = tenant_fixture()
      inbound = channel_fixture(tenant, mode: "inbound")
      assert {:error, :inbound_only} = Channels.send_test_message(inbound, "hi", @actor)

      echo = channel_fixture(tenant, type: "echo", status: "inactive")
      assert {:error, :channel_inactive} = Channels.send_test_message(echo, "hi", @actor)

      {:ok, echo} = Channels.update_channel(echo, %{status: "active"})
      assert {:error, :blank_text} = Channels.send_test_message(echo, "   ", @actor)
    end
  end

  describe "Health.list_health_history_map/2" do
    test "returns the newest checks of each channel, newest first, capped" do
      tenant = tenant_fixture()
      a = channel_fixture(tenant)
      b = channel_fixture(tenant)
      now = DateTime.utc_now()

      for i <- 1..4 do
        health_check_fixture(a, %{
          failure_rate: i / 10,
          checked_at: DateTime.add(now, i, :second)
        })
      end

      health_check_fixture(b, %{failure_rate: 0.5})

      map = Health.list_health_history_map([a.id, b.id], 3)
      assert Enum.map(map[a.id], & &1.failure_rate) == [0.4, 0.3, 0.2]
      assert length(map[b.id]) == 1
      assert Health.list_health_history_map([]) == %{}
    end
  end

  defp ids(page), do: Enum.map(page.entries, & &1.id)

  # Distinct creation times: on some platforms consecutive inserts can share
  # a timestamp, which would make the (inserted_at, id) order random.
  defp created(channel, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    Repo.update_all(
      from(c in Converger.Channels.Channel, where: c.id == ^channel.id),
      set: [inserted_at: at]
    )

    channel
  end
end
