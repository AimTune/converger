defmodule ConvergerWeb.ConvergerAPI.ClientHistoryAndConversationsTest do
  @moduledoc """
  The client API endpoints chativa's hub extras use (ADR-0065, #65):
  backward history paging with a seq cursor, activities as Protocol v1
  frames, the channel's conversation list for channel-scoped tokens, and the
  upload result as an attachment message.
  """

  use ConvergerWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Repo}
  alias Converger.Auth.ConvergerToken
  alias Converger.Conversations.Conversation

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp message!(conversation, text, sender \\ "bot-1") do
    {:ok, activity} =
      Activities.create_activity(%{
        "type" => "message",
        "text" => text,
        "sender" => sender,
        "tenant_id" => conversation.tenant_id,
        "conversation_id" => conversation.id
      })

    activity
  end

  defp conversation_token(ctx, opts \\ []) do
    {:ok, token, _} =
      ConvergerToken.generate_conversation_token(ctx.channel, ctx.conversation.id, opts)

    token
  end

  defp history(conn, ctx, query) do
    conn
    |> bearer(conversation_token(ctx, user_id: "alice"))
    |> get("/api/v1/converger/conversations/#{ctx.conversation.id}/activities?#{query}")
    |> json_response(200)
  end

  describe "backward history paging" do
    setup ctx do
      for n <- 1..5, do: message!(ctx.conversation, "m#{n}")
      :ok
    end

    test "pages from the newest activity back to the first, oldest first", %{conn: conn} = ctx do
      first = history(conn, ctx, "direction=backward&limit=2")
      assert Enum.map(first["activities"], & &1["seq"]) == [4, 5]
      assert first["has_more"] == true
      assert first["cursor"] == "4"
      assert first["watermark"] == Converger.ConvergerAPI.Watermark.encode(5)

      second = history(conn, ctx, "before=#{first["cursor"]}&limit=2")
      assert Enum.map(second["activities"], & &1["text"]) == ["m2", "m3"]
      assert second["cursor"] == "2"

      last = history(conn, ctx, "before=#{second["cursor"]}&limit=2")
      assert Enum.map(last["activities"], & &1["seq"]) == [1]
      assert last["has_more"] == false
      assert last["cursor"] == nil
    end

    test "forward paging is unchanged and carries no cursor", %{conn: conn} = ctx do
      page = history(conn, ctx, "watermark=2&limit=2")
      assert Enum.map(page["activities"], & &1["seq"]) == [3, 4]
      assert page["has_more"] == true
      refute Map.has_key?(page, "cursor")
    end

    test "rejects a malformed before, direction or format", %{conn: conn} = ctx do
      base = "/api/v1/converger/conversations/#{ctx.conversation.id}/activities"
      token = conversation_token(ctx)

      for query <- ["before=abc", "before=0", "direction=sideways", "format=xml"] do
        conn = conn |> recycle() |> bearer(token) |> get("#{base}?#{query}")

        assert assert_api_error(conn, 400, "bad_request")["message"] =~
                 ~r/before|direction|format/
      end
    end
  end

  describe "format=frames" do
    test "renders Protocol v1 frames relative to the token's user", %{conn: conn} = ctx do
      message!(ctx.conversation, "hi", "alice")
      message!(ctx.conversation, "hello", "bot-1")

      {:ok, _} =
        Activities.create_activity(%{
          "type" => "message",
          "sender" => "bot-1",
          "message_type" => "tool_call",
          "payload" => %{"data" => %{"id" => "t1", "name" => "lookup", "status" => "running"}},
          "tenant_id" => ctx.tenant.id,
          "conversation_id" => ctx.conversation.id
        })

      page = history(conn, ctx, "direction=backward&format=frames")
      refute Map.has_key?(page, "activities")

      assert [
               %{"type" => "text", "from" => "user", "seq" => 1, "data" => %{"text" => "hi"}},
               %{"type" => "text", "from" => "bot", "seq" => 2},
               %{"type" => "tool_call", "seq" => 3, "data" => %{"id" => "t1"}}
             ] = page["frames"]
    end

    test "uses ?userId= for a token without user_id", %{conn: conn} = ctx do
      message!(ctx.conversation, "hi", "bob")

      page =
        conn
        |> bearer(conversation_token(ctx))
        |> get(
          "/api/v1/converger/conversations/#{ctx.conversation.id}/activities?format=frames&userId=bob"
        )
        |> json_response(200)

      assert [%{"from" => "user"}] = page["frames"]
    end
  end

  describe "GET /api/v1/converger/conversations" do
    setup ctx do
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel, scope: "channel")
      %{agent_token: token}
    end

    defp list(conn, token, query \\ "") do
      conn
      |> bearer(token)
      |> get("/api/v1/converger/conversations?#{query}")
      |> json_response(200)
    end

    defp touch!(conversation, at) do
      Repo.update_all(
        from(c in Conversation, where: c.id == ^conversation.id),
        set: [updated_at: at]
      )
    end

    test "lists the channel's conversations, most recently active first", %{conn: conn} = ctx do
      older = conversation_fixture(ctx.tenant, ctx.channel, %{metadata: %{"title" => "Refund"}})
      message!(older, "where is my refund?", "alice")
      message!(ctx.conversation, "hello", "bob")
      touch!(older, ~U[2026-01-01 00:00:00.000000Z])

      other_channel = channel_fixture(ctx.tenant)
      _hidden = conversation_fixture(ctx.tenant, other_channel)

      page = list(conn, ctx.agent_token)
      assert page["has_more"] == false
      assert page["cursor"] == nil

      assert [newest, oldest] = page["conversations"]
      assert newest["id"] == ctx.conversation.id
      assert newest["lastMessage"] == "hello"
      assert newest["lastSeq"] == 1
      assert newest["status"] == "active"
      assert is_integer(newest["lastMessageAt"])

      assert oldest["id"] == older.id
      assert oldest["title"] == "Refund"
      assert oldest["lastMessage"] == "where is my refund?"
    end

    test "pages with the cursor and filters by status and updated_since", %{conn: conn} = ctx do
      closed = conversation_fixture(ctx.tenant, ctx.channel, %{status: "closed"})
      touch!(closed, ~U[2026-01-01 00:00:00.000000Z])

      first = list(conn, ctx.agent_token, "limit=1")
      assert [%{"id" => id}] = first["conversations"]
      assert id == ctx.conversation.id
      assert first["has_more"] == true

      second = list(conn, ctx.agent_token, "limit=1&cursor=#{first["cursor"]}")
      assert [%{"id" => closed_id, "status" => "closed"}] = second["conversations"]
      assert closed_id == closed.id

      assert [%{"id" => ^closed_id}] =
               list(conn, ctx.agent_token, "status=closed")["conversations"]

      since = DateTime.to_unix(~U[2026-06-01 00:00:00Z], :millisecond)

      assert [%{"id" => ^id}] =
               list(conn, ctx.agent_token, "updated_since=#{since}")["conversations"]

      assert [%{"id" => ^id}] =
               list(conn, ctx.agent_token, "updated_since=2026-06-01T00:00:00Z")["conversations"]
    end

    test "rejects bad filters", %{conn: conn} = ctx do
      for query <- ["status=open", "updated_since=yesterday", "cursor=nope"] do
        conn = conn |> recycle() |> bearer(ctx.agent_token)
        conn = get(conn, "/api/v1/converger/conversations?#{query}")
        assert_api_error(conn, 400, "bad_request")
      end
    end

    test "needs a channel-scoped token", %{conn: conn} = ctx do
      {:ok, end_user, _} = ConvergerToken.generate_token(ctx.channel, user_id: "alice")

      for token <- [end_user, conversation_token(ctx)] do
        conn = conn |> recycle() |> bearer(token) |> get("/api/v1/converger/conversations")
        assert assert_api_error(conn, 403, "forbidden")["message"] =~ "channel-scoped"
      end
    end
  end

  describe "POST /api/v1/converger/conversations with a title" do
    test "stores the title as metadata.title", %{conn: conn} = ctx do
      {:ok, token, _} = ConvergerToken.generate_token(ctx.channel)

      %{"conversationId" => id} =
        conn
        |> bearer(token)
        |> post("/api/v1/converger/conversations", %{"title" => "Order ORD-42"})
        |> json_response(201)

      assert Repo.get!(Conversation, id).metadata == %{
               "source" => "converger",
               "title" => "Order ORD-42"
             }

      conn =
        conn
        |> recycle()
        |> bearer(token)
        |> post("/api/v1/converger/conversations", %{"title" => String.duplicate("x", 201)})

      assert_api_error(conn, 400, "bad_request")
    end
  end

  describe "upload" do
    test "returns the seq and the attachment message frame", %{conn: conn} = ctx do
      path = Path.join(System.tmp_dir!(), "chativa_#{System.unique_integer([:positive])}.png")
      File.write!(path, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, 64))
      on_exit(fn -> File.rm(path) end)

      body =
        conn
        |> bearer(conversation_token(ctx, user_id: "alice"))
        |> post("/api/v1/converger/conversations/#{ctx.conversation.id}/upload", %{
          "file" => %Plug.Upload{path: path, filename: "receipt.png", content_type: "image/png"}
        })
        |> json_response(200)

      assert body["seq"] == 1
      assert [%{"name" => "receipt.png", "contentUrl" => url}] = body["attachments"]

      assert %{
               "type" => "text",
               "id" => id,
               "seq" => 1,
               "from" => "user",
               "sender" => %{"id" => "alice"},
               "data" => %{"attachments" => [%{"contentUrl" => ^url, "name" => "receipt.png"}]}
             } = body["frame"]

      assert id == body["id"]
    end
  end
end
