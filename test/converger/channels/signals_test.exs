defmodule Converger.Channels.SignalsTest do
  use Converger.DataCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Activities, Channels, Participants}
  alias Converger.Channels.Signals

  @phone "16505551234"

  setup do
    previous = Application.get_env(:converger, :whatsapp_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :whatsapp_req_options, previous),
        else: Application.delete_env(:converger, :whatsapp_req_options)
    end)

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:whatsapp_request, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"success" => true})
    end)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "phone_number_id" => "106540352242922",
          "access_token" => "token",
          "verify_token" => "verify",
          "app_secret" => "meta-app-secret"
        }
      })

    {:ok, conversation} = Participants.resolve_conversation(channel, %{"external_id" => @phone})

    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp inbound(conversation, wamid, text) do
    {:ok, activity} =
      Activities.create_client_activity(%{"text" => text}, %{
        tenant_id: conversation.tenant_id,
        conversation_id: conversation.id,
        sender: @phone,
        idempotency_key: wamid
      })

    activity
  end

  test "typing is forwarded as the WhatsApp typing indicator on the latest inbound message", %{
    conversation: conversation,
    channel: channel
  } do
    inbound(conversation, "wamid.1", "hi")
    inbound(conversation, "wamid.2", "anyone?")

    assert [{channel_id, :ok}] =
             Signals.forward(conversation.id, "agent-7", :send_typing, nil, %{is_typing: true})

    assert channel_id == channel.id

    assert_received {:whatsapp_request, "/v26.0/106540352242922/messages", body}

    assert body == %{
             "messaging_product" => "whatsapp",
             "status" => "read",
             "message_id" => "wamid.2",
             "typing_indicator" => %{"type" => "text"}
           }
  end

  test "typing stop needs no provider call", %{conversation: conversation} do
    inbound(conversation, "wamid.1", "hi")

    :ok = Signals.forward_typing(conversation.id, "agent-7", false)

    refute_received {:whatsapp_request, _, _}
  end

  test "a read receipt marks the latest inbound message up to the watermark as read", %{
    conversation: conversation
  } do
    first = inbound(conversation, "wamid.1", "hi")
    inbound(conversation, "wamid.2", "later")

    :ok = Signals.forward_read(conversation.id, "agent-7", first.seq)

    assert_received {:whatsapp_request, _, body}

    assert body == %{
             "messaging_product" => "whatsapp",
             "status" => "read",
             "message_id" => "wamid.1"
           }
  end

  test "without an inbound message there is nothing to mark", %{conversation: conversation} do
    :ok = Signals.forward_typing(conversation.id, "agent-7", true)
    refute_received {:whatsapp_request, _, _}
  end

  test "channels whose adapter has no typing support are skipped", %{tenant: tenant} do
    channel = webhook_channel_fixture(tenant)
    {:ok, conversation} = Participants.resolve_conversation(channel, %{"external_id" => "ext-1"})

    assert [] = Signals.forward(conversation.id, "agent-7", :send_typing, nil, %{is_typing: true})
  end

  @tag :capture_log
  test "a provider error is returned and does not raise", %{conversation: conversation} do
    inbound(conversation, "wamid.1", "hi")

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => %{"code" => 100}})
    end)

    assert [{_, {:error, {:http_error, 400, _}}}] =
             Signals.forward(conversation.id, "agent-7", :send_read_receipt, nil, %{up_to_seq: 1})
  end
end
