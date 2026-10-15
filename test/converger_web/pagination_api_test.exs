defmodule ConvergerWeb.PaginationApiTest do
  use ConvergerWeb.ChannelCase, async: false
  import Phoenix.ConnTest, except: [connect: 2, connect: 3]
  import Plug.Conn
  import ConvergerWeb.ConnCase, only: [assert_api_error: 3]

  @endpoint ConvergerWeb.Endpoint

  alias Converger.Auth.ConvergerToken
  alias Converger.ConvergerAPI.Watermark
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    activities = for i <- 1..5, do: activity_fixture(tenant, conversation, %{text: "m#{i}"})
    {:ok, token, _claims} = ConvergerToken.generate_conversation_token(channel, conversation.id)

    %{
      tenant: tenant,
      channel: channel,
      conversation: conversation,
      activities: activities,
      token: token
    }
  end

  defp put_limits(overrides) do
    Application.put_env(
      :converger,
      :pagination,
      Keyword.merge(Application.get_env(:converger, :pagination, []), overrides)
    )
  end

  defp converger_get(token, path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(path)
    |> json_response(200)
  end

  defp tenant_get(tenant, path) do
    build_conn()
    |> put_req_header("x-api-key", tenant.api_key)
    |> get(path)
  end

  describe "Converger API GET /conversations/:id/activities" do
    test "pages with limit, watermark and has_more", %{
      token: token,
      conversation: conversation,
      activities: activities
    } do
      path = "/api/v1/converger/conversations/#{conversation.id}/activities"
      ids = Enum.map(activities, & &1.id)

      body = converger_get(token, path <> "?limit=2")
      assert Enum.map(body["activities"], & &1["id"]) == Enum.take(ids, 2)
      assert body["has_more"] == true

      body = converger_get(token, path <> "?limit=2&watermark=#{body["watermark"]}")
      assert Enum.map(body["activities"], & &1["id"]) == Enum.slice(ids, 2, 2)
      assert body["has_more"] == true

      body = converger_get(token, path <> "?limit=2&watermark=#{body["watermark"]}")
      assert Enum.map(body["activities"], & &1["id"]) == [List.last(ids)]
      assert body["has_more"] == false

      # Caught up: empty page, watermark unchanged.
      wm = body["watermark"]
      body = converger_get(token, path <> "?watermark=#{wm}")
      assert body == %{"activities" => [], "watermark" => wm, "has_more" => false}
    end

    test "accepts the integer seq of Protocol v1 as the watermark", %{
      token: token,
      conversation: conversation,
      activities: activities
    } do
      path = "/api/v1/converger/conversations/#{conversation.id}/activities"
      body = converger_get(token, path <> "?watermark=3")

      assert Enum.map(body["activities"], & &1["id"]) ==
               activities |> Enum.drop(3) |> Enum.map(& &1.id)

      assert body["watermark"] == 5
    end

    test "default and max page sizes come from config", %{token: token, conversation: c} do
      put_limits(activity_default_limit: 3, activity_max_limit: 4)
      path = "/api/v1/converger/conversations/#{c.id}/activities"

      assert %{"activities" => a, "has_more" => true} = converger_get(token, path)
      assert length(a) == 3

      assert %{"activities" => a, "has_more" => true} = converger_get(token, path <> "?limit=999")
      assert length(a) == 4

      assert %{"activities" => a} = converger_get(token, path <> "?limit=bogus")
      assert length(a) == 3
    end
  end

  describe "tenant API GET /api/v1/conversations/:id/activities" do
    test "returns data plus meta", %{tenant: tenant, conversation: c, activities: activities} do
      conn = tenant_get(tenant, "/api/v1/conversations/#{c.id}/activities?limit=3")
      body = json_response(conn, 200)

      assert Enum.map(body["data"], & &1["id"]) == activities |> Enum.take(3) |> Enum.map(& &1.id)
      assert %{"has_more" => true, "limit" => 3, "watermark" => wm} = body["meta"]
      assert wm == Enum.at(activities, 2).seq

      body =
        tenant
        |> tenant_get("/api/v1/conversations/#{c.id}/activities?watermark=#{wm}")
        |> json_response(200)

      assert length(body["data"]) == 2
      assert body["meta"]["has_more"] == false
    end

    test "rejects an invalid watermark", %{tenant: tenant, conversation: c} do
      conn = tenant_get(tenant, "/api/v1/conversations/#{c.id}/activities?watermark=%%%")
      assert_api_error(conn, 400, "invalid_watermark")
    end
  end

  describe "tenant API GET /api/v1/conversations" do
    test "keyset pages the tenant's conversations", %{
      tenant: tenant,
      channel: channel,
      conversation: first
    } do
      more = for _ <- 1..2, do: conversation_fixture(tenant, channel)
      _other_tenant = conversation_fixture(tenant_fixture(), channel_fixture(tenant_fixture()))

      body = tenant |> tenant_get("/api/v1/conversations?limit=2") |> json_response(200)
      assert length(body["data"]) == 2
      assert %{"has_more" => true, "next_cursor" => cursor, "limit" => 2} = body["meta"]

      body =
        tenant
        |> tenant_get("/api/v1/conversations?limit=2&cursor=#{cursor}")
        |> json_response(200)

      assert length(body["data"]) == 1
      assert body["meta"] == %{"has_more" => false, "next_cursor" => nil, "limit" => 2}

      all_ids = Enum.map([first | more], & &1.id) |> Enum.sort()

      seen =
        (tenant |> tenant_get("/api/v1/conversations?limit=10") |> json_response(200))["data"]
        |> Enum.map(& &1["id"])

      assert Enum.sort(seen) == all_ids
    end

    test "filters by status and rejects bad params", %{tenant: tenant, conversation: c} do
      {:ok, _} = Converger.Conversations.close_conversation(c)

      body = tenant |> tenant_get("/api/v1/conversations?status=closed") |> json_response(200)
      assert [%{"id" => id}] = body["data"]
      assert id == c.id

      assert tenant |> tenant_get("/api/v1/conversations?cursor=nope") |> json_response(400)
      assert tenant |> tenant_get("/api/v1/conversations?channel_id=nope") |> json_response(400)
    end

    test "requires a tenant API key" do
      assert build_conn() |> get("/api/v1/conversations") |> json_response(401)
    end
  end

  describe "integer watermark (#63, protocol v1 section 6.5)" do
    setup do
      ref = make_ref()
      handler = "watermark-deprecation-#{inspect(ref)}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:converger, :deprecated, :use],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:deprecated, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp legacy_forms(activity) do
      [
        {"integer", Integer.to_string(activity.seq), false},
        {"seq:N base64url", Watermark.encode(activity.seq), true},
        {"legacy activity UUID", Base.url_encode64(activity.id, padding: false), true}
      ]
    end

    test "Converger API emits a JSON number and accepts all three input forms", %{
      token: token,
      conversation: conversation,
      activities: activities
    } do
      path = "/api/v1/converger/conversations/#{conversation.id}/activities"
      third = Enum.at(activities, 2)

      assert %{"watermark" => 2} = converger_get(token, path <> "?limit=2")

      for {form, watermark, deprecated?} <- legacy_forms(third) do
        body = converger_get(token, path <> "?watermark=#{watermark}")

        assert Enum.map(body["activities"], & &1["seq"]) == [4, 5], form
        assert body["watermark"] == 5, form

        if deprecated? do
          assert_received {:deprecated, %{count: 1},
                           %{surface: :opaque_watermark, api: :converger}}
        else
          refute_received {:deprecated, _, %{surface: :opaque_watermark}}
        end
      end
    end

    test "an empty page hands back the client's position as an integer", %{
      token: token,
      conversation: conversation,
      activities: activities
    } do
      path = "/api/v1/converger/conversations/#{conversation.id}/activities"
      last = List.last(activities)

      for {form, watermark, _} <- legacy_forms(last) do
        assert converger_get(token, path <> "?watermark=#{watermark}") ==
                 %{"activities" => [], "watermark" => 5, "has_more" => false},
               form
      end
    end

    test "tenant API emits a JSON number and accepts all three input forms", %{
      tenant: tenant,
      conversation: c,
      activities: activities
    } do
      third = Enum.at(activities, 2)

      for {form, watermark, deprecated?} <- legacy_forms(third) do
        body =
          tenant
          |> tenant_get("/api/v1/conversations/#{c.id}/activities?watermark=#{watermark}")
          |> json_response(200)

        assert Enum.map(body["data"], & &1["seq"]) == [4, 5], form
        assert body["meta"]["watermark"] == 5, form

        if deprecated? do
          assert_received {:deprecated, _, %{surface: :opaque_watermark, api: :tenant}}
        else
          refute_received {:deprecated, _, %{surface: :opaque_watermark}}
        end
      end

      body =
        tenant
        |> tenant_get("/api/v1/conversations/#{c.id}/activities?watermark=#{Watermark.encode(5)}")
        |> json_response(200)

      assert body["meta"]["watermark"] == 5
    end

    test "the legacy Phoenix activitySet keeps the opaque string and accepts an integer join", %{
      token: token,
      conversation: conversation,
      activities: activities
    } do
      {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConvergerChannel,
          "converger:conversation:#{conversation.id}",
          %{"watermark" => Enum.at(activities, 2).seq}
        )

      assert_push "activitySet", %{activities: [_, _], watermark: wm, has_more: false}
      assert wm == Watermark.encode(5)
      refute_received {:deprecated, _, %{surface: :opaque_watermark}}
    end
  end

  describe "WebSocket replay cap" do
    test "Converger channel replays at most ws_replay_limit with has_more", %{
      token: token,
      conversation: conversation,
      activities: [first | rest]
    } do
      put_limits(ws_replay_limit: 2)
      {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConvergerChannel,
          "converger:conversation:#{conversation.id}",
          %{
            "watermark" => Watermark.encode(first.seq)
          }
        )

      expected = rest |> Enum.take(2) |> Enum.map(& &1.id)
      assert_push "activitySet", %{activities: replayed, watermark: wm, has_more: true}
      assert Enum.map(replayed, & &1.id) == expected
      assert wm == Watermark.encode(Enum.at(rest, 1).seq)

      # The rest is fetched over REST from the frame's watermark.
      body =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/converger/conversations/#{conversation.id}/activities?watermark=#{wm}")
        |> json_response(200)

      assert Enum.map(body["activities"], & &1["id"]) == rest |> Enum.drop(2) |> Enum.map(& &1.id)
      assert body["has_more"] == false
    end

    test "Converger channel replay without truncation says has_more: false", %{
      token: token,
      conversation: conversation,
      activities: activities
    } do
      {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConvergerChannel,
          "converger:conversation:#{conversation.id}",
          %{
            "watermark" => Watermark.encode(Enum.at(activities, 2).seq)
          }
        )

      assert_push "activitySet", %{activities: [_, _], has_more: false}
    end
  end
end
