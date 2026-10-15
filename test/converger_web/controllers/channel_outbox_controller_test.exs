defmodule ConvergerWeb.ChannelOutboxControllerTest do
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Ecto.Query, only: [from: 2]

  alias Converger.{Channels, Deliveries, Repo}
  alias Converger.Channels.{Adapter, Outbox}
  alias Converger.Deliveries.Delivery

  setup %{conn: conn} do
    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "pull-#{System.unique_integer([:positive])}",
        type: "http_pull",
        mode: "outbound",
        status: "active",
        tenant_id: tenant.id
      })

    conversation = conversation_fixture(tenant, channel)

    %{
      conn: put_req_header(conn, "x-api-key", tenant.api_key),
      tenant: tenant,
      channel: channel,
      conversation: conversation
    }
  end

  # A new request with the tenant's API key (recycle/1 keeps only cookies).
  defp fresh(conn),
    do: put_req_header(build_conn(), "x-api-key", hd(get_req_header(conn, "x-api-key")))

  defp add(tenant, conversation, text), do: activity_fixture(tenant, conversation, %{text: text})

  defp poll(conn, channel, params \\ %{}) do
    conn
    |> fresh()
    |> get(~p"/api/v1/channels/#{channel.id}/outbox", params)
    |> json_response(200)
  end

  test "is an outbound-only built-in" do
    assert {:ok, _} = Adapter.adapter_for("http_pull")
    assert Adapter.supported_modes("http_pull") == ~w(outbound)
    assert Adapter.capability?("http_pull", :lifecycle_events)
  end

  test "deliveries stay pending in the outbox until a watermark acknowledges them", %{
    conn: conn,
    tenant: tenant,
    channel: channel,
    conversation: conversation
  } do
    a1 = add(tenant, conversation, "one")
    a2 = add(tenant, conversation, "two")
    a3 = add(tenant, conversation, "three")

    assert Repo.all(Delivery) |> Enum.map(& &1.status) |> Enum.uniq() == ["pending"]

    page = poll(conn, channel, %{"limit" => "2"})
    assert Enum.map(page["data"], & &1["activity"]["text"]) == ["one", "two"]
    assert Enum.map(page["data"], & &1["activity"]["id"]) == [a1.id, a2.id]
    assert page["has_more"] == true
    assert page["acknowledged"] == 0
    refute hd(page["data"])["served_before"]

    # Not acknowledged: the same page again, marked as served before.
    again = poll(conn, channel, %{"limit" => "2"})
    assert Enum.map(again["data"], & &1["activity"]["id"]) == [a1.id, a2.id]
    assert hd(again["data"])["served_before"]
    assert again["watermark"] == page["watermark"]

    next = poll(conn, channel, %{"limit" => "2", "watermark" => page["watermark"]})
    assert next["acknowledged"] == 2
    assert Enum.map(next["data"], & &1["activity"]["id"]) == [a3.id]
    assert next["has_more"] == false

    assert Deliveries.get_delivery_for_activity_and_channel(a1.id, channel.id).status == "sent"
    assert Deliveries.get_delivery_for_activity_and_channel(a3.id, channel.id).status == "pending"

    done = poll(conn, channel, %{"watermark" => next["watermark"]})
    assert done["data"] == []
    assert done["acknowledged"] == 1
    # An empty page keeps the watermark the consumer sent.
    assert done["watermark"] == next["watermark"]
  end

  test "a watermark never acknowledges an item that was not served", %{
    conn: conn,
    tenant: tenant,
    channel: channel,
    conversation: conversation
  } do
    add(tenant, conversation, "one")
    page = poll(conn, channel)
    [served] = page["data"]

    # A delivery committed late, with a position before the watermark.
    late = add(tenant, conversation, "late")
    delivery = Deliveries.get_delivery_for_activity_and_channel(late.id, channel.id)
    {:ok, served_at, 0} = DateTime.from_iso8601(served["queued_at"])
    earlier = DateTime.add(served_at, -1, :second)

    Repo.update_all(
      from(d in Delivery, where: d.id == ^delivery.id),
      set: [inserted_at: earlier]
    )

    next = poll(conn, channel, %{"watermark" => page["watermark"]})
    assert next["acknowledged"] == 1
    assert Enum.map(next["data"], & &1["activity"]["text"]) == ["late"]
  end

  test "POST /outbox/ack acknowledges without fetching", %{
    conn: conn,
    tenant: tenant,
    channel: channel,
    conversation: conversation
  } do
    add(tenant, conversation, "one")
    page = poll(conn, channel)

    conn =
      conn
      |> fresh()
      |> post(~p"/api/v1/channels/#{channel.id}/outbox/ack", %{"watermark" => page["watermark"]})

    assert json_response(conn, 200) == %{"acknowledged" => 1}
    assert poll(conn, channel)["data"] == []
  end

  test "middleware output is what the outbox serves", %{tenant: tenant} do
    {:ok, channel} =
      Channels.create_channel(%{
        name: "pull-mw-#{System.unique_integer([:positive])}",
        type: "http_pull",
        mode: "outbound",
        status: "active",
        tenant_id: tenant.id,
        transformations: [%{"type" => "add_prefix", "prefix" => "[Pull] "}]
      })

    conversation = conversation_fixture(tenant, channel)
    add(tenant, conversation, "hi")

    {[delivery], false} = Deliveries.outbox_page(channel.id, 10)
    assert delivery.metadata["outbox"]["text"] == "[Pull] hi"
  end

  test "errors", %{conn: conn, tenant: tenant, channel: channel} do
    conn1 =
      conn |> fresh() |> get(~p"/api/v1/channels/#{channel.id}/outbox", %{"watermark" => "nope"})

    assert assert_api_error(conn1, 400, "invalid_watermark")["message"] =~ "watermark"

    conn2 = conn |> fresh() |> get(~p"/api/v1/channels/#{channel.id}/outbox", %{"limit" => "0"})
    assert assert_api_error(conn2, 400, "bad_request")["message"] =~ "limit"

    other = channel_fixture(tenant)
    conn3 = conn |> fresh() |> get(~p"/api/v1/channels/#{other.id}/outbox")
    assert assert_api_error(conn3, 422, "unsupported_channel_type")["message"] =~ "no outbox"

    conn4 = build_conn() |> get(~p"/api/v1/channels/#{channel.id}/outbox")
    assert_api_error(conn4, 401, "unauthorized")

    stranger = tenant_fixture()

    {404, _headers, body} =
      assert_error_sent 404, fn ->
        build_conn()
        |> put_req_header("x-api-key", stranger.api_key)
        |> get(~p"/api/v1/channels/#{channel.id}/outbox")
      end

    assert %{"error" => %{"code" => "not_found", "message" => _, "details" => nil}} =
             Jason.decode!(body)
  end

  test "watermarks round-trip" do
    at = DateTime.utc_now()
    id = Ecto.UUID.generate()

    assert {:ok, {^at, ^id}} =
             Outbox.decode_watermark(Outbox.encode_watermark(%{inserted_at: at, id: id}))

    assert {:ok, nil} = Outbox.decode_watermark(nil)
    assert {:error, :invalid_watermark} = Outbox.decode_watermark(Base.url_encode64("v1:x:y"))
  end
end
