defmodule ConvergerWeb.ConvergerLongPollTest do
  @moduledoc "Long-polling is the last-resort fallback of the Phoenix binding."

  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.ConvergerToken

  test "a valid token opens a long-poll session", %{conn: conn} do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {:ok, token, _} = ConvergerToken.generate_conversation_token(channel, conversation.id)

    conn = get(conn, "/socket/converger/longpoll", %{"token" => token, "vsn" => "2.0.0"})

    # 410 + a session token is how Phoenix starts a long-poll session.
    assert %{"status" => 410, "token" => session} = json_response(conn, 200)
    assert is_binary(session)
  end

  test "an invalid token is refused", %{conn: conn} do
    conn = get(conn, "/socket/converger/longpoll", %{"token" => "nope", "vsn" => "2.0.0"})
    # Phoenix reports long-poll statuses in the JSON body.
    assert %{"status" => 403} = json_response(conn, 200)
  end
end
