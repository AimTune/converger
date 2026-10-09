defmodule ConvergerWeb.Integration.WebSocketE2ETest do
  use ConvergerWeb.ChannelCase
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)

    %{conn: conn, channel: channel}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "channel secret -> token -> conversation -> socket: send and receive both ways", %{
    conn: conn,
    channel: channel
  } do
    # 1. The integrator's backend exchanges the channel secret for a user token.
    %{"token" => user_token} =
      conn
      |> bearer(channel.secret)
      |> post(~p"/api/v1/converger/tokens/generate", %{user: %{id: "e2e-user"}})
      |> json_response(200)

    # 2. The client starts a conversation and gets a conversation token.
    %{"conversationId" => conversation_id, "token" => token} =
      conn
      |> bearer(user_token)
      |> post(~p"/api/v1/converger/conversations")
      |> json_response(201)

    # 3. It connects and joins the single WebSocket entry point.
    {:ok, socket} = Phoenix.ChannelTest.connect(ConvergerSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConvergerChannel, "converger:conversation:#{conversation_id}")

    # 4. Sending over the socket: reply, then the activitySet.
    ref =
      Phoenix.ChannelTest.push(socket, "postActivity", %{
        "text" => "over ws",
        "clientId" => "e2e-1"
      })

    assert_reply ref, :ok, %{id: ws_id, watermark: ws_watermark}, 1_000

    assert_push "activitySet", %{
      activities: [%{id: ^ws_id, text: "over ws", from: %{id: "e2e-user"}}],
      watermark: ^ws_watermark
    }

    # 5. Sending over REST reaches the socket the same way.
    %{"id" => rest_id} =
      conn
      |> bearer(token)
      |> post(~p"/api/v1/converger/conversations/#{conversation_id}/activities", %{
        type: "message",
        text: "over rest"
      })
      |> json_response(200)

    assert_push "activitySet", %{activities: [%{id: ^rest_id, text: "over rest"}]}
  end
end
