defmodule Converger.Channels.Adapters.SlackTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.{Adapter, DeliveryError, InboundSignature}
  alias Converger.Channels.Adapters.Slack
  alias Converger.Channels.Adapters.Slack.{Blocks, Events}

  @secret "slack-signing-secret"
  @channel %{
    type: "slack",
    config: %{
      "bot_token" => "xoxb-test",
      "signing_secret" => @secret,
      "channel" => "C0DEFAULT"
    }
  }

  setup do
    Application.put_env(:converger, :slack_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:converger, :slack_req_options) end)
  end

  defp sign(body, timestamp \\ System.system_time(:second)) do
    [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature",
       "v0=" <> InboundSignature.hmac_hex(@secret, "v0:#{timestamp}:#{body}")}
    ]
  end

  # Records every Web API call ({method, decoded body}) and answers with `reply`.
  defp capture_calls(
         reply \\ fn _method, _body -> %{"ok" => true, "ts" => "1700000000.000200"} end
       ) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      method = conn.path_info |> List.last()
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      body =
        case Plug.Conn.get_req_header(conn, "content-type") do
          ["application/json" <> _] -> Jason.decode!(raw)
          ["application/x-www-form-urlencoded" <> _] -> URI.decode_query(raw)
          _ -> raw
        end

      send(test_pid, {:slack_call, method, body, Plug.Conn.get_req_header(conn, "authorization")})
      Req.Test.json(conn, reply.(method, body))
    end)
  end

  defp activity(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        type: "message",
        text: "hello",
        attachments: [],
        metadata: %{},
        reply_to_id: nil,
        conversation_id: nil,
        tenant_id: nil
      },
      Map.new(attrs)
    )
  end

  describe "registry and config" do
    test "is a built-in adapter" do
      assert {:ok, Slack} = Adapter.adapter_for("slack")
      assert Adapter.capability?("slack", :provider_ack)
      assert Adapter.activity_types("slack") == ~w(message messageUpdate messageDelete)
    end

    test "requires a bot token and a signing secret" do
      assert {:error, "slack config missing: bot_token, signing_secret"} =
               Adapter.validate_config("slack", %{})
    end

    test "accepts only bot tokens and known conversation scopes" do
      base = %{"bot_token" => "xoxb-1", "signing_secret" => "s"}

      assert :ok = Adapter.validate_config("slack", base)
      assert :ok = Adapter.validate_config("slack", Map.put(base, "conversation_scope", "user"))

      assert {:error, "slack config 'bot_token' must be a bot token (xoxb-...)"} =
               Adapter.validate_config("slack", %{base | "bot_token" => "xoxp-1"})

      assert {:error, "slack config 'conversation_scope' must be one of: thread, channel, user"} =
               Adapter.validate_config("slack", Map.put(base, "conversation_scope", "team"))
    end
  end

  describe "verify_inbound_signature/3" do
    test "accepts a valid v0 signature" do
      body = ~s({"type":"event_callback"})
      assert :ok = Slack.verify_inbound_signature(@channel, sign(body), body)
    end

    test "rejects a tampered body" do
      headers = sign(~s({"a":1}))

      assert {:error, :invalid_signature} =
               Slack.verify_inbound_signature(@channel, headers, ~s({"a":2}))
    end

    test "rejects a request older than the tolerance (replay)" do
      body = ~s({"type":"event_callback"})
      headers = sign(body, System.system_time(:second) - 301)

      assert {:error, :stale_timestamp} = Slack.verify_inbound_signature(@channel, headers, body)
    end

    test "rejects a request from the future beyond the tolerance" do
      body = "{}"
      headers = sign(body, System.system_time(:second) + 301)

      assert {:error, :stale_timestamp} = Slack.verify_inbound_signature(@channel, headers, body)
    end

    test "rejects a signature without a valid timestamp" do
      headers = [{"x-slack-signature", "v0=abc"}, {"x-slack-request-timestamp", "soon"}]

      assert {:error, :invalid_timestamp} =
               Slack.verify_inbound_signature(@channel, headers, "{}")
    end

    test "reports a missing signature" do
      assert :missing = Slack.verify_inbound_signature(@channel, [], "{}")
    end
  end

  describe "inbound_challenge/2" do
    test "answers url_verification with its challenge" do
      assert {:ok, %{"challenge" => "abc"}} =
               Slack.inbound_challenge(@channel, %{
                 "type" => "url_verification",
                 "challenge" => "abc"
               })
    end

    test "ignores other bodies" do
      assert :none = Slack.inbound_challenge(@channel, %{"type" => "event_callback"})
    end
  end

  describe "parse_inbound/2" do
    defp callback(event, extra \\ %{}) do
      Map.merge(
        %{
          "type" => "event_callback",
          "team_id" => "T1",
          "api_app_id" => "A1",
          "event_id" => "Ev1",
          "event" => event
        },
        extra
      )
    end

    test "a top-level message starts a thread conversation" do
      event = %{
        "type" => "message",
        "channel" => "C1",
        "user" => "U1",
        "text" => "hi",
        "ts" => "1700000000.000100",
        "channel_type" => "channel"
      }

      assert {:ok, [message]} = Slack.parse_inbound(@channel, callback(event))
      assert message["type"] == "message"
      assert message["text"] == "hi"
      assert message["sender"] == "U1"
      assert message["idempotency_key"] == "C1:1700000000.000100"
      assert message["reply_to_provider_id"] == nil
      assert message["participant"] == %{"external_id" => "C1:1700000000.000100"}

      assert %{
               "slack_channel" => "C1",
               "slack_ts" => "1700000000.000100",
               "slack_team" => "T1",
               "slack_event_type" => "message"
             } = message["metadata"]
    end

    test "a thread reply joins the thread's conversation and refers to its root" do
      event = %{
        "type" => "message",
        "channel" => "C1",
        "user" => "U2",
        "text" => "reply",
        "ts" => "1700000000.000300",
        "thread_ts" => "1700000000.000100"
      }

      assert {:ok, [message]} = Slack.parse_inbound(@channel, callback(event))
      assert message["participant"] == %{"external_id" => "C1:1700000000.000100"}
      assert message["reply_to_provider_id"] == "C1:1700000000.000100"
      assert message["metadata"]["slack_thread_ts"] == "1700000000.000100"
    end

    test "conversation_scope channel and user" do
      event = %{
        "type" => "message",
        "channel" => "C1",
        "user" => "U1",
        "ts" => "1.2",
        "text" => "x"
      }

      for {scope, external_id} <- [{"channel", "C1"}, {"user", "C1:U1"}] do
        channel = put_in(@channel, [:config, "conversation_scope"], scope)
        assert {:ok, [message]} = Slack.parse_inbound(channel, callback(event))
        assert message["participant"] == %{"external_id" => external_id}
      end
    end

    test "an app_mention has the same idempotency key as its message event" do
      event = %{
        "type" => "app_mention",
        "channel" => "C1",
        "user" => "U1",
        "ts" => "1.2",
        "text" => "<@B> hi"
      }

      assert {:ok, [message]} = Slack.parse_inbound(@channel, callback(event))
      assert message["idempotency_key"] == "C1:1.2"
      assert message["metadata"]["slack_event_type"] == "app_mention"
    end

    test "bot messages, including Converger's own replies, are ignored" do
      bot = %{
        "type" => "message",
        "channel" => "C1",
        "bot_id" => "B1",
        "ts" => "1.2",
        "text" => "x"
      }

      bot_message = %{
        "type" => "message",
        "subtype" => "bot_message",
        "channel" => "C1",
        "ts" => "1.3"
      }

      join = %{
        "type" => "message",
        "subtype" => "channel_join",
        "channel" => "C1",
        "user" => "U1",
        "ts" => "1.4"
      }

      for event <- [bot, bot_message, join] do
        assert {:ok, []} = Slack.parse_inbound(@channel, callback(event))
      end
    end

    test "events of another app are ignored when app_id is set" do
      channel = put_in(@channel, [:config, "app_id"], "A2")

      event = %{
        "type" => "message",
        "channel" => "C1",
        "user" => "U1",
        "ts" => "1.2",
        "text" => "x"
      }

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, []} = Slack.parse_inbound(channel, callback(event))
      end)

      assert {:ok, [_]} = Slack.parse_inbound(channel, callback(event, %{"api_app_id" => "A2"}))
    end

    test "file shares become attachments referencing the Slack file" do
      event = %{
        "type" => "message",
        "subtype" => "file_share",
        "channel" => "C1",
        "user" => "U1",
        "ts" => "1.2",
        "text" => "see",
        "files" => [
          %{
            "id" => "F1",
            "name" => "a.png",
            "mimetype" => "image/png",
            "size" => 10,
            "url_private" => "https://files.slack.com/a.png",
            "url_private_download" => "https://files.slack.com/download/a.png"
          }
        ]
      }

      assert {:ok, [message]} = Slack.parse_inbound(@channel, callback(event))

      assert [
               %{
                 "contentType" => "image/png",
                 "name" => "a.png",
                 "size" => 10,
                 "channelData" => %{
                   "provider" => "slack",
                   "fileId" => "F1",
                   "urlPrivateDownload" => "https://files.slack.com/download/a.png"
                 }
               }
             ] = message["attachments"]
    end

    test "edits and deletes refer to the original message" do
      edit = %{
        "type" => "message",
        "subtype" => "message_changed",
        "channel" => "C1",
        "message" => %{
          "user" => "U1",
          "text" => "fixed",
          "ts" => "1.2",
          "edited" => %{"ts" => "1.9"}
        }
      }

      assert {:ok, [update]} = Slack.parse_inbound(@channel, callback(edit))
      assert update["type"] == "messageUpdate"
      assert update["text"] == "fixed"
      assert update["reply_to_provider_id"] == "C1:1.2"
      assert update["idempotency_key"] == "C1:1.2:edit:1.9"

      delete = %{
        "type" => "message",
        "subtype" => "message_deleted",
        "channel" => "C1",
        "deleted_ts" => "1.2",
        "previous_message" => %{"user" => "U1", "ts" => "1.2"}
      }

      assert {:ok, [deleted]} = Slack.parse_inbound(@channel, callback(delete))
      assert deleted["type"] == "messageDelete"
      assert deleted["reply_to_provider_id"] == "C1:1.2"

      own_delete = put_in(delete, ["previous_message", "bot_id"], "B1")
      assert {:ok, []} = Slack.parse_inbound(@channel, callback(own_delete))
    end

    test "reactions become messageReaction activities" do
      added = %{
        "type" => "reaction_added",
        "user" => "U1",
        "reaction" => "thumbsup",
        "item" => %{"type" => "message", "channel" => "C1", "ts" => "1.2"}
      }

      assert {:ok, [reaction]} = Slack.parse_inbound(@channel, callback(added))
      assert reaction["type"] == "messageReaction"
      assert reaction["text"] == ":thumbsup:"
      assert reaction["reply_to_provider_id"] == "C1:1.2"
      assert reaction["idempotency_key"] == "Ev1"
      assert reaction["participant"] == %{"external_id" => "C1:1.2"}

      removed = %{added | "type" => "reaction_removed"}
      assert {:ok, [%{"text" => ""}]} = Slack.parse_inbound(@channel, callback(removed))
    end

    test "a card button click becomes a message with the button value" do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "user" => %{"id" => "U1"},
          "team" => %{"id" => "T1"},
          "channel" => %{"id" => "C1"},
          "container" => %{"message_ts" => "1.5", "channel_id" => "C1"},
          "message" => %{"ts" => "1.5", "thread_ts" => "1.2"},
          "actions" => [
            %{
              "action_id" => "converger_0_0",
              "value" => "/track",
              "text" => %{"text" => "Track"},
              "action_ts" => "1.6"
            }
          ]
        })

      assert {:ok, [message]} = Slack.parse_inbound(@channel, %{"payload" => payload})
      assert message["text"] == "/track"
      assert message["participant"] == %{"external_id" => "C1:1.2"}
      assert message["metadata"]["interactive_reply"]["title"] == "Track"
    end

    test "other well-formed bodies carry no message; garbage is an error" do
      assert {:ok, []} = Slack.parse_inbound(@channel, %{"type" => "app_rate_limited"})
      assert {:error, _} = Slack.parse_inbound(@channel, %{"foo" => "bar"})
    end
  end

  describe "Blocks.from_attachments/1" do
    test "renders a card as a section and buttons" do
      card = %{
        "contentType" => "application/vnd.converger.card.hero",
        "content" => %{
          "title" => "ORD-1",
          "subtitle" => "249.90 USD",
          "image" => "https://example.com/1.png",
          "buttons" => [
            %{"label" => "Track", "value" => "/track ORD-1"},
            %{"label" => "Open", "url" => "https://example.com/o/1"},
            %{"label" => "Approve", "value" => %{"approved" => true}}
          ]
        }
      }

      assert [section, actions] = Blocks.from_attachments([card, %{"contentType" => "image/png"}])
      assert section.text.text == "*ORD-1*\n249.90 USD"
      assert section.accessory.image_url == "https://example.com/1.png"

      assert [
               %{value: "/track ORD-1"},
               %{url: "https://example.com/o/1"},
               %{value: ~s({"approved":true})}
             ] = actions.elements
    end
  end

  describe "deliver_activity/2" do
    test "posts to the default channel and returns the message reference" do
      capture_calls()

      assert {:ok, meta} = Slack.deliver_activity(@channel, activity(text: "hi"))

      assert_received {:slack_call, "chat.postMessage",
                       %{"channel" => "C0DEFAULT", "text" => "hi"} = body, ["Bearer xoxb-test"]}

      refute Map.has_key?(body, "thread_ts")
      assert meta["provider_message_id"] == "C0DEFAULT:1700000000.000200"
      assert meta["slack_ts"] == "1700000000.000200"
    end

    test "metadata picks the channel and thread" do
      capture_calls()

      activity = activity(metadata: %{"slack_channel" => "C9", "slack_thread_ts" => "1.1"})
      assert {:ok, meta} = Slack.deliver_activity(@channel, activity)

      assert_received {:slack_call, "chat.postMessage",
                       %{"channel" => "C9", "thread_ts" => "1.1"}, _}

      assert meta["slack_thread_ts"] == "1.1"
    end

    test "card attachments are sent as blocks" do
      capture_calls()

      card = %{
        "contentType" => "application/vnd.converger.card.hero",
        "content" => %{"title" => "T"}
      }

      assert {:ok, _} = Slack.deliver_activity(@channel, activity(attachments: [card]))

      assert_received {:slack_call, "chat.postMessage", %{"blocks" => [%{"type" => "section"}]},
                       _}
    end

    test "fails permanently without a target channel" do
      channel = %{@channel | config: Map.delete(@channel.config, "channel")}

      assert {:error, %DeliveryError{retryable?: false}} =
               Slack.deliver_activity(channel, activity([]))
    end

    test "permanent and transient Slack errors" do
      capture_calls(fn _method, _body -> %{"ok" => false, "error" => "channel_not_found"} end)

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               Slack.deliver_activity(@channel, activity([]))

      assert reason =~ "channel_not_found"

      capture_calls(fn _method, _body -> %{"ok" => false, "error" => "internal_error"} end)

      assert {:error, %DeliveryError{retryable?: true}} =
               Slack.deliver_activity(@channel, activity([]))
    end

    test "429 is retried after Retry-After" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.send_resp(429, ~s({"ok":false,"error":"ratelimited"}))
      end)

      assert {:error, %DeliveryError{retryable?: true, retry_after_ms: 7000, status: 429}} =
               Slack.deliver_activity(@channel, activity([]))
    end

    test "edits and deletes need a message Converger posted" do
      for type <- ~w(messageUpdate messageDelete) do
        assert {:error, %DeliveryError{retryable?: false}} =
                 Slack.deliver_activity(@channel, activity(type: type))
      end
    end
  end

  describe "health_probe/1" do
    test "calls auth.test" do
      capture_calls()
      assert :ok = Slack.health_probe(@channel)
      assert_received {:slack_call, "auth.test", _, _}

      capture_calls(fn _, _ -> %{"ok" => false, "error" => "invalid_auth"} end)
      assert {:error, "Slack auth.test failed: invalid_auth"} = Slack.health_probe(@channel)
    end
  end

  test "Events.message_ref/2" do
    assert Events.message_ref("C1", "1.2") == "C1:1.2"
    assert Events.message_ref(nil, "1.2") == nil
  end
end
