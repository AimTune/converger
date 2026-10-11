defmodule ConvergerWeb.SlackInboundTest do
  use ConvergerWeb.ConnCase

  @moduletag :capture_log

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Activities, Deliveries, Participants, Repo}
  alias Converger.Activities.Activity
  alias Converger.Channels.InboundSignature

  @secret "slack-signing-secret"

  setup do
    Application.put_env(:converger, :slack_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:converger, :slack_req_options) end)

    tenant = tenant_fixture()

    channel =
      channel_fixture(tenant, %{
        type: "slack",
        config: %{"bot_token" => "xoxb-test", "signing_secret" => @secret}
      })

    stub_slack()
    %{tenant: tenant, channel: channel}
  end

  # Answers every Web API call with a new ts and reports it to the test.
  defp stub_slack do
    test_pid = self()
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      :counters.add(counter, 1, 1)
      ts = "1800000000.00000#{:counters.get(counter, 1)}"
      method = List.last(conn.path_info)

      case {conn.host, method} do
        # A private file download (inbound) or a file upload (outbound).
        {"files.slack.com", "a.txt"} ->
          Plug.Conn.send_resp(conn, 200, "hello from slack")

        {"files.slack.com", _upload} ->
          send(test_pid, {:slack_upload, raw})
          Plug.Conn.send_resp(conn, 200, "OK - 5")

        {_host, "files.getUploadURLExternal"} ->
          send(test_pid, {:slack_call, method, URI.decode_query(raw)})

          Req.Test.json(conn, %{
            "ok" => true,
            "upload_url" => "https://files.slack.com/upload/v1/abc",
            "file_id" => "F123"
          })

        {_host, "files.completeUploadExternal"} ->
          send(test_pid, {:slack_call, method, URI.decode_query(raw)})
          Req.Test.json(conn, %{"ok" => true, "files" => [%{"id" => "F123"}]})

        _ ->
          send(test_pid, {:slack_call, method, Jason.decode!(raw)})
          Req.Test.json(conn, %{"ok" => true, "channel" => "C1", "ts" => ts})
      end
    end)
  end

  defp slack_post(conn, channel, body, timestamp \\ System.system_time(:second)) do
    raw = Jason.encode!(body)
    signature = "v0=" <> InboundSignature.hmac_hex(@secret, "v0:#{timestamp}:#{raw}")

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-slack-request-timestamp", Integer.to_string(timestamp))
    |> put_req_header("x-slack-signature", signature)
    |> post(~p"/api/v1/channels/#{channel.id}/inbound", raw)
  end

  defp event(event, event_id \\ "Ev#{System.unique_integer([:positive])}") do
    %{
      "type" => "event_callback",
      "team_id" => "T1",
      "api_app_id" => "A1",
      "event_id" => event_id,
      "event" => event
    }
  end

  defp message(attrs) do
    Map.merge(
      %{
        "type" => "message",
        "channel" => "C1",
        "user" => "U1",
        "text" => "hi",
        "ts" => "1700000000.000100"
      },
      attrs
    )
  end

  test "answers url_verification once the signature is verified", %{conn: conn, channel: channel} do
    body = %{
      "type" => "url_verification",
      "token" => "x",
      "challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"
    }

    assert %{"challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"} =
             conn |> slack_post(channel, body) |> json_response(200)

    unsigned =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", Jason.encode!(body))

    assert json_response(unsigned, 401)
  end

  test "a Slack message creates an activity and the reply goes to the same thread", %{
    conn: conn,
    channel: channel,
    tenant: tenant
  } do
    response = conn |> slack_post(channel, event(message(%{}))) |> json_response(200)
    assert [activity_id] = response["activity_ids"]

    inbound = Repo.get!(Activity, activity_id)
    assert inbound.text == "hi"
    assert inbound.sender == "U1"
    assert inbound.idempotency_key == "C1:1700000000.000100"

    participant = Participants.get_participant_by_external_id(channel.id, "C1:1700000000.000100")
    assert participant

    # A reply written by a WebSocket client in the same conversation is
    # delivered by the pipeline to the Slack thread.
    {:ok, reply} =
      Activities.create_client_activity(%{"type" => "message", "text" => "on it"}, %{
        tenant_id: tenant.id,
        conversation_id: inbound.conversation_id,
        sender: "agent-1"
      })

    assert_receive {:slack_call, "chat.postMessage",
                    %{"channel" => "C1", "thread_ts" => "1700000000.000100", "text" => "on it"}}

    delivery = Deliveries.get_delivery_for_activity_and_channel(reply.id, channel.id)
    assert delivery.status == "sent"
    assert "C1:1800000000.00000" <> _ = delivery.provider_message_id

    # Editing and deleting the reply edits and deletes the Slack message.
    [_, posted_ts] = String.split(delivery.provider_message_id, ":")

    {:ok, _} =
      Activities.create_client_activity(
        %{"type" => "messageUpdate", "text" => "done", "reply_to_id" => reply.id},
        %{tenant_id: tenant.id, conversation_id: inbound.conversation_id, sender: "agent-1"}
      )

    assert_receive {:slack_call, "chat.update",
                    %{"channel" => "C1", "ts" => ^posted_ts, "text" => "done"}}

    {:ok, _} =
      Activities.create_client_activity(
        %{"type" => "messageDelete", "reply_to_id" => reply.id},
        %{tenant_id: tenant.id, conversation_id: inbound.conversation_id, sender: "agent-1"}
      )

    assert_receive {:slack_call, "chat.delete", %{"channel" => "C1", "ts" => ^posted_ts}}
  end

  test "a request older than 5 minutes is rejected", %{conn: conn, channel: channel} do
    old = System.system_time(:second) - 6 * 60

    assert json_response(slack_post(conn, channel, event(message(%{})), old), 401)
    refute Repo.get_by(Activity, idempotency_key: "C1:1700000000.000100")
  end

  test "a retried callback and the app_mention of the same message create one activity", %{
    conn: conn,
    channel: channel
  } do
    body = event(message(%{}), "Ev1")
    first = conn |> slack_post(channel, body) |> json_response(200)
    retry = build_conn() |> slack_post(channel, body) |> json_response(200)

    mention =
      build_conn()
      |> slack_post(channel, event(message(%{"type" => "app_mention"}), "Ev2"))
      |> json_response(200)

    assert retry["duplicates"] == 1
    assert mention["duplicates"] == 1
    assert first["activity_ids"] == retry["activity_ids"]
    assert first["activity_ids"] == mention["activity_ids"]
  end

  test "thread replies and reactions join the thread's conversation", %{
    conn: conn,
    channel: channel
  } do
    root = conn |> slack_post(channel, event(message(%{}))) |> json_response(200)
    [root_id] = root["activity_ids"]
    root_activity = Repo.get!(Activity, root_id)

    reply =
      build_conn()
      |> slack_post(
        channel,
        event(
          message(%{
            "user" => "U2",
            "ts" => "1700000000.000200",
            "thread_ts" => "1700000000.000100"
          })
        )
      )
      |> json_response(200)

    reply_activity = Repo.get!(Activity, hd(reply["activity_ids"]))
    assert reply_activity.conversation_id == root_activity.conversation_id
    assert reply_activity.reply_to_id == root_id

    reaction =
      build_conn()
      |> slack_post(
        channel,
        event(%{
          "type" => "reaction_added",
          "user" => "U3",
          "reaction" => "eyes",
          "item" => %{"type" => "message", "channel" => "C1", "ts" => "1700000000.000200"}
        })
      )
      |> json_response(200)

    reaction_activity = Repo.get!(Activity, hd(reaction["activity_ids"]))
    assert reaction_activity.type == "messageReaction"
    assert reaction_activity.text == ":eyes:"
    assert reaction_activity.conversation_id == root_activity.conversation_id
    assert reaction_activity.reply_to_id == reply_activity.id
  end

  test "bot messages are acknowledged without creating anything", %{conn: conn, channel: channel} do
    body = event(message(%{"bot_id" => "B1", "user" => nil}))

    assert %{"status" => "accepted"} = conn |> slack_post(channel, body) |> json_response(200)
    refute Repo.get_by(Activity, idempotency_key: "C1:1700000000.000100")
  end

  test "an uploaded file is shared in the thread with files.uploadV2", %{
    conn: conn,
    channel: channel,
    tenant: tenant
  } do
    [activity_id] =
      conn
      |> slack_post(channel, event(message(%{})))
      |> json_response(200)
      |> Map.fetch!("activity_ids")

    inbound = Repo.get!(Activity, activity_id)
    {:ok, upload} = Converger.Uploads.create_attachment(tenant.id, {"notes.txt", "hello world"})

    {:ok, _} =
      Activities.create_client_activity(
        %{
          "type" => "message",
          "text" => "see attached",
          "attachments" => [
            %{
              "contentType" => "text/plain",
              "name" => "notes.txt",
              "contentUrl" => "/api/v1/converger/attachments/#{upload.id}"
            }
          ]
        },
        %{tenant_id: tenant.id, conversation_id: inbound.conversation_id, sender: "agent-1"}
      )

    assert_receive {:slack_call, "files.getUploadURLExternal",
                    %{"filename" => "notes.txt", "length" => "11"}}

    assert_receive {:slack_upload, "hello world"}
    assert_receive {:slack_call, "chat.postMessage", %{"text" => "see attached"}}

    assert_receive {:slack_call, "files.completeUploadExternal",
                    %{"channel_id" => "C1", "thread_ts" => "1700000000.000100", "files" => files}}

    assert [%{"id" => "F123", "title" => "notes.txt"}] = Jason.decode!(files)
  end

  test "download_files stores inbound Slack files as uploads", %{conn: conn, tenant: tenant} do
    channel =
      channel_fixture(tenant, %{
        type: "slack",
        config: %{
          "bot_token" => "xoxb-test",
          "signing_secret" => @secret,
          "download_files" => true
        }
      })

    body =
      event(
        message(%{
          "subtype" => "file_share",
          "files" => [
            %{
              "id" => "F1",
              "name" => "a.txt",
              "mimetype" => "text/plain",
              "url_private_download" => "https://files.slack.com/files-pri/T1-F1/download/a.txt"
            }
          ]
        })
      )

    [activity_id] =
      conn |> slack_post(channel, body) |> json_response(200) |> Map.fetch!("activity_ids")

    assert [%{"contentUrl" => "/api/v1/converger/attachments/" <> upload_id} = attachment] =
             Repo.get!(Activity, activity_id).attachments

    assert attachment["channelData"]["fileId"] == "F1"
    assert %{filename: "a.txt", size: 16} = Converger.Uploads.get_attachment(tenant.id, upload_id)
  end

  test "a card button click (form-encoded interaction) becomes a message", %{
    conn: conn,
    channel: channel
  } do
    payload =
      Jason.encode!(%{
        "type" => "block_actions",
        "user" => %{"id" => "U1"},
        "channel" => %{"id" => "C1"},
        "container" => %{"message_ts" => "1700000000.000500", "channel_id" => "C1"},
        "message" => %{"ts" => "1700000000.000500"},
        "actions" => [
          %{"action_id" => "converger_0_0", "value" => "/track", "action_ts" => "1700000001.1"}
        ]
      })

    raw = URI.encode_query(%{"payload" => payload})
    timestamp = System.system_time(:second)
    signature = "v0=" <> InboundSignature.hmac_hex(@secret, "v0:#{timestamp}:#{raw}")

    response =
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("x-slack-request-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-slack-signature", signature)
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", raw)
      |> json_response(200)

    activity = Repo.get!(Activity, hd(response["activity_ids"]))
    assert activity.text == "/track"
    assert activity.metadata["interactive_reply"]["id"] == "converger_0_0"
  end
end
