defmodule Converger.Channels.Mqtt.ConnectionTest do
  # The MQTT client connection against Converger.FakeMqttBroker.
  use ExUnit.Case, async: true

  alias Converger.Channels.Mqtt.{Connection, Packet}
  alias Converger.FakeMqttBroker

  setup do
    broker = start_supervised!({FakeMqttBroker, self()})
    %{broker: broker, port: FakeMqttBroker.port(broker)}
  end

  defp connect(port, opts \\ []) do
    Connection.start(
      Keyword.merge([host: "127.0.0.1", port: port, client_id: "test-client"], opts)
    )
  end

  test "connects, subscribes and hands QoS 1 messages to the owner without acknowledging them",
       %{port: port} do
    {:ok, conn} =
      connect(port,
        clean_session: false,
        username: "user",
        password: "pw",
        subscriptions: [{"in/+", 1}]
      )

    assert_receive {:mqtt_client, session,
                    {:connect,
                     %{
                       client_id: "test-client",
                       clean_session: false,
                       username: "user",
                       password: "pw"
                     }}}

    assert_receive {:mqtt_client, ^session, {:subscribe, 1, [{"in/+", 1}]}}

    FakeMqttBroker.push(session, Packet.publish("in/dev-1", ~s({"text":"hi"}), 1, 42))

    assert_receive {:mqtt_publish, ^conn,
                    %{topic: "in/dev-1", payload: ~s({"text":"hi"}), qos: 1, packet_id: 42}}

    # No PUBACK until the owner acknowledges.
    refute_receive {:mqtt_client, ^session, {:puback, _}}, 200

    :ok = Connection.ack(conn, 42)
    assert_receive {:mqtt_client, ^session, {:puback, 42}}

    Connection.stop(conn)
    assert_receive {:mqtt_client, ^session, :disconnect}
  end

  test "messages queued before the SUBACK are passed on", %{port: port, broker: broker} do
    FakeMqttBroker.set(broker, :session_present, true)
    FakeMqttBroker.set(broker, :after_connack, Packet.publish("in/a", "queued", 1, 1, dup: true))

    {:ok, conn} = connect(port, subscriptions: [{"in/+", 1}], clean_session: false)
    assert_receive {:mqtt_publish, ^conn, %{payload: "queued", dup: true, packet_id: 1}}
  end

  test "publish with QoS 1 waits for the PUBACK", %{port: port, broker: broker} do
    {:ok, conn} = connect(port)
    assert_receive {:mqtt_client, session, {:connect, _}}

    assert Connection.publish(conn, "out/1", "payload", 1) == :ok
    assert_receive {:mqtt_client, ^session, {:publish, %{topic: "out/1", qos: 1, packet_id: 1}}}

    assert Connection.publish(conn, "out/1", "zero", 0) == :ok
    assert_receive {:mqtt_client, ^session, {:publish, %{payload: "zero", qos: 0}}}

    FakeMqttBroker.set(broker, :puback, false)
    assert Connection.publish(conn, "out/1", "lost", 1, timeout: 200) == {:error, :puback_timeout}
  end

  test "a refused CONNECT is an error with the reason", %{port: port, broker: broker} do
    FakeMqttBroker.set(broker, :connack_code, 5)
    assert {:error, {:connection_refused, :not_authorized}} = connect(port)

    FakeMqttBroker.set(broker, :connack_code, 4)
    assert {:error, {:connection_refused, :bad_username_or_password}} = connect(port)
  end

  test "a refused subscription is an error", %{port: port, broker: broker} do
    FakeMqttBroker.set(broker, :suback, 0x80)

    assert {:error, {:subscribe_failed, "secret/#"}} =
             connect(port, subscriptions: [{"secret/#", 1}])
  end

  test "an unreachable broker is a connect error" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    assert {:error, {:connect_failed, :econnrefused}} = connect(port)
  end

  test "pings within the keepalive and closes when the broker stops answering", %{
    port: port,
    broker: broker
  } do
    {:ok, conn} = connect(port, keepalive: 1)
    ref = Process.monitor(conn)
    assert_receive {:mqtt_client, session, {:connect, %{keepalive: 1}}}
    assert_receive {:mqtt_client, ^session, :pingreq}, 2_000

    FakeMqttBroker.set(broker, :pingresp, false)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :keepalive_timeout}}, 5_000
  end

  test "stops when the broker closes the socket", %{port: port} do
    {:ok, conn} = connect(port)
    ref = Process.monitor(conn)
    assert_receive {:mqtt_client, session, {:connect, _}}

    FakeMqttBroker.close(session)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :closed}}, 2_000
  end

  test "a publisher stops after idle_ms without publishes", %{port: port} do
    {:ok, conn} = connect(port, keepalive: 1, idle_ms: 100)
    ref = Process.monitor(conn)
    assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 3_000
  end
end
