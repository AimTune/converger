defmodule ConvergerWeb.DeliveryControllerTest do
  use ConvergerWeb.ConnCase, async: false
  use Oban.Testing, repo: Converger.Repo

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.{Channels, Deliveries, Repo}
  alias Converger.Deliveries.Delivery
  alias Converger.Workers.ActivityDeliveryWorker

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant)
    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, tenant: tenant, channel: channel}
  end

  defp api(conn, tenant), do: put_req_header(conn, "x-api-key", tenant.api_key)

  # A dead letter on `channel` for a fresh activity on a websocket
  # conversation (so creating the activity enqueues nothing).
  defp dead_letter(tenant, channel, attrs \\ %{}) do
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    activity = activity_fixture(tenant, conversation, %{metadata: %{"password" => "hunter2"}})
    delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)

    {:ok, delivery} =
      delivery
      |> Delivery.changeset(
        Map.merge(%{status: "failed", attempts: 5, last_error: "HTTP 500"}, attrs)
      )
      |> Repo.update()

    delivery
  end

  describe "GET /api/v1/deliveries" do
    test "lists the tenant's dead letters with error, attempts and redacted payload",
         %{conn: conn, tenant: tenant, channel: channel} do
      dead = dead_letter(tenant, channel)
      _sent = dead_letter(tenant, channel, %{status: "sent"})
      other = tenant_fixture()
      _foreign = dead_letter(other, webhook_channel_fixture(other))

      body =
        conn
        |> api(tenant)
        |> get(~p"/api/v1/deliveries?status=failed&channel_id=#{channel.id}")
        |> json_response(200)

      assert [item] = body["data"]
      assert item["id"] == dead.id
      assert item["status"] == "failed"
      assert item["attempts"] == 5
      assert item["last_error"] == "HTTP 500"
      assert item["retry_count"] == 0
      assert item["payload"]["text"] == "some content"
      assert item["payload"]["metadata"]["password"] == "[REDACTED]"
      assert body["meta"]["has_more"] == false
    end

    test "filters by time window", %{conn: conn, tenant: tenant, channel: channel} do
      dead_letter(tenant, channel)

      body =
        conn
        |> api(tenant)
        |> get(~p"/api/v1/deliveries?status=failed&to=2020-01-01")
        |> json_response(200)

      assert body["data"] == []
    end

    test "rejects invalid filters and channel tokens",
         %{conn: conn, tenant: tenant, channel: channel} do
      assert %{"error" => "Invalid status"} =
               conn
               |> api(tenant)
               |> get(~p"/api/v1/deliveries?status=bogus")
               |> json_response(400)

      {:ok, token, _} = Converger.Auth.Token.generate_channel_token(channel)

      conn
      |> put_req_header("x-channel-token", token)
      |> get(~p"/api/v1/deliveries")
      |> json_response(403)
    end
  end

  describe "POST /api/v1/deliveries/:id/retry" do
    test "re-enqueues a dead letter", %{conn: conn, tenant: tenant, channel: channel} do
      dead = dead_letter(tenant, channel)

      Oban.Testing.with_testing_mode(:manual, fn ->
        body =
          conn
          |> api(tenant)
          |> post(~p"/api/v1/deliveries/#{dead.id}/retry")
          |> json_response(202)

        assert %{"status" => "pending", "attempts" => 0, "retry_count" => 1} = body["data"]
        assert body["data"]["retried_by"] == "tenant_api:#{tenant.id}"
        assert_enqueued(worker: ActivityDeliveryWorker, args: %{activity_id: dead.activity_id})
      end)
    end

    test "409 when the delivery is not failed", %{conn: conn, tenant: tenant, channel: channel} do
      sent = dead_letter(tenant, channel, %{status: "sent"})

      assert %{"error" => "not_failed"} =
               conn
               |> api(tenant)
               |> post(~p"/api/v1/deliveries/#{sent.id}/retry")
               |> json_response(409)
    end

    test "404 for another tenant's delivery, 400 for a malformed id",
         %{conn: conn, tenant: tenant} do
      other = tenant_fixture()
      foreign = dead_letter(other, webhook_channel_fixture(other))

      conn
      |> api(tenant)
      |> post(~p"/api/v1/deliveries/#{foreign.id}/retry")
      |> json_response(404)

      assert_error_sent 400, fn ->
        conn |> api(tenant) |> post(~p"/api/v1/deliveries/nope/retry")
      end

      assert Repo.get!(Delivery, foreign.id).status == "failed"
    end

    test "400 when the channel is inactive", %{conn: conn, tenant: tenant, channel: channel} do
      dead = dead_letter(tenant, channel)
      {:ok, _} = Channels.update_channel(channel, %{status: "inactive"})

      conn |> api(tenant) |> post(~p"/api/v1/deliveries/#{dead.id}/retry") |> json_response(400)
    end
  end

  describe "POST /api/v1/channels/:channel_id/deliveries/retry" do
    test "re-enqueues the channel's dead letters", %{conn: conn, tenant: tenant, channel: channel} do
      for _ <- 1..3, do: dead_letter(tenant, channel)
      other_channel = webhook_channel_fixture(tenant)
      untouched = dead_letter(tenant, other_channel)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert %{"data" => %{"retried" => 3, "has_more" => false}} =
                 conn
                 |> api(tenant)
                 |> post(~p"/api/v1/channels/#{channel.id}/deliveries/retry", %{"limit" => "10"})
                 |> json_response(202)

        assert length(all_enqueued(worker: ActivityDeliveryWorker)) == 3
      end)

      assert Repo.get!(Delivery, untouched.id).status == "failed"
    end

    test "404 for another tenant's channel", %{conn: conn, tenant: tenant} do
      other = tenant_fixture()
      foreign_channel = webhook_channel_fixture(other)
      dead_letter(other, foreign_channel)

      conn
      |> api(tenant)
      |> post(~p"/api/v1/channels/#{foreign_channel.id}/deliveries/retry")
      |> json_response(404)
    end
  end
end
