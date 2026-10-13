defmodule Converger.Channels.Discord.GatewayTest do
  # The Discord Gateway consumer against Converger.FakeDiscordGateway (no
  # real Discord): identify, heartbeats, resume, reconnects, zombie
  # detection and MESSAGE_CREATE handling.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Channels.{Adapter, Broker, Consumers}
  alias Converger.Channels.Adapters.Discord
  alias Converger.FakeDiscordGateway
  alias Converger.Participants.Participant

  @bot_id "900000000000000001"
  @user_id "111111111111111111"
  @discord_channel "987654321098765432"

  setup do
    {:ok, gateway} = FakeDiscordGateway.start_link(self(), heartbeat_interval: 45_000)

    previous = Application.get_env(:converger, Discord, [])

    Application.put_env(
      :converger,
      Discord,
      Keyword.merge(previous, gateway_url: gateway.url, fatal_retry_ms: 600)
    )

    on_exit(fn -> Application.put_env(:converger, Discord, previous) end)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "discord-gw-#{System.unique_integer([:positive])}",
        type: "discord",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "application_id" => "1234567890123456789",
          "bot_token" => "bot-token",
          "gateway" => true
        }
      })

    Ecto.Adapters.SQL.Sandbox.mode(Converger.Repo, {:shared, self()})
    on_exit(fn -> Consumers.stop_consumer(channel.id) end)

    %{gateway: gateway, channel: channel, tenant: tenant}
  end

  # Starts the consumer and completes the handshake; returns the socket.
  defp start_gateway(channel) do
    {:ok, _} = Consumers.start_consumer(channel)
    assert_receive {:gateway_connected, socket, path}, 5_000
    assert path =~ "v=10"
    assert path =~ "encoding=json"
    assert_receive {:gateway_frame, ^socket, %{"op" => 2, "d" => identify}}
    assert identify["token"] == "bot-token"
    assert identify["intents"] == 37_376
    assert identify["properties"]["browser"] == "converger"
    socket
  end

  defp ready(socket, gateway, seq \\ 1) do
    FakeDiscordGateway.push(socket, %{
      "op" => 0,
      "s" => seq,
      "t" => "READY",
      "d" => %{
        "session_id" => "session-1",
        "resume_gateway_url" => gateway.url,
        "user" => %{"id" => @bot_id, "bot" => true}
      }
    })
  end

  defp message_create(socket, seq, attrs) do
    data =
      Map.merge(
        %{
          "id" => "m#{seq}",
          "type" => 0,
          "channel_id" => @discord_channel,
          "guild_id" => "555",
          "content" => "hello from discord",
          "author" => %{"id" => @user_id, "username" => "ada", "global_name" => "Ada"},
          "attachments" => []
        },
        attrs
      )

    FakeDiscordGateway.push(socket, %{"op" => 0, "s" => seq, "t" => "MESSAGE_CREATE", "d" => data})
  end

  defp wait_for(fun, attempts \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false, []] ->
        if attempts == 0, do: flunk("condition not met"), else: Process.sleep(50)
        wait_for(fun, attempts - 1)

      result ->
        result
    end
  end

  defp activities(channel) do
    Repo.all(from(a in Activity, where: a.source_channel_id == ^channel.id, order_by: a.seq))
  end

  describe "configuration" do
    test "only channels with gateway: true in an inbound mode consume", %{channel: channel} do
      assert Broker.consumes?(channel)
      refute Broker.consumes?(put_in(channel.config["gateway"], false))
      refute Broker.consumes?(%{channel | mode: "outbound"})
      assert Adapter.capability?("discord", :consumer)
      assert channel.id in Enum.map(Channels.list_consumer_channels(), & &1.id)
    end

    test "the public key is optional in gateway mode only" do
      base = %{"application_id" => "1", "bot_token" => "t"}

      assert Adapter.validate_config("discord", Map.put(base, "gateway", true)) == :ok

      assert {:error, "discord config missing: public_key (required unless gateway is true)"} =
               Adapter.validate_config("discord", base)

      assert {:error, message} =
               Adapter.validate_config(
                 "discord",
                 Map.merge(base, %{"gateway" => true, "gateway_intents" => "-1"})
               )

      assert message =~ "gateway_intents"

      assert Adapter.validate_config(
               "discord",
               Map.merge(base, %{"gateway" => "true", "gateway_intents" => "33281"})
             ) == :ok
    end

    test "interactions are rejected without a public key", %{channel: channel} do
      assert {:error, :public_key_not_configured} =
               Discord.verify_inbound_signature(channel, [], "{}")
    end
  end

  describe "parse_gateway_message/2" do
    test "maps a message, its attachments and reply reference" do
      assert {:ok, message} =
               Discord.parse_gateway_message(
                 %{
                   "id" => "42",
                   "type" => 19,
                   "channel_id" => "c1",
                   "content" => "see attached",
                   "author" => %{"id" => "u1", "username" => "ada"},
                   "member" => %{"nick" => "Ada L."},
                   "message_reference" => %{"message_id" => "41"},
                   "attachments" => [
                     %{
                       "url" => "https://cdn.discordapp.com/a.png",
                       "filename" => "a.png",
                       "content_type" => "image/png",
                       "size" => 10
                     }
                   ]
                 },
                 @bot_id
               )

      assert message["idempotency_key"] == "message:42"
      assert message["sender"] == "u1"
      assert message["reply_to_provider_id"] == "41"
      assert message["participant"]["display_name"] == "Ada L."
      assert message["participant"]["metadata"] == %{"discord_channel_id" => "c1"}
      assert message["metadata"]["discord_source"] == "gateway"

      assert [
               %{
                 "contentType" => "image/png",
                 "name" => "a.png",
                 "channelData" => %{"provider" => "discord", "providerMediaUrl" => _}
               } = attachment
             ] = message["attachments"]

      refute Map.has_key?(attachment, "contentUrl")
    end

    test "ignores the bot's own, other bots', webhook, system and empty messages" do
      base = %{
        "id" => "1",
        "type" => 0,
        "channel_id" => "c",
        "content" => "x",
        "author" => %{"id" => "u"}
      }

      assert {:ok, _} = Discord.parse_gateway_message(base, @bot_id)

      for data <- [
            %{base | "author" => %{"id" => @bot_id}},
            %{base | "author" => %{"id" => "other", "bot" => true}},
            Map.put(base, "webhook_id", "w"),
            %{base | "type" => 7},
            %{base | "content" => ""},
            Map.delete(base, "author")
          ] do
        assert Discord.parse_gateway_message(data, @bot_id) == :ignore, inspect(data)
      end
    end
  end

  test "identifies, and turns MESSAGE_CREATE into activities", %{
    channel: channel,
    gateway: gateway
  } do
    socket = start_gateway(channel)
    ready(socket, gateway)

    message_create(socket, 2, %{})
    message_create(socket, 3, %{"id" => "own", "author" => %{"id" => @bot_id}})
    message_create(socket, 4, %{"id" => "bot", "author" => %{"id" => "2", "bot" => true}})
    # A replayed event (resume) is a duplicate.
    message_create(socket, 5, %{"id" => "m2"})
    message_create(socket, 6, %{"id" => "m6", "content" => "second"})

    wait_for(fn -> Enum.any?(activities(channel), &(&1.text == "second")) end)
    assert [first, second] = activities(channel)
    assert first.text == "hello from discord"
    assert first.sender == @user_id
    assert first.idempotency_key == "message:m2"
    assert first.metadata["discord_channel_id"] == @discord_channel
    assert second.text == "second"

    participant = Repo.get_by!(Participant, channel_id: channel.id, external_id: @user_id)
    assert participant.metadata["discord_channel_id"] == @discord_channel
    assert participant.display_name == "Ada"
  end

  test "heartbeats carry the last sequence number and the jittered first beat", %{
    channel: channel,
    gateway: gateway
  } do
    FakeDiscordGateway.set(gateway, :heartbeat_interval, 100)
    socket = start_gateway(channel)
    ready(socket, gateway, 7)

    assert_receive {:gateway_frame, ^socket, %{"op" => 1, "d" => 7}}, 2_000
    assert_receive {:gateway_frame, ^socket, %{"op" => 1, "d" => 7}}, 2_000

    # A heartbeat requested by the Gateway is sent at once.
    FakeDiscordGateway.set(gateway, :heartbeat_interval, 45_000)
    FakeDiscordGateway.push(socket, %{"op" => 1, "d" => nil})
    assert_receive {:gateway_frame, ^socket, %{"op" => 1}}, 1_000
  end

  test "a reconnect request (op 7) resumes the session", %{channel: channel, gateway: gateway} do
    socket = start_gateway(channel)
    ready(socket, gateway)
    message_create(socket, 2, %{})

    FakeDiscordGateway.push(socket, %{"op" => 7, "d" => nil})
    assert_receive {:gateway_connected, resumed, _path}, 5_000
    assert resumed != socket

    assert_receive {:gateway_frame, ^resumed,
                    %{"op" => 6, "d" => %{"session_id" => "session-1", "seq" => 2} = resume}}

    assert resume["token"] == "bot-token"
    refute_received {:gateway_frame, ^resumed, %{"op" => 2}}

    FakeDiscordGateway.push(resumed, %{"op" => 0, "s" => 3, "t" => "RESUMED", "d" => %{}})
    message_create(resumed, 4, %{"id" => "after-resume", "content" => "back"})
    wait_for(fn -> Enum.any?(activities(channel), &(&1.text == "back")) end)
  end

  test "a missing heartbeat ACK (zombie connection) reconnects and resumes", %{
    channel: channel,
    gateway: gateway
  } do
    FakeDiscordGateway.set(gateway, :heartbeat_interval, 100)
    FakeDiscordGateway.set(gateway, :ack_heartbeats, false)
    socket = start_gateway(channel)
    ready(socket, gateway)

    assert_receive {:gateway_frame, ^socket, %{"op" => 1}}, 2_000
    assert_receive {:gateway_connected, resumed, _path}, 5_000
    assert resumed != socket
    assert_receive {:gateway_frame, ^resumed, %{"op" => 6, "d" => %{"seq" => 1}}}, 2_000
  end

  test "an invalid session that cannot be resumed identifies again", %{
    channel: channel,
    gateway: gateway
  } do
    socket = start_gateway(channel)
    ready(socket, gateway)

    FakeDiscordGateway.push(socket, %{"op" => 9, "d" => false})
    assert_receive {:gateway_connected, again, _path}, 8_000
    assert_receive {:gateway_frame, ^again, %{"op" => 2}}, 2_000
  end

  test "a resumable close code resumes; a fatal one waits before identifying again", %{
    channel: channel,
    gateway: gateway
  } do
    socket = start_gateway(channel)
    ready(socket, gateway)

    FakeDiscordGateway.close(socket, 4000, "unknown error")
    assert_receive {:gateway_connected, resumed, _path}, 5_000
    assert_receive {:gateway_frame, ^resumed, %{"op" => 6}}, 2_000

    FakeDiscordGateway.close(resumed, 4004, "Authentication failed.")
    refute_receive {:gateway_connected, _, _}, 300
    # fatal_retry_ms is 600 in this test.
    assert_receive {:gateway_connected, again, _path}, 3_000
    assert_receive {:gateway_frame, ^again, %{"op" => 2}}, 2_000
  end
end
