defmodule ConvergerClient.IntegrationTest do
  # End-to-end test against a real server (packages/conformance/integration).
  # Run with: CONVERGER_FIXTURES=../conformance/integration/fixtures.json mix test --only integration
  use ExUnit.Case, async: false

  alias ConvergerClient.{Ack, ClientAPI, Error, Socket, TenantAPI, Webhook}

  @moduletag :integration

  setup do
    path = System.get_env("CONVERGER_FIXTURES") || flunk("set CONVERGER_FIXTURES")
    doc = path |> File.read!() |> Jason.decode!()
    base_url = System.get_env("CONVERGER_BASE_URL") || doc["base_url"]
    {:ok, fx: doc["elixir"], base_url: base_url}
  end

  test "create a conversation, send, receive over the socket, verify the webhook",
       %{fx: fx, base_url: base_url} do
    start_supervised!(
      {Bandit,
       plug: {ConvergerClient.WebhookReceiver, self()},
       port: fx["webhook_port"],
       startup_log: false}
    )

    client =
      ConvergerClient.new(base_url, api_key: fx["api_key"], channel_secret: fx["channel_secret"])

    marker = "ex-#{System.unique_integer([:positive])}"

    {:ok, token} = ClientAPI.generate_token(client, user_id: "sdk-elixir")
    {:ok, conv} = ClientAPI.create_conversation(client, token.token)

    {:ok, sock} =
      Socket.start_link(client: client, token: conv.token, conversation_id: conv.conversation_id)

    assert_receive {:converger, ^sock, %{"type" => "welcome"}}, 10_000
    assert {:ok, %Ack{seq: seq}} = Socket.send_text(sock, marker <> " ws")
    assert seq >= 1

    {:ok, reply} =
      TenantAPI.post_activity(client, conv.conversation_id, %{
        sender: "bot",
        text: marker <> " bot"
      })

    reply_seq = reply.seq

    assert_receive {:converger, ^sock, %{"seq" => ^reply_seq, "data" => %{"text" => text}}},
                   10_000

    assert text == marker <> " bot"
    assert Socket.watermark(sock) == reply_seq

    {:ok, page} = ClientAPI.list_activities(client, conv.token, conv.conversation_id)

    assert Enum.map(Enum.take(page.activities, 2), & &1.text) == [
             marker <> " ws",
             marker <> " bot"
           ]

    {:ok, a1} =
      ClientAPI.post_activity(client, conv.token, conv.conversation_id, %{text: "hi"},
        idempotency_key: "k-1"
      )

    {:ok, a2} =
      ClientAPI.post_activity(client, conv.token, conv.conversation_id, %{text: "hi"},
        idempotency_key: "k-1"
      )

    assert a1.id == a2.id

    assert_webhook(conv.conversation_id, fx["webhook_secret"])

    {:ok, _} = TenantAPI.close_conversation(client, conv.conversation_id)

    assert {:error, %Error{status: 409, code: "conversation_closed"}} =
             ClientAPI.post_activity(client, conv.token, conv.conversation_id, %{text: "late"})
  end

  defp assert_webhook(conversation_id, secret) do
    assert_receive {:webhook, headers, body}, 20_000
    assert Webhook.verify_signature(headers, body, secret) == :ok

    if Jason.decode!(body)["conversation_id"] != conversation_id,
      do: assert_webhook(conversation_id, secret)
  end
end
