defmodule Converger.Channels.Adapters.TeamsTest do
  # Global Req stub (config :converger, :teams_req_options) and the shared
  # token cache: not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Participants, Repo}
  alias Converger.Channels.{Adapter, DeliveryError, TokenCache}
  alias Converger.Channels.Adapters.Teams
  alias Converger.Channels.Teams.Auth

  @app_id "6d3c8a2e-1f4b-4c7a-9e2d-0b5a7c9e1f3d"
  @service_url "https://smba.trafficmanager.net/emea/"
  @conversation "a:1Xb9-personal-chat-id"
  @user "29:1user-aad-id"
  @bot "28:#{@app_id}"
  @kid "test-signing-key"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(256)>>

  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(jwk)
    %{jwk: jwk, public_key: public}
  end

  setup %{public_key: public_key} do
    Application.put_env(:converger, :teams_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:converger, :teams_req_options) end)

    Auth.clear_key_cache()
    config = %{"app_id" => @app_id, "app_password" => "s3cret"}
    Auth.invalidate_token(config)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "teams-#{System.unique_integer([:positive])}",
        type: "teams",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: config
      })

    keys = [
      Map.merge(public_key, %{"kid" => @kid, "use" => "sig", "endorsements" => ["msteams"]})
    ]

    stub_bot_framework(keys)

    %{tenant: tenant, channel: channel, keys: keys}
  end

  # Answers the OpenID metadata, the signing keys, the token endpoint and the
  # Bot Connector; `connector` decides the Bot Connector answer.
  defp stub_bot_framework(
         keys,
         connector \\ fn _conn, _body -> {201, %{"id" => "1700000000001"}} end
       ) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:http, conn.method, conn.host, conn.request_path, conn.req_headers, body})

      {status, response} =
        case {conn.host, conn.request_path} do
          {"login.botframework.com", "/v1/.well-known/openidconfiguration"} ->
            {200, %{"jwks_uri" => "https://login.botframework.com/v1/.well-known/keys"}}

          {"login.botframework.com", "/v1/.well-known/keys"} ->
            {200, %{"keys" => keys}}

          {"login.microsoftonline.com", "/botframework.com/oauth2/v2.0/token"} ->
            {200, %{"access_token" => "bf-token", "expires_in" => 3599, "token_type" => "Bearer"}}

          _ ->
            connector.(conn, body)
        end

      case response do
        binary when is_binary(binary) ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(status, binary)

        map ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(map)
      end
    end)
  end

  defp token(jwk, overrides) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://api.botframework.com",
          "aud" => @app_id,
          "exp" => now + 3600,
          "nbf" => now - 10,
          "serviceurl" => @service_url
        },
        overrides
      )

    {_, compact} =
      jwk
      |> JOSE.JWT.sign(
        %{"alg" => "RS256", "kid" => overrides["kid"] || @kid},
        Map.delete(claims, "kid")
      )
      |> JOSE.JWS.compact()

    compact
  end

  defp message(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "message",
        "id" => "1700000000000",
        "timestamp" => "2026-10-12T10:00:00.000Z",
        "serviceUrl" => @service_url,
        "channelId" => "msteams",
        "from" => %{"id" => @user, "name" => "Megan Bowen", "aadObjectId" => "aad-1"},
        "conversation" => %{
          "id" => @conversation,
          "conversationType" => "personal",
          "tenantId" => "t-1"
        },
        "recipient" => %{"id" => @bot, "name" => "Support Bot"},
        "text" => "Hello bot",
        "locale" => "en-US",
        "channelData" => %{"tenant" => %{"id" => "t-1"}}
      },
      extra
    )
  end

  defp post_activity(conn, channel, jwk, activity, claims \\ %{}) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token(jwk, claims))
    |> post(~p"/api/v1/channels/#{channel.id}/inbound", Jason.encode!(activity))
  end

  defp verify(channel, jwk, activity, claims) do
    body = Jason.encode!(activity)

    Teams.verify_inbound_signature(
      channel,
      [{"authorization", "Bearer " <> token(jwk, claims)}],
      body
    )
  end

  test "is registered as a duplex built-in with typing" do
    assert {:ok, Teams} = Adapter.adapter_for("teams")
    assert Teams.supported_modes() == ~w(inbound outbound duplex)
    assert Adapter.capability?("teams", :typing)
  end

  test "config requires a GUID app id and the client secret" do
    assert {:error, message} = Adapter.validate_config("teams", %{"app_id" => @app_id})
    assert message =~ "app_password"

    assert {:error, message} =
             Adapter.validate_config("teams", %{"app_id" => "bot", "app_password" => "x"})

    assert message =~ "GUID"

    assert :ok =
             Adapter.validate_config("teams", %{
               "app_id" => @app_id,
               "app_password" => "x",
               "app_tenant_id" => "contoso.onmicrosoft.com"
             })
  end

  describe "JWT validation" do
    test "accepts a Bot Connector token", %{channel: channel, jwk: jwk} do
      assert :ok = verify(channel, jwk, message(), %{})
    end

    test "rejects wrong claims", %{channel: channel, jwk: jwk} do
      assert {:error, :invalid_audience} =
               verify(channel, jwk, message(), %{"aud" => "other-app"})

      assert {:error, :invalid_issuer} =
               verify(channel, jwk, message(), %{"iss" => "https://evil.example.com"})

      assert {:error, :token_expired} =
               verify(channel, jwk, message(), %{"exp" => System.system_time(:second) - 600})

      assert {:error, :service_url_mismatch} =
               verify(channel, jwk, message(), %{
                 "serviceurl" => "https://smba.trafficmanager.net/amer/"
               })
    end

    test "rejects a token signed by another key", %{channel: channel} do
      other = JOSE.JWK.generate_key({:rsa, 2048})
      assert {:error, :invalid_signature} = verify(channel, other, message(), %{})
    end

    test "rejects a key not endorsed for the channel", %{channel: channel, jwk: jwk} do
      assert {:error, :key_not_endorsed} =
               verify(channel, jwk, message(%{"channelId" => "slack"}), %{})
    end

    test "an unknown kid refetches the keys once per cooldown", %{channel: channel, jwk: jwk} do
      assert :ok = verify(channel, jwk, message(), %{})
      assert_received {:http, "GET", _, "/v1/.well-known/keys", _, _}

      assert {:error, :unknown_key} = verify(channel, jwk, message(), %{"kid" => "rotated"})
      assert_received {:http, "GET", _, "/v1/.well-known/keys", _, _}

      assert {:error, :unknown_key} = verify(channel, jwk, message(), %{"kid" => "rotated-again"})
      refute_received {:http, "GET", _, "/v1/.well-known/keys", _, _}
    end

    test "a request without a token is a 401", %{conn: conn, channel: channel} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/channels/#{channel.id}/inbound", Jason.encode!(message()))

      assert json_response(conn, 401)
    end
  end

  describe "inbound" do
    test "a message creates an activity and remembers where to reply", %{
      conn: conn,
      channel: channel,
      jwk: jwk
    } do
      activity =
        message(%{
          "text" => "<at>Support Bot</at> I need help",
          "entities" => [
            %{
              "type" => "mention",
              "text" => "<at>Support Bot</at>",
              "mentioned" => %{"id" => @bot}
            }
          ]
        })

      conn = post_activity(conn, channel, jwk, activity)
      assert %{"activity_ids" => [id]} = json_response(conn, 200)

      stored = Repo.get!(Activity, id)
      assert stored.text == "I need help"
      assert stored.sender == @user
      assert stored.idempotency_key == Teams.message_key(@conversation, "1700000000000")
      assert stored.metadata["teams_tenant_id"] == "t-1"

      participant = Participants.get_participant_by_external_id(channel.id, @user)
      assert participant.display_name == "Megan Bowen"

      assert participant.metadata == %{
               "service_url" => @service_url,
               "conversation_id" => @conversation,
               "bot_id" => @bot,
               "tenant_id" => "t-1"
             }

      # A later message from another conversation moves the reply target.
      conn =
        post_activity(
          build_conn(),
          channel,
          jwk,
          message(%{"id" => "1700000000002", "conversation" => %{"id" => "19:group@thread.v2"}})
        )

      assert json_response(conn, 200)

      assert Participants.get_participant_by_external_id(channel.id, @user).metadata[
               "conversation_id"
             ] ==
               "19:group@thread.v2"
    end

    test "reactions, edits, deletes and card actions" do
      key = Teams.message_key(@conversation, "1700000000000")

      assert {:ok, [reaction]} =
               Teams.parse_inbound(
                 %{},
                 message(%{
                   "type" => "messageReaction",
                   "id" => "r1",
                   "replyToId" => "1700000000000",
                   "reactionsAdded" => [%{"type" => "like"}]
                 })
               )

      assert reaction["type"] == "messageReaction"
      assert reaction["text"] == "like"
      assert reaction["reply_to_provider_id"] == key

      assert {:ok, [edit]} =
               Teams.parse_inbound(%{}, message(%{"type" => "messageUpdate", "text" => "fixed"}))

      assert edit["type"] == "messageUpdate"
      assert edit["reply_to_provider_id"] == key

      assert {:ok, [delete]} = Teams.parse_inbound(%{}, message(%{"type" => "messageDelete"}))
      assert delete["type"] == "messageDelete"

      assert {:ok, [submit]} =
               Teams.parse_inbound(%{}, message(%{"text" => nil, "value" => %{"choice" => "a"}}))

      assert submit["type"] == "event"
      assert submit["metadata"]["value"] == %{"choice" => "a"}

      assert {:ok, []} = Teams.parse_inbound(%{}, message(%{"type" => "conversationUpdate"}))
    end

    test "an adaptiveCard/action invoke gets the invoke response", %{
      conn: conn,
      channel: channel,
      jwk: jwk
    } do
      invoke =
        message(%{
          "type" => "invoke",
          "name" => "adaptiveCard/action",
          "value" => %{"action" => %{"type" => "Action.Execute", "verb" => "approve"}}
        })

      conn = post_activity(conn, channel, jwk, invoke)

      assert json_response(conn, 200) == %{
               "statusCode" => 200,
               "type" => "application/vnd.microsoft.activity.message",
               "value" => "Received"
             }

      [activity] = Repo.all(Activity)
      assert activity.type == "event"
      assert activity.text == "approve"
    end

    test "inline images are fetched with the bot token, shared files without", %{channel: channel} do
      stub_bot_framework([], fn _conn, _ -> {200, @png} end)

      inline = %{
        "channelData" => %{
          "kind" => "inline",
          "providerMediaUrl" =>
            "https://smba.trafficmanager.net/emea/v3/attachments/1/views/original"
        }
      }

      assert {:ok, %{data: @png}} = Teams.fetch_media(channel, inline)
      assert_received {:http, "GET", "smba.trafficmanager.net", _, headers, _}
      assert {"authorization", "Bearer bf-token"} in headers

      # The bot token never goes to a host outside the allowlist.
      assert {:error, message} =
               Teams.fetch_media(
                 channel,
                 put_in(inline, ["channelData", "providerMediaUrl"], "https://evil.example.com/x")
               )

      assert message =~ "not an allowed Bot Framework host"

      file = %{
        "channelData" => %{
          "kind" => "file",
          "providerMediaUrl" => "https://contoso.sharepoint.com/download?x=1"
        }
      }

      assert {:ok, %{data: @png}} = Teams.fetch_media(channel, file)
      assert_received {:http, "GET", "contoso.sharepoint.com", _, file_headers, _}
      refute List.keymember?(file_headers, "authorization", 0)
    end
  end

  describe "outbound" do
    setup %{conn: conn, channel: channel, jwk: jwk} do
      conn = post_activity(conn, channel, jwk, message())
      %{"activity_ids" => [id]} = json_response(conn, 200)
      %{inbound: Repo.get!(Activity, id)}
    end

    defp reply(inbound, attrs \\ %{}) do
      struct(
        Activity,
        Map.merge(
          %{
            conversation_id: inbound.conversation_id,
            text: "Hi Megan",
            attachments: [],
            metadata: %{}
          },
          Map.new(attrs)
        )
      )
    end

    defp drain do
      receive do
        {:http, _, _, _, _, _} -> drain()
      after
        0 -> :ok
      end
    end

    test "replies to the participant's conversation with a cached token", %{
      channel: channel,
      inbound: inbound
    } do
      drain()

      buttons = %{
        "contentType" => "application/vnd.converger.card.buttons",
        "content" => %{"buttons" => [%{"id" => "yes", "title" => "Yes"}]}
      }

      assert {:ok, %{provider_message_id: key}} =
               Teams.deliver_activity(channel, reply(inbound, attachments: [buttons]))

      assert key == Teams.message_key(@conversation, "1700000000001")

      assert_received {:http, "POST", "login.microsoftonline.com", _, _, token_form}
      assert URI.decode_query(token_form)["scope"] == "https://api.botframework.com/.default"

      assert_received {:http, "POST", "smba.trafficmanager.net", path, headers, body}
      assert path == "/emea/v3/conversations/a%3A1Xb9-personal-chat-id/activities"
      assert {"authorization", "Bearer bf-token"} in headers

      body = Jason.decode!(body)
      assert body["from"] == %{"id" => @bot}
      assert body["text"] == "Hi Megan"

      assert [%{"contentType" => "application/vnd.microsoft.card.hero", "content" => content}] =
               body["attachments"]

      assert content["buttons"] == [%{"type" => "imBack", "title" => "Yes", "value" => "yes"}]

      assert {:ok, _} = Teams.deliver_activity(channel, reply(inbound))
      refute_received {:http, "POST", "login.microsoftonline.com", _, _, _}
    end

    test "a 401 drops the token and is retried; 403 is permanent", %{
      channel: channel,
      inbound: inbound,
      keys: keys
    } do
      stub_bot_framework(keys, fn _, _ -> {401, %{}} end)

      assert {:error, %DeliveryError{retryable?: true, status: 401}} =
               Teams.deliver_activity(channel, reply(inbound))

      assert :miss =
               TokenCache.get(
                 {Auth, :token, @app_id, "botframework.com", :crypto.hash(:sha256, "s3cret")}
               )

      stub_bot_framework(keys, fn _, _ ->
        {403, %{"error" => %{"code" => "BotNotInConversationRoster"}}}
      end)

      assert {:error, %DeliveryError{retryable?: false}} =
               Teams.deliver_activity(channel, reply(inbound))
    end

    test "rejected credentials are permanent", %{channel: channel, inbound: inbound} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               Teams.deliver_activity(channel, reply(inbound))

      assert reason =~ "invalid_client"
      refute reason =~ "s3cret"
    end

    test "service URLs outside the allowlist or on private addresses are refused", %{
      channel: channel
    } do
      activity =
        struct(Activity, %{
          text: "hi",
          attachments: [],
          metadata: %{
            "target_conversation_id" => @conversation,
            "target_service_url" => "https://evil.example.com/"
          }
        })

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               Teams.deliver_activity(channel, activity)

      assert reason =~ "not an allowed Bot Framework host"

      Converger.TestDnsResolver.put("internal.botframework.com", {:ok, [{10, 0, 0, 7}]})

      activity =
        put_in(activity.metadata["target_service_url"], "https://internal.botframework.com/")

      assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
               Teams.deliver_activity(channel, activity)

      assert reason =~ "private"
    end

    test "typing indicators go to the participant's conversation", %{channel: channel} do
      drain()

      assert :ok =
               Teams.send_typing(channel, %{
                 is_typing: true,
                 recipient: @user,
                 conversation_id: "c",
                 provider_message_id: nil
               })

      assert_received {:http, "POST", "smba.trafficmanager.net", _, _, body}
      assert Jason.decode!(body)["type"] == "typing"
    end

    test "health probe gets a token", %{channel: channel} do
      assert :ok = Teams.health_probe(channel)
    end
  end
end
