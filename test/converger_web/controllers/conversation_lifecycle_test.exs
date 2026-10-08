defmodule ConvergerWeb.ConversationLifecycleTest do
  use ConvergerWeb.ConnCase

  alias Converger.{Activities, Conversations, Pipeline}
  alias Converger.Auth.ConvergerToken

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp tenant_conn(tenant), do: put_req_header(build_conn(), "x-api-key", tenant.api_key)

  defp api_conn(channel, conversation) do
    {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, conversation.id)
    put_req_header(build_conn(), "authorization", "Bearer #{token}")
  end

  describe "tenant REST API" do
    test "posting to a closed conversation returns 409", %{
      tenant: tenant,
      conversation: conversation
    } do
      {:ok, _} = Conversations.close_conversation(conversation)

      conn =
        tenant
        |> tenant_conn()
        |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{"text" => "hi"})

      assert %{"error" => "conversation_closed"} = json_response(conn, 409)
    end

    test "close and reopen endpoints", %{tenant: tenant, conversation: conversation} do
      conn = tenant |> tenant_conn() |> post(~p"/api/v1/conversations/#{conversation.id}/close")
      assert %{"status" => "closed"} = json_response(conn, 200)["data"]

      conn =
        tenant
        |> tenant_conn()
        |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{"text" => "hi"})

      assert json_response(conn, 409)

      conn = tenant |> tenant_conn() |> post(~p"/api/v1/conversations/#{conversation.id}/reopen")
      assert %{"status" => "active"} = json_response(conn, 200)["data"]

      conn =
        tenant
        |> tenant_conn()
        |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{"text" => "hi"})

      assert json_response(conn, 201)
    end

    test "close requires the owning tenant", %{conversation: conversation} do
      other = tenant_fixture()
      conn = other |> tenant_conn() |> post(~p"/api/v1/conversations/#{conversation.id}/close")
      assert json_response(conn, 404)
      assert Conversations.open?(Converger.Repo.reload!(conversation))
    end
  end

  describe "Converger API" do
    test "close, post (409), upload (409), reopen, post", %{
      channel: channel,
      conversation: conversation
    } do
      conn =
        channel
        |> api_conn(conversation)
        |> post("/api/v1/converger/conversations/#{conversation.id}/close")

      assert %{"conversationId" => _, "status" => "closed"} = json_response(conn, 200)

      conn =
        channel
        |> api_conn(conversation)
        |> post("/api/v1/converger/conversations/#{conversation.id}/activities", %{
          "type" => "message",
          "text" => "hi"
        })

      assert %{"error" => "conversation_closed"} = json_response(conn, 409)

      upload = %Plug.Upload{
        path: Path.join(System.tmp_dir!(), "never-read-#{System.unique_integer([:positive])}"),
        filename: "x.txt",
        content_type: "text/plain"
      }

      conn =
        channel
        |> api_conn(conversation)
        |> post("/api/v1/converger/conversations/#{conversation.id}/upload", %{"file" => upload})

      assert %{"error" => "conversation_closed"} = json_response(conn, 409)

      conn =
        channel
        |> api_conn(conversation)
        |> post("/api/v1/converger/conversations/#{conversation.id}/reopen")

      assert %{"status" => "active"} = json_response(conn, 200)

      conn =
        channel
        |> api_conn(conversation)
        |> post("/api/v1/converger/conversations/#{conversation.id}/activities", %{
          "type" => "message",
          "text" => "hi"
        })

      assert %{"id" => _} = json_response(conn, 200)
    end

    test "a token for another conversation cannot close it", %{
      tenant: tenant,
      channel: channel,
      conversation: conversation
    } do
      other = conversation_fixture(tenant, channel)

      conn =
        channel
        |> api_conn(other)
        |> post("/api/v1/converger/conversations/#{conversation.id}/close")

      assert json_response(conn, 403)
      assert Conversations.open?(Converger.Repo.reload!(conversation))
    end
  end

  describe "inbound webhook" do
    test "posting into a closed conversation returns 409", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})
      conversation = conversation_fixture(tenant, channel)
      {:ok, _} = Conversations.close_conversation(conversation)

      conn =
        signed_post(build_conn(), ~p"/api/v1/channels/#{channel.id}/inbound", channel, %{
          "text" => "hello",
          "sender" => "user1",
          "conversation_id" => conversation.id
        })

      assert %{"error" => "conversation_closed"} = json_response(conn, 409)
    end
  end

  describe "lifecycle event delivery" do
    test "is not delivered to messaging adapters such as echo", %{tenant: tenant} do
      echo = channel_fixture(tenant, %{type: "echo"})
      conversation = conversation_fixture(tenant, echo)

      {:ok, _} = Conversations.close_conversation(conversation)

      [event] = Activities.list_activities_for_conversation(conversation.id)
      assert event.type == "conversationUpdate"
      assert Pipeline.resolve_delivery_channels(event) == []
    end

    test "is delivered to webhook channels", %{tenant: tenant} do
      webhook = webhook_channel_fixture(tenant, %{mode: "outbound"})
      conversation = conversation_fixture(tenant, webhook)

      event = %Activities.Activity{
        type: "conversationUpdate",
        sender: "system",
        conversation_id: conversation.id,
        tenant_id: tenant.id
      }

      assert [%{id: id}] = Pipeline.resolve_delivery_channels(event)
      assert id == webhook.id
    end
  end
end
