defmodule ConvergerWeb.ConvergerChannelTest do
  use ConvergerWeb.ChannelCase
  import Phoenix.ConnTest, except: [connect: 2, connect: 3]
  import Plug.Conn

  @endpoint ConvergerWeb.Endpoint

  alias Converger.Auth.ConvergerToken
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
        "watermark" => Converger.ConvergerAPI.Watermark.encode(first.id)
      })

    assert_push "activitySet", %{activities: [replayed]}

    assert wire(replayed) ==
             wire(ConvergerWeb.ConvergerAPI.ActivityJSON.activity_data(second))

    assert [%{"contentUrl" => "https://x/z.png"}] = wire(replayed)["attachments"]
  end

  defp write_tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "upload_src_#{System.unique_integer([:positive])}.txt")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
