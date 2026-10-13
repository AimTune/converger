defmodule Converger.Channels.Mqtt.PacketTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Mqtt.Packet

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  describe "encoding" do
    test "CONNECT with credentials, persistent session and keepalive" do
      packet =
        bin(
          Packet.connect(
            client_id: "c1",
            clean_session: false,
            keepalive: 30,
            username: "u",
            password: "p"
          )
        )

      assert packet ==
               <<0x10, 20, 4::16, "MQTT", 4, 0xC0, 30::16, 2::16, "c1", 1::16, "u", 1::16, "p">>
    end

    test "CONNECT without credentials, clean session" do
      assert <<0x10, _len, 4::16, "MQTT", 4, 0x02, 60::16, 3::16, "abc">> =
               bin(Packet.connect(client_id: "abc"))
    end

    test "a password without a username is not sent" do
      assert <<0x10, _len, 4::16, "MQTT", 4, 0x02, _::binary>> =
               bin(Packet.connect(client_id: "abc", password: "p"))
    end

    test "PUBLISH QoS 0 and 1, retain and dup flags" do
      assert bin(Packet.publish("a/b", "hi", 0, nil)) == <<0x30, 7, 3::16, "a/b", "hi">>
      assert bin(Packet.publish("a/b", "hi", 1, 7)) == <<0x32, 9, 3::16, "a/b", 7::16, "hi">>

      assert <<0x3B, _::binary>> =
               bin(Packet.publish("a", "x", 1, 1, retain: true, dup: true))
    end

    test "remaining length over 127 bytes uses several bytes" do
      payload = String.duplicate("x", 200)
      # 2 + 1 (topic) + 200 = 203 = 0xCB 0x01
      assert <<0x30, 0xCB, 0x01, 1::16, "t", ^payload::binary>> =
               bin(Packet.publish("t", payload, 0, nil))
    end

    test "SUBSCRIBE, PUBACK, PINGREQ, DISCONNECT" do
      assert bin(Packet.subscribe(1, [{"a/+", 1}, {"b/#", 0}])) ==
               <<0x82, 14, 1::16, 3::16, "a/+", 1, 3::16, "b/#", 0>>

      assert bin(Packet.puback(258)) == <<0x40, 2, 1, 2>>
      assert Packet.pingreq() == <<0xC0, 0>>
      assert Packet.disconnect() == <<0xE0, 0>>
    end
  end

  describe "decoding" do
    test "CONNACK" do
      assert {:ok, %{type: :connack, session_present: true, return_code: 0}, <<>>} =
               Packet.decode(<<0x20, 2, 1, 0>>)

      assert {:ok, %{type: :connack, session_present: false, return_code: 5}, "rest"} =
               Packet.decode(<<0x20, 2, 0, 5, "rest">>)
    end

    test "PUBLISH QoS 0 and 1 round trip" do
      assert {:ok, %{type: :publish, topic: "a/b", payload: "hi", qos: 0, packet_id: nil}, <<>>} =
               Packet.decode(bin(Packet.publish("a/b", "hi", 0, nil)))

      assert {:ok,
              %{
                type: :publish,
                topic: "a/b",
                payload: "hi",
                qos: 1,
                packet_id: 9,
                dup: true,
                retain: true
              }, <<>>} =
               Packet.decode(bin(Packet.publish("a/b", "hi", 1, 9, dup: true, retain: true)))
    end

    test "PUBACK, SUBACK, PINGRESP" do
      assert {:ok, %{type: :puback, packet_id: 3}, <<>>} = Packet.decode(<<0x40, 2, 3::16>>)

      assert {:ok, %{type: :suback, packet_id: 1, return_codes: [1, 0x80]}, <<>>} =
               Packet.decode(<<0x90, 4, 1::16, 1, 0x80>>)

      assert {:ok, %{type: :pingresp}, <<>>} = Packet.decode(<<0xD0, 0>>)
    end

    test "incomplete buffers ask for more" do
      packet = bin(Packet.publish("topic", String.duplicate("y", 300), 1, 1))

      assert Packet.decode(<<>>) == :more
      assert Packet.decode(binary_part(packet, 0, 1)) == :more
      assert Packet.decode(binary_part(packet, 0, 2)) == :more
      assert Packet.decode(binary_part(packet, 0, byte_size(packet) - 1)) == :more
      assert {:ok, %{type: :publish}, <<>>} = Packet.decode(packet)
    end

    test "two packets in one buffer" do
      assert {:ok, %{type: :pingresp}, rest} = Packet.decode(<<0xD0, 0, 0x40, 2, 0, 1>>)
      assert {:ok, %{type: :puback, packet_id: 1}, <<>>} = Packet.decode(rest)
    end

    test "rejects QoS 2, unexpected packets and malformed lengths" do
      assert {:error, {:unsupported_qos, 2}} = Packet.decode(<<0x34, 5, 1::16, "a", 1::16>>)
      assert {:error, {:unexpected_packet, 1}} = Packet.decode(<<0x10, 0>>)

      assert {:error, :malformed_remaining_length} =
               Packet.decode(<<0x30, 0xFF, 0xFF, 0xFF, 0xFF>>)

      assert {:error, :malformed_publish} = Packet.decode(<<0x32, 3, 1::16, "a">>)
    end
  end

  describe "topics" do
    test "valid filters" do
      for filter <- ["a", "a/b", "a/+", "+/b/#", "#", "+", "a//b", "/a"] do
        assert Packet.valid_filter?(filter), filter
      end

      for filter <- ["", "a/#/b", "a+", "a/b#", "a/#b", <<"a", 0>>, nil, 1] do
        refute Packet.valid_filter?(filter), inspect(filter)
      end
    end

    test "valid topic names" do
      assert Packet.valid_topic?("converger/out/123")
      refute Packet.valid_topic?("a/+")
      refute Packet.valid_topic?("a/#")
      refute Packet.valid_topic?("")
    end

    test "matching" do
      assert Packet.matches?("a/+", "a/b")
      refute Packet.matches?("a/+", "a/b/c")
      assert Packet.matches?("a/#", "a/b/c")
      assert Packet.matches?("a/#", "a")
      assert Packet.matches?("#", "x/y")
      refute Packet.matches?("#", "$SYS/x")
      refute Packet.matches?("+/x", "$SYS/x")
      assert Packet.matches?("$SYS/#", "$SYS/x")
      assert Packet.matches?("a/b", "a/b")
      refute Packet.matches?("a/b", "a/c")
    end
  end
end
