defmodule ConvergerWeb.ConvergerChannelTest do
  use ConvergerWeb.ChannelCase
  import Phoenix.ConnTest, except: [connect: 2, connect: 3]
  import Plug.Conn, except: [push: 3]

  @endpoint ConvergerWeb.Endpoint

  # postActivity replies after the pipeline ran (inline deliveries, echo).
  @reply_timeout 1_000

  alias Converger.Auth.ConvergerToken
  alias Converger.ConvergerAPI.Watermark
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    previous_dir = Application.get_env(:converger, :upload_dir)

    upload_dir =
      Path.join(System.tmp_dir!(), "converger_test_uploads_#{System.unique_integer([:positive])}")

    Application.put_env(:converger, :upload_dir, upload_dir)

    on_exit(fn ->
      File.rm_rf(upload_dir)

      if previous_dir,
        do: Application.put_env(:converger, :upload_dir, previous_dir),
        else: Application.delete_env(:converger, :upload_dir)
    end)

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {:ok, token, _claims} = ConvergerToken.generate_conversation_token(channel, conversation.id)

    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:conversation:#{conversation.id}")

    %{socket: socket, conversation: conversation, token: token}
  end

  defp api_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
  end

  # Push payloads are maps with atom keys and structs; compare in wire format.
  defp wire(term), do: term |> Jason.encode!() |> Jason.decode!()

  test "WS frame for an upload activity contains the attachment list", %{
    conversation: conversation,
    token: token
  } do
    upload = %Plug.Upload{
      path: write_tmp_file("hello attachment"),
      filename: "note.txt",
      content_type: "text/plain"
    }

    conn =
      token
      |> api_conn()
      |> post("/api/v1/converger/conversations/#{conversation.id}/upload", %{
        "file" => upload,
        "activity" => Jason.encode!(%{"text" => "see file", "channelData" => %{"k" => "v"}})
      })

    assert %{"id" => id} = json_response(conn, 200)

    assert_push "activitySet", %{activities: [frame], watermark: _}
    frame = wire(frame)

    assert frame["id"] == id
    assert frame["type"] == "message"
    assert frame["text"] == "see file"
    assert frame["channelData"] == %{"k" => "v"}

    assert [%{"name" => "note.txt", "contentType" => "text/plain", "contentUrl" => url}] =
             frame["attachments"]

    assert is_binary(url)
  end

  test "closing the conversation pushes a conversationUpdate activitySet", %{
    conversation: conversation,
    token: token
  } do
    conn =
      token
      |> api_conn()
      |> post("/api/v1/converger/conversations/#{conversation.id}/close")

    assert json_response(conn, 200)["status"] == "closed"

    assert_push "activitySet", %{activities: [frame]}
    frame = wire(frame)
    assert frame["type"] == "conversationUpdate"
    assert frame["channelData"]["event"] == "conversation_closed"
  end

  test "REST GET activities and WS activitySet produce identical activity objects", %{
    conversation: conversation,
    token: token
  } do
    conn =
      token
      |> api_conn()
      |> post("/api/v1/converger/conversations/#{conversation.id}/activities", %{
        "type" => "event",
        "text" => "hi",
        "from" => %{"id" => "user-42"},
        "attachments" => [%{"contentType" => "image/png", "contentUrl" => "https://x/y.png"}],
        "channelData" => %{"locale" => "tr-TR"}
      })

    assert %{"id" => id} = json_response(conn, 200)

    assert_push "activitySet", %{activities: [ws_activity]}

    rest =
      token
      |> api_conn()
      |> get("/api/v1/converger/conversations/#{conversation.id}/activities")
      |> json_response(200)

    assert [rest_activity] = rest["activities"]
    assert rest_activity["id"] == id
    assert rest_activity["type"] == "event"
    assert wire(ws_activity) == rest_activity
  end

  test "watermark replay on join uses the same activity shape", %{
    conversation: conversation,
    token: token
  } do
    {:ok, first} =
      Converger.Activities.create_activity(%{
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id,
        "sender" => "user-1",
        "text" => "first"
      })

    {:ok, second} =
      Converger.Activities.create_activity(%{
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id,
        "sender" => "user-1",
        "text" => "second",
        "attachments" => [%{"contentType" => "image/png", "contentUrl" => "https://x/z.png"}]
      })

    # Consume the live pushes to the socket joined in setup.
    first_id = first.id
    second_id = second.id
    assert_push "activitySet", %{activities: [%{id: ^first_id}]}
    assert_push "activitySet", %{activities: [%{id: ^second_id}]}

    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, _socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:conversation:#{conversation.id}", %{
        "watermark" => Watermark.encode(first.seq)
      })

    assert_push "activitySet", %{activities: [replayed]}

    assert wire(replayed) ==
             wire(ConvergerWeb.ConvergerAPI.ActivityJSON.activity_data(second))

    assert [%{"contentUrl" => "https://x/z.png"}] = wire(replayed)["attachments"]
  end

  defp join_as(channel, conversation, opts) do
    {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, conversation.id, opts)
    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:conversation:#{conversation.id}")

    socket
  end

  defp stored(conversation),
    do: Converger.Activities.list_activities_for_conversation(conversation.id)

  describe "postActivity" do
    test "persists the activity, replies with id/seq/watermark and pushes the activitySet", %{
      socket: socket,
      conversation: conversation
    } do
      ref =
        push(socket, "postActivity", %{
          "type" => "message",
          "text" => "hello",
          "channelData" => %{"k" => "v"},
          "attachments" => [%{"contentType" => "image/png", "contentUrl" => "https://x/a.png"}]
        })

      assert_reply ref, :ok, %{id: id, seq: 1, watermark: watermark}, @reply_timeout
      assert {:ok, {:seq, 1}} = Watermark.decode(watermark)

      assert_push "activitySet", %{activities: [frame], watermark: ^watermark}
      frame = wire(frame)
      assert frame["id"] == id
      assert frame["text"] == "hello"
      assert frame["channelData"] == %{"k" => "v"}

      assert [%{id: ^id, metadata: %{"k" => "v"}}] = stored(conversation)
    end

    test "client fields only: sender, seq and timestamps are not client-settable", %{
      socket: socket,
      conversation: conversation
    } do
      ref =
        push(socket, "postActivity", %{
          "text" => "spoof",
          "sender" => "bot",
          "seq" => 99,
          "inserted_at" => "2001-01-01T00:00:00Z"
        })

      assert_reply ref, :ok, %{seq: 1}, @reply_timeout

      [activity] = stored(conversation)
      assert activity.sender == "user"
      assert activity.inserted_at.year >= 2026
    end

    test "the verified user_id is the sender; from.id cannot override it", %{
      conversation: conversation
    } do
      channel = Converger.Channels.get_channel!(conversation.channel_id)
      socket = join_as(channel, conversation, user_id: "alice")

      ref = push(socket, "postActivity", %{"text" => "hi", "from" => %{"id" => "bot"}})
      assert_reply ref, :ok, %{}, @reply_timeout

      assert [%{sender: "alice"}] = stored(conversation)
    end

    test "without a user_id claim from.id names the sender", %{
      socket: socket,
      conversation: conversation
    } do
      ref = push(socket, "postActivity", %{"text" => "hi", "from" => %{"id" => "user-42"}})
      assert_reply ref, :ok, %{}, @reply_timeout

      assert [%{sender: "user-42"}] = stored(conversation)
    end

    test "invalid payloads reply with field-level errors", %{socket: socket} do
      ref = push(socket, "postActivity", %{"text" => "x", "type" => "bogus"})
      assert_reply ref, :error, %{reason: "invalid_activity", errors: %{type: [_]}}

      ref = push(socket, "postActivity", "not a map")
      assert_reply ref, :error, %{reason: "invalid_activity"}
    end

    test "a closed conversation replies conversation_closed", %{
      socket: socket,
      conversation: conversation
    } do
      {:ok, _} = Converger.Conversations.close_conversation(conversation)
      assert_push "activitySet", %{activities: [%{type: "conversationUpdate"}]}

      ref = push(socket, "postActivity", %{"text" => "too late"})
      assert_reply ref, :error, %{reason: "conversation_closed"}

      assert [%{type: "conversationUpdate"}] = stored(conversation)
    end

    test "a token for another conversation cannot join (and so cannot post)", %{
      conversation: conversation
    } do
      channel = Converger.Channels.get_channel!(conversation.channel_id)
      tenant = Converger.Tenants.get_tenant!(conversation.tenant_id)
      other = conversation_fixture(tenant, channel)

      {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, other.id)
      {:ok, socket} = connect(ConvergerSocket, %{"token" => token})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 ConvergerChannel,
                 "converger:conversation:#{conversation.id}"
               )
    end

    test "is rate limited with the tenant's activity_create bucket", %{
      socket: socket,
      conversation: conversation
    } do
      tenant = Converger.Tenants.get_tenant!(conversation.tenant_id)

      {:ok, _} =
        Converger.Tenants.update_tenant_limits(tenant, %{
          "activity_create" => %{"limit" => 1, "scale_ms" => 60_000}
        })

      ref = push(socket, "postActivity", %{"text" => "one"})
      assert_reply ref, :ok, %{}, @reply_timeout

      ref = push(socket, "postActivity", %{"text" => "two"})
      assert_reply ref, :error, %{reason: "rate_limited", retry_after_ms: ms}
      assert ms > 0

      assert [%{text: "one"}] = stored(conversation)
    end
  end

  describe "postActivity clientId" do
    test "a re-send returns the stored activity instead of a duplicate", %{
      socket: socket,
      conversation: conversation
    } do
      ref = push(socket, "postActivity", %{"text" => "once", "clientId" => "c-1"})
      assert_reply ref, :ok, %{id: id, seq: 1}, @reply_timeout

      # e.g. the client lost the connection before the reply and re-sends
      ref = push(socket, "postActivity", %{"text" => "once", "clientId" => "c-1"})
      assert_reply ref, :ok, %{id: ^id, seq: 1}, @reply_timeout

      assert [%{id: ^id, idempotency_key: "ws:user:c-1"}] = stored(conversation)
    end

    test "survives a reconnect (new socket, same user)", %{conversation: conversation} do
      channel = Converger.Channels.get_channel!(conversation.channel_id)

      socket = join_as(channel, conversation, user_id: "alice")
      ref = push(socket, "postActivity", %{"text" => "once", "clientId" => "c-2"})
      assert_reply ref, :ok, %{id: id}, @reply_timeout

      socket = join_as(channel, conversation, user_id: "alice")
      ref = push(socket, "postActivity", %{"text" => "once", "clientId" => "c-2"})
      assert_reply ref, :ok, %{id: ^id}, @reply_timeout

      assert [_] = stored(conversation)
    end

    test "keys of different senders and of the REST API do not collide", %{
      conversation: conversation
    } do
      channel = Converger.Channels.get_channel!(conversation.channel_id)

      {:ok, rest} =
        Converger.Activities.create_client_activity(%{"text" => "rest"}, %{
          tenant_id: conversation.tenant_id,
          conversation_id: conversation.id,
          sender: "bot",
          idempotency_key: "shared"
        })

      ids =
        for user <- ~w(alice bob) do
          socket = join_as(channel, conversation, user_id: user)
          ref = push(socket, "postActivity", %{"text" => user, "clientId" => "shared"})
          assert_reply ref, :ok, %{id: id}, @reply_timeout
          id
        end

      assert [rest.id | ids] |> Enum.uniq() |> length() == 3
      assert ~w(rest alice bob) == conversation |> stored() |> Enum.map(& &1.text)
    end

    test "rejects an invalid clientId", %{socket: socket, conversation: conversation} do
      for id <- ["", 42, "has space", String.duplicate("k", 129)] do
        ref = push(socket, "postActivity", %{"text" => "x", "clientId" => id})
        assert_reply ref, :error, %{reason: "invalid_activity", errors: %{clientId: [_]}}
      end

      ref = push(socket, "postActivity", %{"text" => "no key", "clientId" => nil})
      assert_reply ref, :ok, %{}, @reply_timeout

      assert [%{idempotency_key: nil}] = stored(conversation)
    end
  end

  test "an echo channel echoes a postActivity exactly once" do
    tenant = tenant_fixture()
    echo_channel = channel_fixture(tenant, %{type: "echo"})
    conversation = conversation_fixture(tenant, echo_channel)
    socket = join_as(echo_channel, conversation, user_id: "user-echo")

    ref = push(socket, "postActivity", %{"text" => "echo me"})
    assert_reply ref, :ok, %{}, @reply_timeout

    assert_push "activitySet", %{activities: [%{text: "echo me", from: %{id: "user-echo"}}]}
    assert_push "activitySet", %{activities: [%{text: "echo me", from: %{id: "bot"}}]}
    refute_push "activitySet", _
    assert length(stored(conversation)) == 2
  end

  describe "postActivity delivery through the pipeline" do
    setup do
      previous = Application.get_env(:converger, :webhook_req_options)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, :webhook_req_options, previous),
          else: Application.delete_env(:converger, :webhook_req_options)
      end)

      Application.put_env(:converger, :webhook_req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      # Deliveries run in the channel process, not the test process.
      Req.Test.set_req_test_to_shared()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:webhook_request, Jason.decode!(body)})
        Req.Test.json(conn, %{ok: true})
      end)

      tenant = tenant_fixture()

      channel =
        webhook_channel_fixture(tenant, %{
          transformations: [%{"type" => "add_prefix", "prefix" => "[WS] "}]
        })

      conversation = conversation_fixture(tenant, channel)
      %{socket: join_as(channel, conversation, user_id: "user-ws"), channel: channel}
    end

    test "one WS message results in exactly one tracked, transformed delivery", %{
      socket: socket,
      channel: channel
    } do
      ref = push(socket, "postActivity", %{"text" => "hi there"})
      assert_reply ref, :ok, %{}, @reply_timeout

      assert_receive {:webhook_request, %{"text" => "[WS] hi there", "id" => activity_id}}
      refute_receive {:webhook_request, _}, 200

      delivery =
        Converger.Deliveries.get_delivery_for_activity_and_channel(activity_id, channel.id)

      assert delivery.status == "sent"
      assert delivery.attempts == 1
    end
  end

  defp write_tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "upload_src_#{System.unique_integer([:positive])}.txt")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
